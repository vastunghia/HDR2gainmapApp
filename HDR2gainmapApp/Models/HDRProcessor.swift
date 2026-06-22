import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import CoreVideo

/// Which image the preview pane should display. Lives here (rather than in `ProcessingSettings`)
/// because it is a global *viewing* state, not a per-image export parameter, yet it must be
/// visible to `PreviewParams` which is shared with the CLI target.
enum PreviewMode: String, CaseIterable, Sendable {
    // Declaration order drives the left→right order of the segmented picker.
    case hdrInput        // original HDR, shown via EDR on capable displays
    case sdrTonemapped   // tone-mapped SDR base (default; supports the clipping overlay)
    case gainMap         // standalone grayscale gain map
    case finalOutput     // SDR + gain map round-tripped back to HDR (what the export produces)

    /// Whether the rendered image carries extended-range (HDR) content and must be displayed
    /// through the EDR path. (Also the views where the display-headroom indicator is relevant.)
    var isHDR: Bool {
        switch self {
        case .hdrInput, .finalOutput: return true
        case .sdrTonemapped, .gainMap: return false
        }
    }

    /// Label for the segmented picker.
    var displayName: String {
        switch self {
        case .hdrInput:      return "HDR Input"
        case .sdrTonemapped: return "Tonemapped SDR"
        case .gainMap:       return "Gain Map"
        case .finalOutput:   return "SDR + Gain Map (Final Output)"
        }
    }

}

// MARK: - Per-worker search resources (batch parallelism)

/// Self-contained GPU resources for one concurrent auto-search worker: its own CIContext and
/// Metal histogram calculator. Sharing the singletons across a TaskGroup serializes on the
/// CIContext and the histogram's NSLock (measured: in-process parallelism caps ~1.5×); one set
/// per worker unlocks near-linear scaling (measured ~3× at 6 workers, matching separate processes).
///
/// Declared at file scope and explicitly `nonisolated` so the type and its `init` stay off the
/// main actor: this target builds with default-isolation = MainActor, which would otherwise infer
/// main-actor isolation here and trip Swift 6 concurrency in the nonisolated search code.
nonisolated final class SearchResources: @unchecked Sendable {
    let ctx: CIContext
    let histogram: MetalHistogramCalculator?
    init(workingColorSpace: CGColorSpace) {
        ctx = CIContext(options: [.workingColorSpace: workingColorSpace,
                                  .outputColorSpace: workingColorSpace])
        histogram = MetalHistogramCalculator()
    }
}

/// Task-local holder for the resources the current task should use during the auto search. Set
/// per-task by the batch via `withValue`; `nil` (the single-image path) falls back to the shared
/// singletons, so behavior outside the batch is unchanged. Lives in a non-isolated namespace so the
/// projected `$current` is referenceable from the nonisolated search code (Swift 6 safe). The enum
/// is marked `nonisolated` so its `@TaskLocal` (and its projected value) escapes the target's
/// default-isolation = MainActor.
nonisolated enum SearchResourcesContext {
    @TaskLocal static var current: SearchResources?
}

/// Bridge between the CLI pipeline and SwiftUI; orchestrates HDR image processing.
@MainActor
class HDRProcessor {
    
    // These caches are accessed from the off-main load/preview path as well as the main
    // actor. NSCache is thread-safe, so the access is safe despite the `nonisolated(unsafe)`.
    nonisolated(unsafe) private let hdrCache = NSCache<NSURL, CIImage>()

    // Short‑term preview cache (key = URL + settings fingerprint).
    nonisolated(unsafe) private let previewBaseCache = NSCache<NSString, CIImage>()
    // Keyed by `overlayKey(baseKey, opacity)` — the composite depends on the chosen overlay opacity.
    nonisolated(unsafe) private let previewOverlayCache = NSCache<NSString, CIImage>()
    nonisolated(unsafe) private let previewCountsCache = NSCache<NSString, NSDictionary>() // ["c": Int, "t": Int]
    // Detailed clipping stats, cached per settings key so they survive preview cache hits and are
    // available regardless of the overlay opacity (the key excludes the opacity — stats are
    // opacity-independent).
    nonisolated(unsafe) private let previewDetailedCache = NSCache<NSString, DetailedStatsBox>()

    nonisolated(unsafe) private static var peakLuminanceCache = NSCache<NSURL, NSNumber>()

    // Percentile-derived headroom lookup (built once per image, then reused for real-time UI updates).
    nonisolated(unsafe) private static let percentileCDFCache = NSCache<NSURL, PercentileCDFBox>()
    
    // In-flight builders so multiple callers (UI + preview/export) don't duplicate work.
    private var percentileCDFInFlight: [NSURL: Task<PercentileCDFBox, Error>] = [:]
    
    /// Sendable snapshot of the per-image settings needed by the preview pipeline. Captured on the
    /// main actor so the heavy off-main render never reads the live `@Observable` settings (which
    /// can mutate while the user drags a slider).
    struct PreviewParams: Sendable {
        let url: URL
        let method: ProcessingSettings.SourceHeadroomMethod
        let tonemapRatio: Float
        let percentile: Float
        let directSourceHeadroom: Float?
        let targetHeadroom: Float?
        /// Clipped-pixel overlay opacity (0 = hidden, 1 = fully opaque). Affects only the
        /// composited overlay image, never the SDR base or the clipping stats.
        let overlayOpacity: Float
        // Which view to render. The CLI never sets this (defaults to `.sdrTonemapped`).
        let mode: PreviewMode
    }

    /// Snapshots the live per-image settings on the main actor.
    func previewParams(url: URL, settings: ProcessingSettings, mode: PreviewMode = .sdrTonemapped) -> PreviewParams {
        PreviewParams(
            url: url,
            method: settings.sourceHeadroomMethod,
            tonemapRatio: settings.tonemapRatio,
            percentile: settings.percentile,
            directSourceHeadroom: settings.directSourceHeadroom,
            targetHeadroom: settings.targetHeadroom,
            overlayOpacity: settings.overlayOpacity,
            mode: mode
        )
    }

    nonisolated private func previewSettingsFingerprint(_ p: PreviewParams) -> String {
        // Include both source and target headroom in the fingerprint
        let th = p.targetHeadroom ?? 1.0

        switch p.method {
        case .peakMax:
            return "m=peakMax;r=\(p.tonemapRatio);th=\(th)"
        case .percentile:
            return "m=percentile;p=\(p.percentile);th=\(th)"
        case .direct:
            let sh = p.directSourceHeadroom ?? -1
            return "m=direct;sh=\(sh);th=\(th)"
        }
    }

    nonisolated private func previewKey(_ p: PreviewParams) -> NSString {
        var k = p.url.absoluteString + "|mode=" + p.mode.rawValue + "|" + previewSettingsFingerprint(p)
        // The gain-map–dependent views differ between the mono and RGB gain maps, and the gain map is
        // (optionally) subsampled by `gainMapSubsampleFactor` — which changes both the gain-map view
        // and the reconstructed final-output view. Fold both global prefs into their key so toggling
        // either in Preferences yields a distinct cache entry (the stale one is never returned and
        // gets evicted). The SDR/HDR-input views don't depend on either.
        if p.mode == .gainMap || p.mode == .finalOutput {
            k += "|rgb=\(UserDefaults.standard.bool(forKey: "gainMapRGB"))"
            k += "|gmsub=\(UserDefaults.standard.integer(forKey: "gainMapSubsampleFactor"))"
        }
        return NSString(string: k)
    }

    /// Convenience for callers that already hold live settings on the main actor.
    func previewKey(url: URL, settings: ProcessingSettings, mode: PreviewMode = .sdrTonemapped) -> NSString {
        previewKey(previewParams(url: url, settings: settings, mode: mode))
    }

    /// Cache key for the overlay-composited image. Built from the (opacity-independent) base key plus
    /// the overlay opacity, so each opacity has its own cached composite while the base/stats are shared.
    nonisolated private func overlayKey(_ baseKey: NSString, opacity: Float) -> NSString {
        NSString(string: (baseKey as String) + "|op=\(opacity)")
    }

    /// The cached CIImage actually shown for a given view, if present. Used by the Metal display
    /// path (now all four views) to render the pixels directly. For the SDR view with overlay
    /// opacity > 0, returns the overlay-composited image; otherwise the base / HDR / final / gain-map
    /// image. All of these are populated by `renderPreviewCore`.
    func displayPreviewCIImage(for image: HDRImage, mode: PreviewMode) -> CIImage? {
        let key = previewKey(url: image.url, settings: image.settings, mode: mode)
        let opacity = image.settings.overlayOpacity
        if mode == .sdrTonemapped, opacity > 0,
           let overlay = previewOverlayCache.object(forKey: overlayKey(key, opacity: opacity)) {
            return overlay
        }
        return previewBaseCache.object(forKey: key)
    }
    
    
    static let shared = HDRProcessor()
    
    // Immutable Core Graphics / Core Image resources. CIContext is documented thread-safe
    // and these color spaces are never mutated, so they are safe to use off the main actor.
    nonisolated private let linear_p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    nonisolated private let p3_cs = CGColorSpace(name: CGColorSpace.displayP3)!
    // Color space tag for the manual gain-map aux. Must be an HDR space (PQ), NOT Display P3: iOS's
    // "optimized version" regeneration strips a gain map tagged with an SDR space (Display P3),
    // degrading the photo to SDR on zoom after iCloud sync. The tag is only a classification flag —
    // the HDR reconstruction is governed by the ISO 21496-1 metadata, not this color space (verified
    // bit-identical P3 vs PQ), so it carries no color/primaries risk for mono or RGB gain maps.
    nonisolated private let gainmap_cs = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!

    // Metal-backed histogram calculator (falls back to CPU when unavailable).
    // Internally serialized with an NSLock, so it is safe to call from background tasks.
    nonisolated private let metalHistogram = MetalHistogramCalculator()

    // Shared working context for loading/tone-mapping. A single context is reused across
    // threads (CIContext is thread-safe). Initialized in `init` because it depends on `linear_p3`.
    nonisolated private let ctx_linear_p3: CIContext

    nonisolated private let encode_ctx = CIContext()

    // MARK: Per-worker search resources (batch parallelism)

    /// CIContext / histogram for the current task: per-worker inside a batch (via the
    /// `SearchResourcesContext` task-local), shared singletons otherwise.
    nonisolated private var searchCtx: CIContext { SearchResourcesContext.current?.ctx ?? ctx_linear_p3 }
    nonisolated private var searchHistogram: MetalHistogramCalculator? {
        SearchResourcesContext.current?.histogram ?? metalHistogram
    }

    private init() {
        ctx_linear_p3 = CIContext(options: [.workingColorSpace: linear_p3,
                                            .outputColorSpace: linear_p3])
        let totalRAM = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let maxCacheSizeGB = min(max(Int(Double(totalRAM) * 0.12), 2), 8)  // Min 2GB, Max 8GB
        
        Self.rawDataCache.totalCostLimit = maxCacheSizeGB * 1024
        hdrCache.totalCostLimit = maxCacheSizeGB * 250
        
        // Log for debug
        // print("💾 System has \(totalRAM) GB RAM - cache limit set to \(maxCacheSizeGB) GB")
        
        Self.peakLuminanceCache.countLimit = 100
        Self.percentileCDFCache.countLimit = 100
        previewBaseCache.countLimit = 32
        previewOverlayCache.countLimit = 32
        previewCountsCache.countLimit = 64
        previewDetailedCache.countLimit = 64
    }
    
    // MARK: - Public API
    
    // Convenience overload that preserves the original API:
    func generatePreview(for image: HDRImage) async throws -> NSImage {
        try await generatePreview(for: image, mode: .sdrTonemapped, reportClipping: nil)
    }

    // Nuova versione con callback

    func generatePreview(
        for image: HDRImage,
        mode: PreviewMode = .sdrTonemapped,
        reportClipping: ((Int, Int, DetailedClippingStats?) -> Void)?
    ) async throws -> NSImage {

        // Snapshot the live settings on the main actor before any off-main work.
        let params = previewParams(url: image.url, settings: image.settings, mode: mode)
        let baseKey = previewKey(params)
        let file = params.url.lastPathComponent

        // Non-SDR views (HDR input / final output / gain map) carry no clipping overlay; a single
        // rendered CIImage is cached per (mode, settings) key. The SDR clipping stats are computed
        // separately (see `sdrClippingStats`) so the legend & count stay available here too.
        if mode != .sdrTonemapped {
            if let cached = previewBaseCache.object(forKey: baseKey) {
                let t = Prof.tic()
                defer { Prof.toc("preview modeHit→NSImage [\(file)]", t) }
                return try ciImageToNSImage(cached, hdr: mode.isHDR)
            }
            let t = Prof.tic()
            let r = try await renderPreviewCore(params: params, baseKey: baseKey)
            Prof.toc("preview MISS renderCore [\(file)]", t)
            return r.image
        }

        let wantOverlay = params.overlayOpacity > 0

        // Cached clipping stats for this settings key (available regardless of overlay opacity).
        let cachedDetailed = previewDetailedCache.object(forKey: baseKey)?.stats
        let cachedCounts = previewCountsCache.object(forKey: baseKey) as? [String: Int]

        // 1) HIT overlay? (keyed by opacity — the composite depends on it.)
        if wantOverlay, let cachedOverlay = previewOverlayCache.object(forKey: overlayKey(baseKey, opacity: params.overlayOpacity)) {
            if let c = cachedCounts?["c"], let t = cachedCounts?["t"] {
                reportClipping?(c, t, cachedDetailed)
            } else {
                reportClipping?(0, 0, cachedDetailed)
            }
            let t = Prof.tic()
            defer { Prof.toc("preview overlayHit→NSImage [\(file)]", t) }
            return try ciImageToNSImage(cachedOverlay)
        }

        // 2) HIT base?
        if !wantOverlay, let cachedBase = previewBaseCache.object(forKey: baseKey) {
            if let c = cachedCounts?["c"], let t = cachedCounts?["t"] {
                reportClipping?(c, t, cachedDetailed)
            } else {
                reportClipping?(0, 0, cachedDetailed)
            }
            let t = Prof.tic()
            defer { Prof.toc("preview baseHit→NSImage [\(file)]", t) }
            return try ciImageToNSImage(cachedBase)
        }

        // 3) MISS → render off the main actor (load + tone-map + overlay) so the UI stays
        //    responsive; only the cache lookups above run on the main actor.
        let t = Prof.tic()
        let r = try await renderPreviewCore(params: params, baseKey: baseKey)
        Prof.toc("preview MISS renderCore [\(file)]", t)
        reportClipping?(r.clipped, r.total, r.detailed)
        return r.image
    }

    /// Heavy preview rendering: loads the HDR image, tone-maps it, optionally builds the clipping
    /// overlay, populates the preview caches, and returns the final image plus clipping counts.
    /// `@concurrent` forces this onto the global executor (never the caller's actor), so it always
    /// runs off the main thread even with `NonisolatedNonsendingByDefault` enabled.
    @concurrent nonisolated private func renderPreviewCore(
        params: PreviewParams,
        baseKey: NSString
    ) async throws -> (image: NSImage, clipped: Int, total: Int, detailed: DetailedClippingStats?) {

        let file = params.url.lastPathComponent

        // Cooperative cancellation: when a new selection supersedes a background prefetch, bail at
        // stage boundaries instead of finishing a multi-second render that would contend for
        // CPU/GPU (and the Metal lock) with the foreground work. The foreground render task is not
        // cancelled, so these checks are no-ops for it.
        try Task.checkCancellation()

        let tLoad = Prof.tic()
        let hdr = try loadHDR(url: params.url)
        Prof.toc("renderCore.loadHDR [\(file)]", tLoad)

        try Task.checkCancellation()

        // Compute headroom using the shared, consistent method.
        let tHead = Prof.tic()
        let measuredHeadroom = getHeadroomForImage(url: params.url)
        Prof.toc("renderCore.headroom [\(file)]", tHead)

        try Task.checkCancellation()

        // HDR-input view: no tone-mapping, no overlay — render the source HDR through the EDR path.
        if params.mode == .hdrInput {
            previewBaseCache.setObject(hdr, forKey: baseKey)
            let tRender = Prof.tic()
            defer { Prof.toc("renderCore.render→NSImage(hdrInput) [\(file)]", tRender) }
            return (try ciImageToNSImage(hdr, hdr: true), 0, 0, nil)
        }

        let tTone = Prof.tic()
        let sdrBase = try await buildSDRBase(hdr: hdr, params: params, measuredHeadroom: measuredHeadroom)
        // tonemap_sdr builds a lazy CIImage graph; its real cost materializes in the
        // ciImageToNSImage render below. This measures graph construction only.
        Prof.toc("renderCore.tonemapBuild [\(file)]", tTone)

        // Final-output / gain-map views round-trip the SDR base + HDR through an in-memory HEIF
        // encode (skipping the on-disk write + ISO conversion the real export performs). They
        // carry no clipping overlay; cache only the finished product under the mode-specific key.
        switch params.mode {
        case .finalOutput:
            try Task.checkCancellation()
            let tEnc = Prof.tic()
            let reconstructed = try reconstructHDRFromGainMap(sdrBase: sdrBase, hdr: hdr)
            Prof.toc("renderCore.finalOutputEncode [\(file)]", tEnc)
            previewBaseCache.setObject(reconstructed, forKey: baseKey)
            let tRender = Prof.tic()
            defer { Prof.toc("renderCore.render→NSImage(finalOutput) [\(file)]", tRender) }
            return (try ciImageToNSImage(reconstructed, hdr: true), 0, 0, nil)

        case .gainMap:
            try Task.checkCancellation()
            let tEnc = Prof.tic()
            let gm = try extractGainMapImage(sdrBase: sdrBase, hdr: hdr)
            Prof.toc("renderCore.gainMapEncode [\(file)]", tEnc)
            previewBaseCache.setObject(gm, forKey: baseKey)
            let tRender = Prof.tic()
            defer { Prof.toc("renderCore.render→NSImage(gainMap) [\(file)]", tRender) }
            return (try ciImageToNSImage(gm, hdr: false), 0, 0, nil)

        case .sdrTonemapped, .hdrInput:
            break  // hdrInput already returned above; sdrTonemapped continues below.
        }

        previewBaseCache.setObject(sdrBase, forKey: baseKey)

        // Clipping stats are opacity-independent: reuse the cached counts/detailed for this settings
        // key if present (e.g. an opacity-only change), else compute them once (counting renders) and
        // cache them. This keeps the legend & stats available regardless of the overlay opacity.
        try Task.checkCancellation()
        let clipped: Int
        let total: Int
        let detailed: DetailedClippingStats?
        if let cachedDetailed = previewDetailedCache.object(forKey: baseKey)?.stats,
           let counts = previewCountsCache.object(forKey: baseKey) as? [String: Int],
           let c = counts["c"], let t = counts["t"] {
            clipped = c; total = t; detailed = cachedDetailed
        } else {
            let tCount = Prof.tic()
            let stats = computeClippingStats(sdr: sdrBase, context: ctx_linear_p3)
            Prof.toc("renderCore.clipCount [\(file)]", tCount)
            clipped = stats?.clipped ?? 0
            total = stats?.total ?? 0
            detailed = stats?.detailedStats
            if let detailed {
                previewDetailedCache.setObject(DetailedStatsBox(detailed), forKey: baseKey)
                previewCountsCache.setObject(["c": clipped, "t": total] as NSDictionary, forKey: baseKey)
            }
        }

        // Overlay opacity > 0 → build & cache the composited image (keyed by opacity); else the base.
        if params.overlayOpacity > 0 {
            let tOverlay = Prof.tic()
            let composite = buildClippingOverlayImage(sdr: sdrBase, opacity: CGFloat(params.overlayOpacity))
            Prof.toc("renderCore.overlayBuild [\(file)]", tOverlay)
            previewOverlayCache.setObject(composite, forKey: overlayKey(baseKey, opacity: params.overlayOpacity))
            let tRender = Prof.tic()
            defer { Prof.toc("renderCore.render→NSImage [\(file)]", tRender) }
            return (try ciImageToNSImage(composite), clipped, total, detailed)
        } else {
            let tRender = Prof.tic()
            defer { Prof.toc("renderCore.render→NSImage [\(file)]", tRender) }
            return (try ciImageToNSImage(sdrBase), clipped, total, detailed)
        }
    }

    /// Builds the tone-mapped SDR base for the given settings snapshot. Shared by the SDR preview,
    /// the HDR/final/gain-map views' encode step, and the clipping-stats computation, so they all
    /// stay in lock-step.
    nonisolated private func buildSDRBase(hdr: CIImage, params: PreviewParams, measuredHeadroom: Float) async throws -> CIImage {
        switch params.method {
        case .peakMax:
            let derivedHeadroom = max(1.0, 1.0 + measuredHeadroom - powf(measuredHeadroom, params.tonemapRatio))
            let targetHeadroom = params.targetHeadroom ?? 1.0
            guard let s = tonemap_sdr(from: hdr, sourceHeadroom: derivedHeadroom, targetHeadroom: targetHeadroom) else {
                throw ProcessingError.tonemapFailed
            }
            return s

        case .percentile:
            let percentileHeadroom = try await percentileHeadroom(url: params.url, percentile: params.percentile)
            let targetHeadroom = params.targetHeadroom ?? 1.0
            guard let s = tonemap_sdr(from: hdr, sourceHeadroom: percentileHeadroom, targetHeadroom: targetHeadroom) else {
                throw ProcessingError.tonemapFailed
            }
            return s

        case .direct:
            let sH = params.directSourceHeadroom ?? measuredHeadroom
            let tH = params.targetHeadroom ?? 1.0
            let maxLimit = max(1.0, measuredHeadroom * 2.0)
            let sH_clamped = min(max(sH, 0.1), maxLimit)
            let tH_clamped = min(max(tH, 0.1), maxLimit)
            guard let s = tonemap_sdr(from: hdr, sourceHeadroom: sH_clamped, targetHeadroom: tH_clamped) else {
                throw ProcessingError.tonemapFailed
            }
            return s
        }
    }

    /// Computes (or returns cached) the SDR-output clipping statistics for the given settings,
    /// independent of the current preview view. The legend and the clipped-pixel count describe the
    /// SDR output, so they stay available in the HDR / gain-map views too (like the histograms).
    @concurrent nonisolated func sdrClippingStats(for params: PreviewParams) async throws -> (clipped: Int, total: Int, detailed: DetailedClippingStats?) {
        // Stats depend only on the URL + tone-map settings; key them under the SDR view, where the
        // SDR preview render also caches them, so the two paths share results.
        let sdrParams = PreviewParams(
            url: params.url,
            method: params.method,
            tonemapRatio: params.tonemapRatio,
            percentile: params.percentile,
            directSourceHeadroom: params.directSourceHeadroom,
            targetHeadroom: params.targetHeadroom,
            overlayOpacity: params.overlayOpacity,
            mode: .sdrTonemapped
        )
        let key = previewKey(sdrParams)

        if let detailed = previewDetailedCache.object(forKey: key)?.stats,
           let counts = previewCountsCache.object(forKey: key) as? [String: Int],
           let c = counts["c"], let t = counts["t"] {
            return (c, t, detailed)
        }

        try Task.checkCancellation()
        let hdr = try loadHDR(url: sdrParams.url)
        let measuredHeadroom = getHeadroomForImage(url: sdrParams.url)
        let sdrBase = try await buildSDRBase(hdr: hdr, params: sdrParams, measuredHeadroom: measuredHeadroom)
        previewBaseCache.setObject(sdrBase, forKey: key)

        try Task.checkCancellation()
        let stats = computeClippingStats(sdr: sdrBase, context: ctx_linear_p3)
        let clipped = stats?.clipped ?? 0
        let total = stats?.total ?? 0
        let detailed = stats?.detailedStats
        if let detailed {
            previewDetailedCache.setObject(DetailedStatsBox(detailed), forKey: key)
            previewCountsCache.setObject(["c": clipped, "t": total] as NSDictionary, forKey: key)
        }
        return (clipped, total, detailed)
    }

    /// Warms the caches for `image` (raw bytes, headroom, percentile CDF, preview base/overlay)
    /// entirely off the main actor, so a later selection of this image is near-instant.
    /// Best-effort: returns silently on cancellation or failure.
    nonisolated func prewarm(params: PreviewParams) async {
        let baseKey = previewKey(params)

        // Warm the preview (base/overlay) unless already cached for these settings.
        let previewWarm = params.overlayOpacity > 0
            ? previewOverlayCache.object(forKey: overlayKey(baseKey, opacity: params.overlayOpacity)) != nil
            : previewBaseCache.object(forKey: baseKey) != nil
        if !previewWarm {
            if Task.isCancelled { return }
            _ = try? await renderPreviewCore(params: params, baseKey: baseKey)
        }

        // Warm the HDR-input histogram too: it depends only on the source image (not the
        // tone-map settings), and the foreground selection otherwise recomputes it (~320 ms)
        // on every navigation. Caching it here makes that a hit.
        if Task.isCancelled { return }
        _ = try? await histogramForHDRInput(url: params.url)
    }
    
    /// Exports a single image as HEIC with gain map
    func exportImage(_ image: HDRImage, to outputURL: URL) async throws {
        
        let hdr = try loadHDR(url: image.url)
        
        // Compute headroom using the shared, consistent method.
        let measuredHeadroom = getHeadroomForImage(url: image.url)
        
        // Tonemap SDR base
        var sdr: CIImage?

        // Get target headroom (common to all methods)
        let targetHeadroom = image.settings.targetHeadroom ?? 1.0

        switch image.settings.sourceHeadroomMethod {
        case .peakMax:
            let calculated = max(1.0, 1.0 + measuredHeadroom - powf(measuredHeadroom, image.settings.tonemapRatio))
            sdr = tonemap_sdr(from: hdr, sourceHeadroom: calculated, targetHeadroom: targetHeadroom)

        case .percentile:
            let percentileHeadroom = try await percentileHeadroom(url: image.url, percentile: image.settings.percentile)
            sdr = tonemap_sdr(from: hdr, sourceHeadroom: percentileHeadroom, targetHeadroom: targetHeadroom)

        case .direct:
            let sH = image.settings.directSourceHeadroom ?? measuredHeadroom
            let tH = targetHeadroom

            let maxLimit = max(1.0, measuredHeadroom * 2.0)
            let sH_clamped = min(max(sH, 0.1), maxLimit)
            let tH_clamped = min(max(tH, 0.1), maxLimit)

            sdr = tonemap_sdr(from: hdr, sourceHeadroom: sH_clamped, targetHeadroom: tH_clamped)
        }
        
        guard let sdrBase = sdr else {
            throw ProcessingError.tonemapFailed
        }

        // Extract metadata from the original HDR PNG file
        let originalMetadata = extractMetadata(from: image.url)
        // print("📋 Extracted \(originalMetadata.count) metadata dictionaries from original file")
        
        var props = originalMetadata

        // ISO 21496-1 output requires Core Image to emit the modern HDRToneMap scheme, which it
        // does precisely when the legacy Apple MakerNote headroom tags (33 & 48) are ABSENT.
        // Strip them in case the source file carried them.
        if var maker_apple = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] {
            maker_apple["33"] = nil
            maker_apple["48"] = nil
            props[kCGImagePropertyMakerAppleDictionary as String] = maker_apple
        }

        // Append to Software metadata
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "<undetermined>"
        if let originalSoftware = tiff["Software"] as? String, !originalSoftware.isEmpty {
            // Append to existing value
            tiff["Software"] = "\(originalSoftware) + HDR2gainmap App v\(appVersion)"
        } else {
            // No existing value
            tiff["Software"] = "HDR2gainmapApp v\(appVersion)"
        }
        props[kCGImagePropertyTIFFDictionary as String] = tiff

        // Currently the app is not allowing for resizing -- should this change in the future, un-comment this!
//        let extent = sdrBase.extent
//        props[kCGImagePropertyPixelWidth as String] = Int(extent.width)
//        props[kCGImagePropertyPixelHeight as String] = Int(extent.height)
        
        // RGB gain map (strada B): compute a 3-channel ISO 21496-1 gain map ourselves
        // and assemble the HEIC by hand. Core Image emits only a luma gain map on macOS 15 (RGB is
        // macOS 26+), so when this opt-in pref is set we bypass the Core Image embed + ISO re-encode
        // and write the per-channel gain directly. The SDR base is identical to the mono path's —
        // only the gain map differs.
        if UserDefaults.standard.bool(forKey: "gainMapRGB") {
            try writeRGBGainMapHEIC(hdr: hdr, sdrBase: sdrBase, baseProps: props, to: outputURL)
            return
        }

        // Default mono path: a luma gain map we hand-assemble ourselves, with the aux color space set
        // by us to Display P3 (see `writeMonoManualGainMapHEIC`). The Core Image mono path below —
        // which lets Core Image compute the gain map and tag it PQ — is now an opt-in LEGACY route,
        // selected only via the CLI flag `--mono-coreimage` (UserDefaults `gainMapMonoCoreImage`).
        if !UserDefaults.standard.bool(forKey: "gainMapMonoCoreImage") {
            try writeMonoManualGainMapHEIC(hdr: hdr, sdrBase: sdrBase, baseProps: props, to: outputURL)
            return
        }

        // --- Legacy Core Image mono path (opt-in via `gainMapMonoCoreImage`) ---
        let sdr_with_props = sdrBase.settingProperties(props)

        // Read quality from UserDefaults (set in Preferences)
        let heicQuality = UserDefaults.standard.double(forKey: "heicExportQuality")
        let quality = (heicQuality > 0) ? heicQuality : 0.95  // Fallback to 0.95 if not set
        
        // Encode the SDR base + gain map into an in-memory HEIC. Core Image computes the (luma,
        // monochrome) gain map from the HDR source here; we no longer pre-extract it. This buffer
        // is the intermediate that `convertToISOGainMap` re-encodes into the ISO 21496-1 layout —
        // keeping it in RAM saves a full disk write (the old on-disk file was written only to be
        // re-read immediately).
        let export_options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality,
            CIImageRepresentationOption.hdrGainMapAsRGB: false,
            CIImageRepresentationOption.hdrImage: hdr
        ]

        let heifData: Data
        if #available(macOS 26.0, *) {
            heifData = try encode_ctx.heif10Representation(of: sdr_with_props,
                                                           colorSpace: p3_cs,
                                                           options: export_options)
        } else {
            guard let d = encode_ctx.heifRepresentation(of: sdr_with_props,
                                                        format: .RGB10,
                                                        colorSpace: p3_cs,
                                                        options: export_options) else {
                throw ProcessingError.gainMapGenerationFailed
            }
            heifData = d
        }

        // Re-encode so the gain map lands in the ISO 21496-1 auxiliary slot
        // (kCGImageAuxiliaryDataTypeISOGainMap). ImageIO translates the HDRToneMap metadata
        // into the standard ISO binary metadata box, recognized by Adobe's Gain Map Demo App
        // while still rendering correctly on iOS 26 / macOS 15+. This is the only write to disk.
        try convertToISOGainMap(from: heifData, to: outputURL)

    }

    // MARK: - ISO 21496-1 Gain Map Conversion

    /// Re-encode the in-memory HEIC so its gain map is stored as a standard ISO 21496-1
    /// gain map (`kCGImageAuxiliaryDataTypeISOGainMap`) instead of the Apple-proprietary
    /// `kCGImageAuxiliaryDataTypeHDRGainMap` slot, writing the result to `url`.
    ///
    /// Available on macOS 15+ via `CGImageDestination` with `kCGImageDestinationEncodeToISOGainmap`.
    /// We read back the gain map Core Image wrote (Apple HDRGainMap aux + HDRToneMap metadata),
    /// add it under the ISO aux type, and let ImageIO emit the spec-correct ISO 21496-1 binary
    /// metadata. The HDR reconstruction is preserved (verified: identical peak luminance).
    ///
    /// `sourceData` is the HEIC Core Image just encoded in RAM, so this is the single disk write.
    private func convertToISOGainMap(from sourceData: Data, to url: URL) throws {
        guard let src = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw ProcessingError.isoConversionFailed("[A] CGImageSourceCreateWithData nil for \(url.lastPathComponent)")
        }

        // The gain map Core Image just wrote. Where it lands depends on how it was produced:
        // letting Core Image compute it via `.hdrImage` (as we now do) puts it under the ISO gain
        // map aux type, whereas an explicit `.hdrGainMapImage` embed used the Apple HDRGainMap slot.
        // Verified on macOS 15 (`heifRepresentation(format:.RGB10)`); the macOS 26
        // `heif10Representation` branch is only exercisable via CI, so accept EITHER slot — we
        // re-emit it as ISO below (subsampled) regardless.
        let rawAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
                  ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap)
        guard var auxDict = rawAux as? [String: Any] else {
            // Enumerate other aux types so we can tell whether the gain map landed elsewhere.
            let probes: [(String, CFString)] = [
                ("ISO",     kCGImageAuxiliaryDataTypeISOGainMap),
                ("Depth",   kCGImageAuxiliaryDataTypeDepth),
                ("Portrait", kCGImageAuxiliaryDataTypePortraitEffectsMatte)
            ]
            let present = probes
                .filter { CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, $0.1) != nil }
                .map { $0.0 }
            let presentStr = present.isEmpty ? "none" : present.joined(separator: ",")
            throw ProcessingError.isoConversionFailed("[B] no HDRGainMap aux readable from in-memory HEIC for \(url.lastPathComponent) (other aux present: \(presentStr))")
        }

        // Optionally subsample the gain map. Controlled by the `gainMapSubsampleFactor`
        // preference (default 1 = full resolution); 2 halves it to shrink the file, at the cost
        // of softened highlight detail (where the gain map does most of its work).
        let storedFactor = UserDefaults.standard.integer(forKey: "gainMapSubsampleFactor")
        let subsampleFactor = storedFactor > 0 ? storedFactor : 1
        if subsampleFactor > 1, let smaller = downsampleGainMapAux(auxDict, factor: subsampleFactor) {
            auxDict = smaller
        }

        guard let base = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ProcessingError.isoConversionFailed("[C] CGImageSourceCreateImageAtIndex nil for \(url.lastPathComponent)")
        }

        let heicQuality = UserDefaults.standard.double(forKey: "heicExportQuality")
        let quality = (heicQuality > 0) ? heicQuality : 0.95

        // Carry over the original image properties (Exif/TIFF/GPS/…) and request ISO encoding.
        var imgProps = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        imgProps[kCGImageDestinationEncodeRequest as String] = kCGImageDestinationEncodeToISOGainmap
        imgProps[kCGImageDestinationLossyCompressionQuality as String] = quality

        let utType = CGImageSourceGetType(src) ?? ("public.heic" as CFString)
        // Encode in memory, then write the bytes to the user-chosen `url` with a NON-ATOMIC write.
        // Both CGImageDestinationCreateWithURL and an atomic write safe-save via a sibling temp
        // (`<name>.sb-xxxxxx`) in the destination *directory*, which a file-scoped NSSavePanel grant
        // doesn't permit → ImageIO "cannot create … Operation not permitted". A non-atomic write
        // opens the exact granted path, so single "Export Current Image" to ~/Desktop works (and so
        // does output on an external volume — no cross-device move involved).
        let buffer = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(buffer as CFMutableData, utType, 1, nil) else {
            throw ProcessingError.isoConversionFailed("[D] CGImageDestinationCreateWithData nil, utType=\(utType)")
        }
        CGImageDestinationAddImage(dst, base, imgProps as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(dst, kCGImageAuxiliaryDataTypeISOGainMap, auxDict as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            throw ProcessingError.isoConversionFailed("[G] CGImageDestinationFinalize returned false")
        }
        do {
            try (buffer as Data).write(to: url, options: [])
        } catch {
            throw ProcessingError.isoConversionFailed("[I] write to \(url.lastPathComponent): \(error)")
        }
    }
    
    
    /// Downsample a gain-map auxiliary dictionary by an integer `factor`, returning a new
    /// dictionary with the resized pixel buffer and an updated data description. Only handles
    /// the 8-bit single-channel (`L008`) gain maps this pipeline produces; returns nil for
    /// anything else (caller then embeds the gain map unchanged).
    // MARK: - RGB Gain Map (opt-in via `gainMapRGB`)

    /// Build a 3-channel (RGB) ISO 21496-1 gain map ourselves and assemble the HEIC by hand,
    /// writing it to `url`. Core Image only emits a luma gain map on macOS 15 (RGB is macOS 26+),
    /// so instead of asking it to compute/embed the gain map we render the per-channel gain, build
    /// the `ChannelMetadata` XMP, and attach the payload via `CGImageDestinationAddAuxiliaryDataInfo`
    /// with the ISO gain map aux type. `sdrBase` is the same tone-mapped base the mono path uses —
    /// only the gain map differs. `baseProps` carries the preserved Exif/TIFF/GPS (MakerApple 33/48
    /// already stripped by the caller). Verified on macOS 15 Intel (reconstructs in Core Image and
    /// validates in Adobe's Gain Map Demo App).
    private func writeRGBGainMapHEIC(hdr: CIImage, sdrBase: CIImage,
                                     baseProps: [String: Any], to url: URL) throws {
        let heicQuality = UserDefaults.standard.double(forKey: "heicExportQuality")
        let quality = (heicQuality > 0) ? heicQuality : 0.95

        // Subsample the gain map per the shared preference (default 2). Computing it at reduced
        // resolution both honors the setting and cuts the per-pixel CPU cost; a gain map is
        // smooth/low-detail so the visual impact is minimal. (`downsampleGainMapAux` is L008-only,
        // so the RGB path can't reuse it — we subsample at compute time instead.)
        let storedFactor = UserDefaults.standard.integer(forKey: "gainMapSubsampleFactor")
        let subsampleFactor = storedFactor > 0 ? storedFactor : 1

        guard let data = encodeRGBGainMapHEICData(hdr: hdr, sdrBase: sdrBase, baseProps: baseProps,
                                                  subsampleFactor: subsampleFactor, quality: quality) else {
            throw ProcessingError.gainMapGenerationFailed
        }

        // Non-atomic write to the user-chosen `url` (carries the NSSavePanel grant). An atomic write /
        // CGImageDestinationCreateWithURL safe-saves via a sibling temp in the destination *directory*,
        // which a file-scoped grant doesn't cover — EPERM for single "Export Current Image" to ~/Desktop.
        do {
            try data.write(to: url, options: [])
        } catch {
            throw ProcessingError.isoConversionFailed("[RGB-C] write to \(url.lastPathComponent): \(error)")
        }
    }

    /// Encode the SDR base + a 3-channel (RGB) ISO 21496-1 gain map into an in-memory HEIC `Data`.
    /// Shared by the RGB exporter (`writeRGBGainMapHEIC`) and the RGB `.finalOutput` preview, so both
    /// reconstruct from the exact same bytes. Core Image only emits a luma gain map on macOS 15 (RGB
    /// is macOS 26+), so we render the per-channel gain, build the `ChannelMetadata` XMP, and attach
    /// the payload via `CGImageDestinationAddAuxiliaryDataInfo` with the ISO gain map aux type.
    /// Verified on macOS 15 Intel (reconstructs in Core Image and validates in Adobe's Gain Map Demo App).
    nonisolated private func encodeRGBGainMapHEICData(hdr: CIImage, sdrBase: CIImage,
                                                      baseProps: [String: Any],
                                                      subsampleFactor: Int, quality: Double) -> Data? {
        guard let gm = computeRGBGainMap(hdr: hdr, sdr: sdrBase, factor: subsampleFactor) else { return nil }
        guard let meta = isoGainMapMetadata(channels: 3, gainMapMaxStops: gm.gainMapMaxStops) else { return nil }
        guard let baseCG = encode_ctx.createCGImage(sdrBase, from: sdrBase.extent,
                                                    format: .RGB10, colorSpace: p3_cs) else { return nil }

        let desc: [String: Any] = [
            "PixelFormat": Int(kCVPixelFormatType_32ARGB),
            "Width": gm.width, "Height": gm.height, "BytesPerRow": gm.width * 4,
        ]
        let aux: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: gm.data,
            kCGImageAuxiliaryDataInfoDataDescription: desc,
            kCGImageAuxiliaryDataInfoMetadata: meta,
            kCGImageAuxiliaryDataInfoColorSpace: gainmap_cs,       // ← PQ, so iOS keeps the gain map (see gainmap_cs)
        ]

        var imgProps = baseProps
        imgProps[kCGImageDestinationLossyCompressionQuality as String] = quality

        let buffer = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(buffer as CFMutableData, "public.heic" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dst, baseCG, imgProps as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(dst, kCGImageAuxiliaryDataTypeISOGainMap, aux as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return buffer as Data
    }

    /// Compute a per-channel (RGB) gain map from the HDR source and tone-mapped SDR base at
    /// `1/factor` resolution. Returns the ARGB8 payload bytes (A=255), its dimensions, and the gain
    /// map max in stops (`log2(peak)`). Per-channel ratio: `clamp(log2((hdr+k)/(min(sdr,1)+k)) /
    /// log2(peak), 0, 1)` with `k = 1e-5` (the validated prototype's formula).
    nonisolated private func computeRGBGainMap(hdr: CIImage, sdr: CIImage, factor: Int)
        -> (data: Data, width: Int, height: Int, gainMapMaxStops: Float)? {
        let f = max(1, factor)
        let baseExtent = sdr.extent
        // The gain map MUST have even width & height: ImageIO re-encodes this aux as YUV 4:2:0 (chroma
        // subsampled ×2), and an odd dimension misaligns the chroma plane stride → a corrupt gain map
        // (green cast + vertical bands). Cropped exports often have odd dimensions, so this surfaced
        // "randomly". Round each axis down to even (matches toGainMapHDR's `makeEvenSized`).
        let rawW = max(2, Int(baseExtent.width.rounded()) / f)
        let rawH = max(2, Int(baseExtent.height.rounded()) / f)
        let w = rawW - (rawW % 2)
        let h = rawH - (rawH % 2)

        let scaleX = CGFloat(w) / baseExtent.width
        let scaleY = CGFloat(h) / baseExtent.height
        let hdrS = hdr.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let sdrS = sdr.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var hdrBuf = [Float](repeating: 0, count: w * h * 4)
        var sdrBuf = [Float](repeating: 0, count: w * h * 4)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        encode_ctx.render(hdrS, toBitmap: &hdrBuf, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: linear_p3)
        encode_ctx.render(sdrS, toBitmap: &sdrBuf, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: linear_p3)

        var picHeadroom: Float = 1.0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            picHeadroom = max(picHeadroom, hdrBuf[i], hdrBuf[i + 1], hdrBuf[i + 2])
        }
        let gmaxStops = log2(picHeadroom)
        guard gmaxStops > 0, gmaxStops.isFinite else { return nil }

        let k: Float = 0.00001
        func ch(_ hvIn: Float, _ svIn: Float) -> UInt8 {
            let hv = max(hvIn, 0), s = min(max(svIn, 0), 1)
            var r = log2((hv + k) / (s + k)) / gmaxStops
            if !r.isFinite { r = 0 }
            return UInt8((min(max(r, 0), 1) * 255).rounded())
        }
        var argb = [UInt8](repeating: 0, count: w * h * 4)
        for p in 0..<(w * h) {
            let i = p * 4
            argb[i] = 255
            argb[i + 1] = ch(hdrBuf[i],     sdrBuf[i])
            argb[i + 2] = ch(hdrBuf[i + 1], sdrBuf[i + 1])
            argb[i + 3] = ch(hdrBuf[i + 2], sdrBuf[i + 2])
        }
        return (Data(argb), w, h, gmaxStops)
    }

    // MARK: - Manual mono gain map (DEFAULT mono path; Display P3)

    /// Build a luma (monochrome) ISO 21496-1 gain map ourselves and assemble the HEIC by hand,
    /// writing it to `url`. Same road as `writeRGBGainMapHEIC` — we render the gain, attach the aux
    /// via `CGImageDestinationAddAuxiliaryDataInfo` — but a single luma channel, and crucially WITH
    /// the aux color space set by us (Display P3) instead of letting Core Image pick it (the legacy
    /// Core Image mono path ends up tagged PQ). This is now the DEFAULT for monochrome gain maps in
    /// both the GUI and the CLI; the Core Image path is opt-in via `--mono-coreimage`. `sdrBase` is
    /// the same tone-mapped base the other paths use — only the gain map differs.
    private func writeMonoManualGainMapHEIC(hdr: CIImage, sdrBase: CIImage,
                                            baseProps: [String: Any], to url: URL) throws {
        let heicQuality = UserDefaults.standard.double(forKey: "heicExportQuality")
        let quality = (heicQuality > 0) ? heicQuality : 0.95

        let storedFactor = UserDefaults.standard.integer(forKey: "gainMapSubsampleFactor")
        let subsampleFactor = storedFactor > 0 ? storedFactor : 1

        guard let data = encodeMonoManualGainMapHEICData(hdr: hdr, sdrBase: sdrBase, baseProps: baseProps,
                                                         subsampleFactor: subsampleFactor, quality: quality) else {
            throw ProcessingError.gainMapGenerationFailed
        }

        // Non-atomic write to the granted `url` (same sandbox rationale as `writeRGBGainMapHEIC`).
        do {
            try data.write(to: url, options: [])
        } catch {
            throw ProcessingError.isoConversionFailed("[MONO-C] write to \(url.lastPathComponent): \(error)")
        }
    }

    /// Encode the SDR base + a single-channel (luma) ISO 21496-1 gain map into an in-memory HEIC
    /// `Data`. Mirrors `encodeRGBGainMapHEICData` but emits an `L008` (8-bit, 1-channel) aux and tags
    /// it Display P3 (`p3_cs`) ourselves, with 1-channel `ChannelMetadata`.
    nonisolated private func encodeMonoManualGainMapHEICData(hdr: CIImage, sdrBase: CIImage,
                                                             baseProps: [String: Any],
                                                             subsampleFactor: Int, quality: Double) -> Data? {
        guard let gm = computeMonoGainMap(hdr: hdr, sdr: sdrBase, factor: subsampleFactor) else { return nil }
        guard let meta = isoGainMapMetadata(channels: 1, gainMapMaxStops: gm.gainMapMaxStops) else { return nil }
        guard let baseCG = encode_ctx.createCGImage(sdrBase, from: sdrBase.extent,
                                                    format: .RGB10, colorSpace: p3_cs) else { return nil }

        let desc: [String: Any] = [
            "PixelFormat": Int(kCVPixelFormatType_OneComponent8),   // 'L008' = 8-bit single-channel luma
            "Width": gm.width, "Height": gm.height, "BytesPerRow": gm.width,
        ]
        let aux: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: gm.data,
            kCGImageAuxiliaryDataInfoDataDescription: desc,
            kCGImageAuxiliaryDataInfoMetadata: meta,
            kCGImageAuxiliaryDataInfoColorSpace: gainmap_cs,       // ← PQ, so iOS keeps the gain map (see gainmap_cs)
        ]

        var imgProps = baseProps
        imgProps[kCGImageDestinationLossyCompressionQuality as String] = quality

        let buffer = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(buffer as CFMutableData, "public.heic" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dst, baseCG, imgProps as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(dst, kCGImageAuxiliaryDataTypeISOGainMap, aux as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return buffer as Data
    }

    /// Compute a luma (monochrome) gain map from the HDR source and tone-mapped SDR base at
    /// `1/factor` resolution. Returns the `L008` payload (1 byte/px), its dimensions, and the gain
    /// map max in stops. Luma uses Display-P3/D65 weights; per-pixel ratio mirrors `computeRGBGainMap`:
    /// `clamp(log2((Yhdr+k)/(min(Ysdr,1)+k)) / log2(peak), 0, 1)` with `k = 1e-5`.
    nonisolated private func computeMonoGainMap(hdr: CIImage, sdr: CIImage, factor: Int)
        -> (data: Data, width: Int, height: Int, gainMapMaxStops: Float)? {
        let f = max(1, factor)
        let baseExtent = sdr.extent
        // Even dimensions (same rationale as computeRGBGainMap: ImageIO chroma alignment).
        let rawW = max(2, Int(baseExtent.width.rounded()) / f)
        let rawH = max(2, Int(baseExtent.height.rounded()) / f)
        let w = rawW - (rawW % 2)
        let h = rawH - (rawH % 2)

        let scaleX = CGFloat(w) / baseExtent.width
        let scaleY = CGFloat(h) / baseExtent.height
        let hdrS = hdr.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let sdrS = sdr.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var hdrBuf = [Float](repeating: 0, count: w * h * 4)
        var sdrBuf = [Float](repeating: 0, count: w * h * 4)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        encode_ctx.render(hdrS, toBitmap: &hdrBuf, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: linear_p3)
        encode_ctx.render(sdrS, toBitmap: &sdrBuf, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: linear_p3)

        // Display-P3 / D65 luminance weights.
        let wr: Float = 0.2290, wg: Float = 0.6917, wb: Float = 0.0793
        func luma(_ b: [Float], _ i: Int) -> Float {
            return max(0, wr * b[i] + wg * b[i + 1] + wb * b[i + 2])
        }

        var picHeadroom: Float = 1.0
        for p in 0..<(w * h) {
            picHeadroom = max(picHeadroom, luma(hdrBuf, p * 4))
        }
        let gmaxStops = log2(picHeadroom)
        guard gmaxStops > 0, gmaxStops.isFinite else { return nil }

        let k: Float = 0.00001
        var gray = [UInt8](repeating: 0, count: w * h)
        for p in 0..<(w * h) {
            let i = p * 4
            let hv = luma(hdrBuf, i)
            let s = min(max(luma(sdrBuf, i), 0), 1)
            var r = log2((hv + k) / (s + k)) / gmaxStops
            if !r.isFinite { r = 0 }
            gray[p] = UInt8((min(max(r, 0), 1) * 255).rounded())
        }
        return (Data(gray), w, h, gmaxStops)
    }

    /// Build the ISO 21496-1 HDRToneMap gain map metadata (XMP → CGImageMetadata) with `channels`
    /// entries in the ChannelMetadata sequence (3 for RGB, 1 for mono). `gainMapMaxStops` is the
    /// per-channel GainMapMax and the AlternateHeadroom, both in stops (log2).
    nonisolated private func isoGainMapMetadata(channels: Int, gainMapMaxStops: Float) -> CGImageMetadata? {
        let gmax = String(format: "%.6f", gainMapMaxStops)
        let li = [
            "               <rdf:li rdf:parseType=\"Resource\">",
            "                  <HDRToneMap:GainMapMin>0.000000</HDRToneMap:GainMapMin>",
            "                  <HDRToneMap:GainMapMax>\(gmax)</HDRToneMap:GainMapMax>",
            "                  <HDRToneMap:Gamma>1.000000</HDRToneMap:Gamma>",
            "                  <HDRToneMap:BaseOffset>0.000010</HDRToneMap:BaseOffset>",
            "                  <HDRToneMap:AlternateOffset>0.000010</HDRToneMap:AlternateOffset>",
            "               </rdf:li>",
        ].joined(separator: "\n")
        let seq = Array(repeating: li, count: max(1, channels)).joined(separator: "\n")
        let xmp = [
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"XMP Core 6.0.0\">",
            "   <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">",
            "      <rdf:Description rdf:about=\"\" xmlns:HDRToneMap=\"http://ns.apple.com/HDRToneMap/1.0/\">",
            "         <HDRToneMap:Version>1</HDRToneMap:Version>",
            "         <HDRToneMap:BaseHeadroom>0.000000</HDRToneMap:BaseHeadroom>",
            "         <HDRToneMap:AlternateHeadroom>\(gmax)</HDRToneMap:AlternateHeadroom>",
            "         <HDRToneMap:ChannelMetadata><rdf:Seq>",
            seq,
            "         </rdf:Seq></HDRToneMap:ChannelMetadata>",
            "         <HDRToneMap:BaseColorIsWorkingColor>True</HDRToneMap:BaseColorIsWorkingColor>",
            "      </rdf:Description>",
            "   </rdf:RDF>",
            "</x:xmpmeta>",
        ].joined(separator: "\n")
        guard let data = xmp.data(using: .utf8) else { return nil }
        return CGImageMetadataCreateFromXMPData(data as CFData)
    }

    private func downsampleGainMapAux(_ aux: [String: Any], factor: Int) -> [String: Any]? {
        guard factor > 1,
              let data = aux[kCGImageAuxiliaryDataInfoData as String] as? Data,
              let desc = aux[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any],
              let w = desc["Width"] as? Int, let h = desc["Height"] as? Int,
              let bpr = desc["BytesPerRow"] as? Int else { return nil }

        // 'L008' = 8-bit luminance, one channel — the format Core Image writes for a luma gain map.
        let kL008 = 1_278_226_488
        guard (desc["PixelFormat"] as? Int) == kL008 else { return nil }

        let gray = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: data as CFData),
              let gmImg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: bpr, space: gray,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }

        let nw = max(1, w / factor), nh = max(1, h / factor)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(gmImg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let raw = ctx.data else { return nil }
        let nbpr = ctx.bytesPerRow
        let newData = Data(bytes: raw, count: nbpr * nh)

        var newDesc = desc
        newDesc["Width"] = nw
        newDesc["Height"] = nh
        newDesc["BytesPerRow"] = nbpr

        var out = aux
        out[kCGImageAuxiliaryDataInfoData as String] = newData
        out[kCGImageAuxiliaryDataInfoDataDescription as String] = newDesc
        return out
    }

    // MARK: - Metadata Extraction

    /// Extracts EXIF/IPTC/TIFF metadata from cache (zero disk I/O)
    private func extractMetadata(from url: URL) -> [String: Any] {
        let key = url as NSURL
        
        // 1) Prova RawPixelData cache (ha i metadata)
        if let rawData = Self.rawDataCache.object(forKey: key) {
            return filterMetadataForPreservation(rawData.properties)
        }
        
        // 2) Fallback: leggi da disco (solo se non in cache - raro)
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return [:]
        }
        
        return filterMetadataForPreservation(properties)
    }
    
    /// Filters only metadata to preserve
    private func filterMetadataForPreservation(_ properties: [String: Any]) -> [String: Any] {
        var metadata: [String: Any] = [:]
        
        // Lista di chiavi da preservare (aggiorna dopo aver usato lo script)
        let keysToPreserve: [String] = [
            kCGImagePropertyDPIHeight as String,
            kCGImagePropertyDPIWidth as String,
            kCGImagePropertyExifAuxDictionary as String,
            kCGImagePropertyExifDictionary as String,
            kCGImagePropertyGPSDictionary as String,
            kCGImagePropertyIPTCDictionary as String,
            kCGImagePropertyTIFFDictionary as String
        ]
        
        for key in keysToPreserve {
            if let value = properties[key] {
                metadata[key] = value
            }
        }
        
        return metadata
    }
    
    // MARK: - Percentile Headroom (Real-time UI)
    
    /// Immutable lookup table for percentile-derived headroom.
    /// Stores a cumulative distribution function (CDF) over `bins` buckets normalized to the image peak luminance.
    nonisolated final class PercentileCDFBox: NSObject {
        let maxNits: Float
        let cdf: [Int]   // inclusive prefix sums; last element equals the total sample count
        let bins: Int
        
        init(maxNits: Float, cdf: [Int], bins: Int) {
            self.maxNits = maxNits
            self.cdf = cdf
            self.bins = bins
        }
        
        var totalCount: Int { cdf.last ?? 0 }
    }
    
    /// PQ EOTF lookup table (UInt16 code value → linear signal in [0..1], where 1 == 10,000 nits).
    /// Building this once avoids expensive `pow()` calls inside the pixel loop.
    nonisolated static let pqEotfLUT: [Float] = {
        let m1: Float = 2610.0 / 16384.0
        let m2: Float = 2523.0 / 32.0
        let c1: Float = 3424.0 / 4096.0
        let c2: Float = 2413.0 / 128.0
        let c3: Float = 2392.0 / 128.0
        
        func pqEOTF(_ v: Float) -> Float {
            let val = max(0, min(1, v))
            let vp = pow(val, 1.0 / m2)
            let num = max(vp - c1, 0)
            let den = c2 - c3 * vp
            return pow(num / den, 1.0 / m1)
        }
        
        var lut = [Float](repeating: 0, count: 65536)
        for i in 0..<65536 {
            let code = Float(i) / 65535.0
            lut[i] = pqEOTF(code)
        }
        return lut
    }()
    
    /// Returns a cached percentile-derived source headroom if available.
    /// This is intentionally synchronous and lightweight so the histogram UI can call it while the user drags the slider.
    func cachedPercentileHeadroom(url: URL, percentile: Float) -> Float? {
        let key = url as NSURL
        guard let box = Self.percentileCDFCache.object(forKey: key) else { return nil }
        return Self.headroomFromCDF(box, percentile: percentile)
    }
    
    /// Ensures the percentile lookup table for `url` exists (builds it once if needed).
    /// Returns true if the lookup is available afterwards.
    func prewarmPercentileCDF(url: URL) async -> Bool {
        let key = url as NSURL
        
        if Self.percentileCDFCache.object(forKey: key) != nil {
            return true
        }
        
        if let inflight = percentileCDFInFlight[key] {
            do {
                let box = try await inflight.value
                Self.percentileCDFCache.setObject(box, forKey: key)
                return true
            } catch {
                return false
            }
        }
        
        // Ensure raw bytes are available and headroom is measured. This may touch the disk or
        // run a Metal scan on a cold cache, so do it off the main actor.
        let rawData: RawPixelData
        let peakHeadroom: Float
        do {
            let prep = try await Task.detached(priority: .utility) { [self] () -> (RawPixelData, Float) in
                let data = try getRawPixelData(url: url)
                let head = getHeadroomForImage(url: url)
                return (data, head)
            }.value
            rawData = prep.0
            peakHeadroom = prep.1
        } catch {
            return false
        }
        let peakNits = max(0.001, peakHeadroom * Constants.referenceHDRwhiteNit)
        
        // The percentile CDF reader assumes 16-bit components (pixel stride = cpp × 2). Bail on
        // anything else (mirrors calculatePeakLuminanceNits) so we never read past an 8-bit buffer.
        guard rawData.bitsPerComponent == 16 else { return false }

        let bytes = rawData.bytes
        let width = rawData.width
        let height = rawData.height
        let cpp = rawData.componentsPerPixel
        let isBigEndian = rawData.isBigEndian
        let bins = 2048

        let task = Task.detached(priority: .utility) { () throws -> PercentileCDFBox in
            return Self.buildPercentileCDF(
                bytes: bytes,
                width: width,
                height: height,
                componentsPerPixel: cpp,
                isBigEndian: isBigEndian,
                peakNits: peakNits,
                bins: bins
            )
        }
        
        percentileCDFInFlight[key] = task
        
        do {
            let box = try await task.value
            Self.percentileCDFCache.setObject(box, forKey: key)
            percentileCDFInFlight[key] = nil
            return true
        } catch {
            percentileCDFInFlight[key] = nil
            return false
        }
    }
    
    /// Async helper used by preview/export to get an up-to-date percentile headroom while avoiding repeated pixel scans.
    private func percentileHeadroom(url: URL, percentile: Float) async throws -> Float {
        if let cached = cachedPercentileHeadroom(url: url, percentile: percentile) {
            return cached
        }
        let ok = await prewarmPercentileCDF(url: url)
        guard ok, let cached = cachedPercentileHeadroom(url: url, percentile: percentile) else {
            throw ProcessingError.headroomCalculationFailed
        }
        return cached
    }
    
    private nonisolated static func buildPercentileCDF(
        bytes: [UInt8],
        width: Int,
        height: Int,
        componentsPerPixel: Int,
        isBigEndian: Bool,
        peakNits: Float,
        bins: Int
    ) -> PercentileCDFBox {
        let bytesPerRow = width * componentsPerPixel * 2
        let pixelStride = componentsPerPixel * 2
        
        let kr: Float = 0.2126
        let kg: Float = 0.7152
        let kb: Float = 0.0722
        
        var histogram = [Int](repeating: 0, count: bins)
        let scale = Float(bins) / max(0.001, peakNits)
        
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let pixelStart = rowStart + x * pixelStride
                
                let r16: UInt16
                let g16: UInt16
                let b16: UInt16
                
                if isBigEndian {
                    r16 = (UInt16(bytes[pixelStart + 0]) << 8) | UInt16(bytes[pixelStart + 1])
                    g16 = (UInt16(bytes[pixelStart + 2]) << 8) | UInt16(bytes[pixelStart + 3])
                    b16 = (UInt16(bytes[pixelStart + 4]) << 8) | UInt16(bytes[pixelStart + 5])
                } else {
                    r16 = UInt16(bytes[pixelStart + 0]) | (UInt16(bytes[pixelStart + 1]) << 8)
                    g16 = UInt16(bytes[pixelStart + 2]) | (UInt16(bytes[pixelStart + 3]) << 8)
                    b16 = UInt16(bytes[pixelStart + 4]) | (UInt16(bytes[pixelStart + 5]) << 8)
                }
                
                let rLin = pqEotfLUT[Int(r16)]
                let gLin = pqEotfLUT[Int(g16)]
                let bLin = pqEotfLUT[Int(b16)]
                
                let yLin = kr * rLin + kg * gLin + kb * bLin
                let yNits = yLin * 10000.0
                
                var idx = Int(yNits * scale)
                if idx < 0 { idx = 0 }
                if idx >= bins { idx = bins - 1 }
                histogram[idx] += 1
            }
        }
        
        // Build CDF (prefix sums).
        var cdf = [Int](repeating: 0, count: bins)
        var running = 0
        for i in 0..<bins {
            running += histogram[i]
            cdf[i] = running
        }
        
        return PercentileCDFBox(maxNits: peakNits, cdf: cdf, bins: bins)
    }
    
    private nonisolated static func headroomFromCDF(_ box: PercentileCDFBox, percentile: Float) -> Float {
        let p = max(0, min(1, percentile))
        let total = max(1, box.totalCount)
        let target = max(1, Int(Float(total) * p))
        
        // Linear scan is fine for 2048 bins and keeps the implementation simple.
        var binIndex = box.bins - 1
        for i in 0..<box.bins {
            if box.cdf[i] >= target {
                binIndex = i
                break
            }
        }
        
        let u = Float(binIndex) / Float(box.bins)  // 0..1
        let percentileNits = u * box.maxNits
        let headroom = percentileNits / Constants.referenceHDRwhiteNit
        return max(1.0, headroom)
    }
    
    // MARK: - Auto source headroom

    /// Result of the automatic source-headroom search.
    nonisolated struct AutoHeadroomResult: Sendable {
        let sourceHeadroom: Float    // chosen value in [1.0, measuredHeadroom]
        let measuredHeadroom: Float
        let clipFraction: Double     // worst per-channel clip fraction at the chosen value
        let iterations: Int          // number of tonemap+count evaluations performed
        let metTolerance: Bool       // false if even the measured headroom exceeds the tolerance
    }

    /// Outcome of writing an auto-found source headroom into a settings object.
    nonisolated struct AutoApplyOutcome: Sendable {
        let requestedHeadroom: Float
        let realizedHeadroom: Float  // headroom the written parameter actually reproduces
        let note: String?            // set when the realized value had to deviate (clamps, no-headroom images)
    }

    /// Default tolerance for the Auto search, as percent of total pixels (per channel).
    nonisolated static let defaultAutoClipTolerancePercent: Double = 1.0

    /// Tolerance as a fraction (0...1), read from preferences with fallback to the default.
    nonisolated static func autoClipToleranceFraction() -> Double {
        let pct = UserDefaults.standard.double(forKey: "autoClipTolerancePercent")
        return (pct > 0 ? pct : defaultAutoClipTolerancePercent) / 100.0
    }

    /// Physical CPU cores (not logical/Hyper-Threaded), for sizing batch concurrency.
    nonisolated static func physicalCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Default worker count for the batch auto search: physical cores, bounded by a memory budget
    /// (each worker holds a full-res decode + RGBAf materialization in flight, ≈0.7 GB) and a sane
    /// absolute cap. Adapts to the host so non-6-core machines aren't over- or under-subscribed.
    nonisolated static func defaultAutoConcurrency() -> Int {
        let cores = physicalCoreCount()
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let ramCap = max(2, Int(ramGB * 0.5 / 0.7))   // ~50% of RAM at ~0.7 GB/worker
        return max(1, min(cores, ramCap, 16))
    }

    /// Worst per-channel clip fraction (0...1) of the SDR rendering: `max(frac_R, frac_G, frac_B)`,
    /// where `frac_c` is the fraction of pixels whose channel c exceeds 1+eps (counted independently
    /// of the other channels). Limiting this curbs single-channel clipping (e.g. a clipped R channel
    /// shifts the reconstructed tint toward yellow).
    nonisolated private func maxPerChannelClipFraction(sdr: CIImage, context: CIContext) -> Double {
        let eps: CGFloat = 1e-6
        let thr: CGFloat = 1.0 + eps

        let rMask = thresh01(extractChannel(sdr, r: 1, g: 0, b: 0), threshold: thr)
        let gMask = thresh01(extractChannel(sdr, r: 0, g: 1, b: 0), threshold: thr)
        let bMask = thresh01(extractChannel(sdr, r: 0, g: 0, b: 1), threshold: thr)

        func fraction(_ mask: CIImage) -> Double {
            let (clipped, total) = clippedCountViaAreaAverage(binaryMaskR: mask, context: context)
            guard total > 0 else { return 0 }
            return Double(clipped) / Double(total)
        }

        return max(fraction(rMask), max(fraction(gMask), fraction(bMask)))
    }

    /// Finds the smallest source headroom in [1.0, measured] whose tone-mapped SDR keeps the worst
    /// per-channel clip fraction (`max(frac_R, frac_G, frac_B)`) within `tolerance`. Each `frac_c`
    /// is monotonically non-increasing in the source headroom, so their max is too and a binary
    /// search applies. Full-resolution evaluation: each iteration is one tonemap + three
    /// CIAreaAverage readbacks.
    @concurrent nonisolated func findAutoSourceHeadroom(
        url: URL,
        targetHeadroom: Float,
        tolerance: Double
    ) async throws -> AutoHeadroomResult {
        let hdr = try loadHDR(url: url)
        let measured = max(1.0, getHeadroomForImage(url: url))

        func clipFraction(at sourceHeadroom: Float) throws -> Double {
            guard let sdr = tonemap_sdr(from: hdr, sourceHeadroom: sourceHeadroom, targetHeadroom: targetHeadroom) else {
                throw ProcessingError.tonemapFailed
            }
            return maxPerChannelClipFraction(sdr: sdr, context: searchCtx)
        }

        // No HDR content: nothing to search.
        if measured <= 1.0 + 1e-4 {
            return AutoHeadroomResult(sourceHeadroom: 1.0, measuredHeadroom: measured,
                                      clipFraction: try clipFraction(at: 1.0),
                                      iterations: 1, metTolerance: true)
        }

        let fLow = try clipFraction(at: 1.0)
        if fLow <= tolerance {
            return AutoHeadroomResult(sourceHeadroom: 1.0, measuredHeadroom: measured,
                                      clipFraction: fLow, iterations: 1, metTolerance: true)
        }

        let fHigh = try clipFraction(at: measured)
        if fHigh > tolerance {
            // The measured headroom is a *luma* peak: on heavily saturated content a single channel
            // can exceed it, so per-channel clipping may persist even here. Stay conservative.
            return AutoHeadroomResult(sourceHeadroom: measured, measuredHeadroom: measured,
                                      clipFraction: fHigh, iterations: 2, metTolerance: false)
        }

        // Invariant: f(hi) ≤ tolerance < f(lo).
        var lo: Float = 1.0
        var hi: Float = measured
        var fHi = fHigh
        var iterations = 2
        while hi - lo > max(0.01, 0.005 * hi), iterations < 14 {
            try Task.checkCancellation()
            let mid = (lo + hi) / 2
            let f = try clipFraction(at: mid)
            iterations += 1
            if f <= tolerance {
                hi = mid
                fHi = f
            } else {
                lo = mid
            }
        }
        return AutoHeadroomResult(sourceHeadroom: hi, measuredHeadroom: measured,
                                  clipFraction: fHi, iterations: iterations, metTolerance: true)
    }

    /// Runs the auto search over many images with bounded concurrency, each worker using its own
    /// `SearchResources` (CIContext + histogram) so the work parallelizes instead of serializing on
    /// the shared singletons. `onEach` is invoked on the main actor as each image finishes (for the
    /// GUI to apply the result + advance progress); it receives the original index, the URL and the
    /// search result (or the error/cancellation). Honors cancellation of the calling task.
    @concurrent nonisolated func autoSearchBatch(
        jobs: [(url: URL, targetHeadroom: Float)],
        tolerance: Double,
        concurrency: Int,
        onEach: @escaping @Sendable @MainActor (_ index: Int, _ url: URL, _ result: Result<AutoHeadroomResult, Error>) async -> Void
    ) async {
        guard !jobs.isEmpty else { return }
        let k = max(1, min(concurrency, jobs.count))
        let pool = (0..<k).map { _ in SearchResources(workingColorSpace: linear_p3) }

        await withTaskGroup(of: Int.self) { group in
            var next = 0
            // Submits the job at `next` on the given worker slot; returns the slot when it finishes.
            func submit(slot: Int) {
                guard next < jobs.count, !Task.isCancelled else { return }
                let index = next; next += 1
                let job = jobs[index]
                group.addTask {
                    let outcome: Result<AutoHeadroomResult, Error>
                    do {
                        let r = try await SearchResourcesContext.$current.withValue(pool[slot]) {
                            try await self.findAutoSourceHeadroom(
                                url: job.url, targetHeadroom: job.targetHeadroom, tolerance: tolerance)
                        }
                        outcome = .success(r)
                    } catch {
                        outcome = .failure(error)
                    }
                    await onEach(index, job.url, outcome)
                    return slot
                }
            }
            for slot in 0..<k { submit(slot: slot) }
            while let freedSlot = await group.next() {
                submit(slot: freedSlot)
            }
        }
    }

    /// Writes `sourceHeadroom` into the parameter of the currently active source-headroom method.
    /// Runs on the main actor because `settings` is live @Observable state.
    func applyAutoSourceHeadroom(_ sourceHeadroom: Float, to settings: ProcessingSettings, url: URL) async -> AutoApplyOutcome {
        let measured = max(1.0, getHeadroomForImage(url: url))

        switch settings.sourceHeadroomMethod {
        case .peakMax:
            // Invert sH = 1 + M − M^ratio (see buildSDRBase). For sH ∈ [1, M] the log argument is ≥ 1.
            if measured <= 1.0 + 1e-4 {
                settings.tonemapRatio = 1.0
                return AutoApplyOutcome(requestedHeadroom: sourceHeadroom, realizedHeadroom: 1.0,
                                        note: "Image has no headroom; tone mapping is a no-op")
            }
            let arg = max(1.0, 1.0 + measured - sourceHeadroom)
            let ratio = min(max(log(arg) / log(measured), 0.0), 1.0)
            settings.tonemapRatio = ratio
            let realized = max(1.0, 1.0 + measured - powf(measured, ratio))
            return AutoApplyOutcome(requestedHeadroom: sourceHeadroom, realizedHeadroom: realized, note: nil)

        case .direct:
            let clamped = min(max(sourceHeadroom, 0.1), max(1.0, measured * 2.0))
            settings.directSourceHeadroom = clamped
            return AutoApplyOutcome(requestedHeadroom: sourceHeadroom, realizedHeadroom: clamped, note: nil)

        case .percentile:
            _ = await prewarmPercentileCDF(url: url)
            guard let box = Self.percentileCDFCache.object(forKey: url as NSURL) else {
                return AutoApplyOutcome(requestedHeadroom: sourceHeadroom, realizedHeadroom: sourceHeadroom,
                                        note: "Percentile lookup unavailable; parameters unchanged")
            }
            let (percentile, realized) = Self.percentileForHeadroom(box, sourceHeadroom: sourceHeadroom)
            settings.percentile = percentile
            // One CDF bin of slack is inherent quantization; flag only larger deviations (clamps).
            let binHeadroom = box.maxNits / Float(box.bins) / Constants.referenceHDRwhiteNit
            let note: String? = abs(realized - sourceHeadroom) > 2.0 * binHeadroom
                ? String(format: "Nearest reachable percentile selected (headroom %.2f instead of %.2f)", realized, sourceHeadroom)
                : nil
            return AutoApplyOutcome(requestedHeadroom: sourceHeadroom, realizedHeadroom: realized, note: note)
        }
    }

    /// Inverse of `headroomFromCDF`: the percentile whose realized headroom best matches
    /// `sourceHeadroom`, erring toward less clipping (ceil to the next reachable bin) and
    /// clamped to the UI slider range [0.95, 0.99999].
    private nonisolated static func percentileForHeadroom(_ box: PercentileCDFBox, sourceHeadroom: Float) -> (percentile: Float, realizedHeadroom: Float) {
        let targetNits = sourceHeadroom * Constants.referenceHDRwhiteNit
        var bin = Int((targetNits / max(0.001, box.maxNits) * Float(box.bins)).rounded(.up))
        bin = min(max(bin, 0), box.bins - 1)

        // Advance to the first bin a percentile can actually select: headroomFromCDF picks the
        // first bin whose cdf reaches the target count, so empty bins are unreachable.
        while bin < box.bins - 1, box.cdf[bin] == (bin > 0 ? box.cdf[bin - 1] : 0) {
            bin += 1
        }

        let total = max(1, box.totalCount)
        var percentile = Float(box.cdf[bin]) / Float(total)
        percentile = min(max(percentile, 0.95), 0.99999)
        let realized = headroomFromCDF(box, percentile: percentile)
        return (percentile, realized)
    }

    // MARK: - Headroom

    /// Computes raw headroom (no cache; prefer getHeadroomForImage() instead).
    /// Use Metal for a 10–100× speedup (when available).
    nonisolated func computeMeasuredHeadroomRaw(url: URL) throws -> Float {
        
        // print("🔍 [computeMeasuredHeadroomRaw] Called for: \(url.lastPathComponent)")
        
        // Fetch raw pixel data from cache
        let rawData = try getRawPixelData(url: url)
        
        // print("    RawData obtained: \(rawData.width)×\(rawData.height), \(rawData.bytes.count) bytes")
        
        // Try Metal first (per-worker calculator inside a batch, shared otherwise).
        let peakNits: Float

        if let metalCalc = searchHistogram,
           let metalPeak = metalCalc.calculatePeakLuminance(
            fromBytes: rawData.bytes,
            width: rawData.width,
            height: rawData.height,
            bitsPerComponent: rawData.bitsPerComponent,
            componentsPerPixel: rawData.componentsPerPixel,
            isBigEndian: rawData.isBigEndian
           ) {
            peakNits = metalPeak
        } else {
            // Fallback CPU
            // print("   ℹ️ Metal not available for headroom, using CPU...")
            peakNits = calculatePeakLuminanceNits(
                fromBytes: rawData.bytes,
                width: rawData.width,
                height: rawData.height,
                bitsPerComponent: rawData.bitsPerComponent,
                componentsPerPixel: rawData.componentsPerPixel,
                isBigEndian: rawData.isBigEndian
            )
        }
        
        // Headroom relativo a Constants.referenceHDRwhiteNit
        let headroom = peakNits / Constants.referenceHDRwhiteNit
        
        return headroom.isFinite ? headroom : 1.0
    }
    
    /// Helper: compute headroom from a URL with caching.
    nonisolated func getHeadroomForImage(url: URL) -> Float {
        let key = url as NSURL

        // Cache hit?
        if let cached = Self.peakLuminanceCache.object(forKey: key) {
//            print("📦 [Headroom] Cache HIT: \(url.lastPathComponent) = \(cached.floatValue)")
            return cached.floatValue
        }

        // print("⚠️  [Headroom] Cache MISS: \(url.lastPathComponent)")

        // print("   ❌ Peak luminance cache MISS, calculating...")

        do {
            let headroom = try computeMeasuredHeadroomRaw(url: url)

            if headroom <= 1.0 {
                // print("❌ [Headroom] WARNING: Computed headroom = \(headroom) ≤ 1.0!")
            } else {
                // print("✅ [Headroom] Computed headroom = \(headroom)")
            }

            Self.peakLuminanceCache.setObject(NSNumber(value: headroom), forKey: key)
            // print("    Cached headroom for: \(url.lastPathComponent)")

            return headroom
        } catch {
            // print("❌ [Headroom] Computation FAILED: \(error)")
            return 1.0
        }
    }
    
    /// Computes absolute peak luminance (nits) from raw pixel data.
    nonisolated private func calculatePeakLuminanceNits(
        fromBytes bytes: [UInt8],
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        componentsPerPixel: Int,
        isBigEndian: Bool
    ) -> Float {
        
        guard bitsPerComponent == 16 else {
            // print("⚠️ Only 16-bit supported for headroom calculation")
            return Constants.referenceHDRwhiteNit  // Fallback a Constants.referenceHDRwhiteNit
        }
        
        let bytesPerRow = width * componentsPerPixel * 2  // 16-bit = 2 bytes
        let pixelStride = componentsPerPixel * 2
        
        var maxLuminanceNits: Float = 0.0
        
        // Costanti PQ (SMPTE ST 2084)
        let m1: Float = 2610.0 / 16384.0
        let m2: Float = 2523.0 / 32.0
        let c1: Float = 3424.0 / 4096.0
        let c2: Float = 2413.0 / 128.0
        let c3: Float = 2392.0 / 128.0
        
        // Rec.709 luma coefficients.
        let kr: Float = 0.2126
        let kg: Float = 0.7152
        let kb: Float = 0.0722
        
        // Scan all pixels.
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            
            for x in 0..<width {
                let pixelStart = rowStart + x * pixelStride
                
                // Leggi RGB 16-bit PQ code values [0..65535]
                let r16: UInt16
                let g16: UInt16
                let b16: UInt16
                
                if isBigEndian {
                    r16 = (UInt16(bytes[pixelStart + 0]) << 8) | UInt16(bytes[pixelStart + 1])
                    g16 = (UInt16(bytes[pixelStart + 2]) << 8) | UInt16(bytes[pixelStart + 3])
                    b16 = (UInt16(bytes[pixelStart + 4]) << 8) | UInt16(bytes[pixelStart + 5])
                } else {
                    r16 = UInt16(bytes[pixelStart + 0]) | (UInt16(bytes[pixelStart + 1]) << 8)
                    g16 = UInt16(bytes[pixelStart + 2]) | (UInt16(bytes[pixelStart + 3]) << 8)
                    b16 = UInt16(bytes[pixelStart + 4]) | (UInt16(bytes[pixelStart + 5]) << 8)
                }
                
                // Normalizza a [0..1]
                let rCode = Float(r16) / 65535.0
                let gCode = Float(g16) / 65535.0
                let bCode = Float(b16) / 65535.0
                
                // PQ EOTF → linear [0..1] where 1 = 10k nit
                func pqEOTF(_ v: Float) -> Float {
                    let val = max(0, min(1, v))
                    let vp = pow(val, 1.0 / m2)
                    let num = max(vp - c1, 0)
                    let den = c2 - c3 * vp
                    return pow(num / den, 1.0 / m1)
                }
                
                let rLin = pqEOTF(rCode)
                let gLin = pqEOTF(gCode)
                let bLin = pqEOTF(bCode)
                
                // Luma lineare (Rec.709)
                let yLin = kr * rLin + kg * gLin + kb * bLin
                
                // Convert to absolute nits (linear values are normalized to 10,000 nits).
                let yNits = yLin * 10000.0
                
                // Track max
                maxLuminanceNits = max(maxLuminanceNits, yNits)
            }
        }
        
        return maxLuminanceNits.isFinite ? maxLuminanceNits : Constants.referenceHDRwhiteNit
    }
    
    // MARK: - Overlay + count
    
    // Reference-type box so DetailedClippingStats (a struct) can be stored in NSCache.
    nonisolated final class DetailedStatsBox {
        let stats: DetailedClippingStats
        init(_ stats: DetailedClippingStats) { self.stats = stats }
    }

    // Struct to hold detailed clipping statistics
    nonisolated struct DetailedClippingStats: Sendable {
        let total: Int
        
        // Single channel clipping (bright: Y < 1)
        let redOnly: Int
        let greenOnly: Int
        let blueOnly: Int
        
        // Two-channel clipping (bright: Y < 1)
        let yellowBright: Int    // R+G
        let magentaBright: Int   // R+B
        let cyanBright: Int      // G+B
        
        // Single channel clipping (dim: Y ≥ 1)
        let redDim: Int
        let greenDim: Int
        let blueDim: Int
        
        // Two-channel clipping (dim: Y ≥ 1)
        let yellowDim: Int
        let magentaDim: Int
        let cyanDim: Int
        
        // All three channels clipped (black/white in overlay)
        let white: Int           // R+G+B
        
        var totalClipped: Int {
            redOnly + greenOnly + blueOnly +
            yellowBright + magentaBright + cyanBright +
            redDim + greenDim + blueDim +
            yellowDim + magentaDim + cyanDim +
            white
        }
    }
    
    // --- Mask helpers (shared by overlay pipeline and Auto headroom search) ---

    nonisolated private func extractChannel(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        // Always route the selected channel into the output R channel (mono stored in R).
        let m = CIFilter.colorMatrix()
        m.inputImage = img
        if r == 1 {
            m.rVector = CIVector(x: 1, y: 0, z: 0, w: 0) // map R → R
        } else if g == 1 {
            m.rVector = CIVector(x: 0, y: 1, z: 0, w: 0) // map G → R
        } else {
            m.rVector = CIVector(x: 0, y: 0, z: 1, w: 0) // map B → R
        }
        m.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage!
    }

    nonisolated private func thresh01(_ monoR: CIImage, threshold: CGFloat = 1.0) -> CIImage {
        // (R - thr)^+ → [0,1] binaria in R
        let sub = CIFilter.colorMatrix()
        sub.inputImage = monoR
        sub.rVector   = CIVector(x: 1, y: 0, z: 0, w: 0)
        sub.gVector   = CIVector(x: 0, y: 0, z: 0, w: 0)
        sub.bVector   = CIVector(x: 0, y: 0, z: 0, w: 0)
        sub.aVector   = CIVector(x: 0, y: 0, z: 0, w: 1)
        sub.biasVector = CIVector(x: -threshold, y: 0, z: 0, w: 0)
        var y = sub.outputImage!

        let clampPos = CIFilter.colorClamp()
        clampPos.inputImage   = y
        clampPos.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampPos.maxComponents = CIVector(x: 1e6, y: 0, z: 0, w: 1)
        y = clampPos.outputImage!

        let gain: CGFloat = 1_000_000
        let amp = CIFilter.colorMatrix()
        amp.inputImage = y
        amp.rVector   = CIVector(x: gain, y: 0, z: 0, w: 0)
        amp.gVector   = CIVector(x: 0,    y: 0, z: 0, w: 0)
        amp.bVector   = CIVector(x: 0,    y: 0, z: 0, w: 0)
        amp.aVector   = CIVector(x: 0,    y: 0, z: 0, w: 1)
        y = amp.outputImage!

        let clamp01 = CIFilter.colorClamp()
        clamp01.inputImage   = y
        clamp01.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp01.maxComponents = CIVector(x: 1, y: 0, z: 0, w: 1)
        return clamp01.outputImage!
    }

    nonisolated private func andMask(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.multiplyCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return f.outputImage!
    }

    /// The 13 mutually-exclusive clipped-pixel category masks (each a binary 0/1 image in its R
    /// channel) plus the pixel total. Shared by the stats counting and the overlay compositing so the
    /// two stay in lock-step. Categories for clipped SDR pixels (maxRGB > 1):
    /// - red/green/blue: only R / G / B clipped; yellow/magenta/cyan: 2 channels clipped.
    /// - "*_dim" variants: the above when **Y ≥ 1** (luma clipped too); `all3`: R&G&B all clipped.
    nonisolated private struct ClippingMasks {
        let total: Int
        let onlyR_bright: CIImage, onlyG_bright: CIImage, onlyB_bright: CIImage
        let rg_bright: CIImage, rb_bright: CIImage, gb_bright: CIImage
        let onlyR_dim: CIImage, onlyG_dim: CIImage, onlyB_dim: CIImage
        let rg_dim: CIImage, rb_dim: CIImage, gb_dim: CIImage
        let all3: CIImage
    }

    /// Builds the per-category clipping masks (lazy CIImage graphs — cheap; the cost is in rendering
    /// them, which only the counting path does). `extractChannel`/`thresh01`/`andMask`/`linear_luma`
    /// are instance methods shared with the Auto search.
    nonisolated private func clippingCategoryMasks(sdr: CIImage) -> ClippingMasks? {
        let w = Int(sdr.extent.width)
        let h = Int(sdr.extent.height)
        guard w > 0, h > 0 else { return nil }

        func invert01(_ monoR: CIImage) -> CIImage {
            let inv = CIFilter.colorMatrix()
            inv.inputImage = monoR
            inv.rVector    = CIVector(x: -1, y: 0, z: 0, w: 0)
            inv.gVector    = CIVector(x: 0,  y: 0, z: 0, w: 0)
            inv.bVector    = CIVector(x: 0,  y: 0, z: 0, w: 0)
            inv.aVector    = CIVector(x: 0,  y: 0, z: 0, w: 1)
            inv.biasVector = CIVector(x: 1,  y: 0, z: 0, w: 0)
            return inv.outputImage!
        }
        func andNot(_ a: CIImage, _ b: CIImage) -> CIImage { andMask(a, invert01(b)) } // a ∧ ¬b

        // Per-channel masks (threshold 1.0 + optional epsilon).
        let eps: CGFloat = 1e-6
        let thr: CGFloat = 1.0 + eps
        let rMask = thresh01(extractChannel(sdr, r: 1, g: 0, b: 0), threshold: thr)
        let gMask = thresh01(extractChannel(sdr, r: 0, g: 1, b: 0), threshold: thr)
        let bMask = thresh01(extractChannel(sdr, r: 0, g: 0, b: 1), threshold: thr)

        // Luma (Y) mask, to split "bright" (Y < 1) from "dim" (Y ≥ 1).
        let yMask = thresh01(linear_luma(sdr), threshold: thr)

        let notR = invert01(rMask), notG = invert01(gMask), notB = invert01(bMask)
        let all3  = andMask(andMask(rMask, gMask), bMask)
        let onlyR = andMask(andMask(rMask, notG), notB)
        let onlyG = andMask(andMask(gMask, notR), notB)
        let onlyB = andMask(andMask(bMask, notR), notG)
        let rgOnly = andMask(andMask(rMask, gMask), notB)
        let rbOnly = andMask(andMask(rMask, bMask), notG)
        let gbOnly = andMask(andMask(gMask, bMask), notR)

        return ClippingMasks(
            total: w * h,
            onlyR_bright: andNot(onlyR, yMask), onlyG_bright: andNot(onlyG, yMask), onlyB_bright: andNot(onlyB, yMask),
            rg_bright: andNot(rgOnly, yMask), rb_bright: andNot(rbOnly, yMask), gb_bright: andNot(gbOnly, yMask),
            onlyR_dim: andMask(onlyR, yMask), onlyG_dim: andMask(onlyG, yMask), onlyB_dim: andMask(onlyB, yMask),
            rg_dim: andMask(rgOnly, yMask), rb_dim: andMask(rbOnly, yMask), gb_dim: andMask(gbOnly, yMask),
            all3: all3
        )
    }

    /// Counts clipped pixels per category (the expensive `CIAreaAverage` renders). Opacity-independent.
    nonisolated func computeClippingStats(
        sdr: CIImage,
        context: CIContext
    ) -> (clipped: Int, total: Int, detailedStats: DetailedClippingStats)? {
        guard let m = clippingCategoryMasks(sdr: sdr) else { return nil }

        func countPixels(_ mask: CIImage) -> Int {
            let (c, _) = clippedCountViaAreaAverage(binaryMaskR: mask, context: context)
            return c
        }

        let detailedStats = DetailedClippingStats(
            total: m.total,
            redOnly: countPixels(m.onlyR_bright),
            greenOnly: countPixels(m.onlyG_bright),
            blueOnly: countPixels(m.onlyB_bright),
            yellowBright: countPixels(m.rg_bright),
            magentaBright: countPixels(m.rb_bright),
            cyanBright: countPixels(m.gb_bright),
            redDim: countPixels(m.onlyR_dim),
            greenDim: countPixels(m.onlyG_dim),
            blueDim: countPixels(m.onlyB_dim),
            yellowDim: countPixels(m.rg_dim),
            magentaDim: countPixels(m.rb_dim),
            cyanDim: countPixels(m.gb_dim),
            white: countPixels(m.all3)
        )
        return (detailedStats.totalClipped, m.total, detailedStats)
    }

    /// Composites the colorized clipping overlay onto `sdr` at the given `opacity` (0…1). The overlay
    /// colors are pure additive RGB so they match the legend and RGB diagram. `opacity` scales every
    /// layer's alpha uniformly (1 = the legacy fully-opaque overlay; the caller skips this at 0).
    nonisolated func buildClippingOverlayImage(sdr: CIImage, opacity: CGFloat) -> CIImage {
        guard let m = clippingCategoryMasks(sdr: sdr) else { return sdr }

        // alpha := R * opacity → fades the whole overlay; masks are binary so this is a clean scale.
        func toAlpha(_ monoR: CIImage) -> CIImage {
            let cm = CIFilter.colorMatrix()
            cm.inputImage = monoR
            cm.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            cm.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            cm.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            cm.aVector = CIVector(x: opacity, y: 0, z: 0, w: 0)
            return cm.outputImage!
        }
        func layer(color: CIColor, mask: CIImage, over bg: CIImage) -> CIImage {
            let tint = CIImage(color: color).cropped(to: sdr.extent)
            let alpha = toAlpha(mask)
            return CIFilter(name: "CIBlendWithAlphaMask",
                            parameters: [kCIInputImageKey: tint,
                               kCIInputBackgroundImageKey: bg,
                                     kCIInputMaskImageKey: alpha])!.outputImage!
        }

        // Compositing order: bright → dim → black (all3) on top.
        var composited = sdr
        // bright (full intensity)
        composited = layer(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1), mask: m.onlyR_bright, over: composited)
        composited = layer(color: CIColor(red: 0, green: 1, blue: 0, alpha: 1), mask: m.onlyG_bright, over: composited)
        composited = layer(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1), mask: m.onlyB_bright, over: composited)
        composited = layer(color: CIColor(red: 1, green: 1, blue: 0, alpha: 1), mask: m.rg_bright,    over: composited)
        composited = layer(color: CIColor(red: 1, green: 0, blue: 1, alpha: 1), mask: m.rb_bright,    over: composited)
        composited = layer(color: CIColor(red: 0, green: 1, blue: 1, alpha: 1), mask: m.gb_bright,    over: composited)
        // dim (half intensity)
        composited = layer(color: CIColor(red: 0.5, green: 0,   blue: 0,   alpha: 1), mask: m.onlyR_dim, over: composited)
        composited = layer(color: CIColor(red: 0,   green: 0.5, blue: 0,   alpha: 1), mask: m.onlyG_dim, over: composited)
        composited = layer(color: CIColor(red: 0,   green: 0,   blue: 0.5, alpha: 1), mask: m.onlyB_dim, over: composited)
        composited = layer(color: CIColor(red: 0.5, green: 0.5, blue: 0,   alpha: 1), mask: m.rg_dim,    over: composited)
        composited = layer(color: CIColor(red: 0.5, green: 0,   blue: 0.5, alpha: 1), mask: m.rb_dim,    over: composited)
        composited = layer(color: CIColor(red: 0,   green: 0.5, blue: 0.5, alpha: 1), mask: m.gb_dim,    over: composited)
        // Black for RGB (last, on top of everything)
        composited = layer(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1), mask: m.all3, over: composited)
        return composited
    }
    
    
    nonisolated private func clippedCountViaAreaAverage(binaryMaskR: CIImage, context: CIContext) -> (Int, Int) {
        let w = Int(binaryMaskR.extent.width), h = Int(binaryMaskR.extent.height)
        guard w > 0, h > 0 else { return (0, 0) }
        
        let f = CIFilter(name: "CIAreaAverage",
                         parameters: [kCIInputImageKey: binaryMaskR,
                                     kCIInputExtentKey: CIVector(cgRect: binaryMaskR.extent)])!
        let out = f.outputImage!
        
        var px = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &px,
                       rowBytes: MemoryLayout<Float>.size * 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        
        let fraction = max(0, min(1, px[0]))
        let total = w * h
        let clipped = Int((fraction * Float(total)).rounded(.toNearestOrAwayFromZero))
        return (clipped, total)
    }
    
    /// Materializes a CIImage into an NSImage. For `hdr == true` the CGImage is created in
    /// extended-linear Display P3 with a half-float format so it carries true HDR pixels; the
    /// SwiftUI `Image` then shows them on EDR-capable displays via `.allowedDynamicRange(.high)`.
    nonisolated private func ciImageToNSImage(_ ciImage: CIImage, hdr: Bool = false) throws -> NSImage {
        let cg: CGImage?
        if hdr {
            cg = encode_ctx.createCGImage(ciImage,
                                          from: ciImage.extent,
                                          format: .RGBAh,
                                          colorSpace: linear_p3)
        } else {
            cg = encode_ctx.createCGImage(ciImage, from: ciImage.extent)
        }
        guard let cgImage = cg else {
            throw ProcessingError.imageConversionFailed
        }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: ciImage.extent.width, height: ciImage.extent.height))
        return nsImage
    }

    /// Reconstructs the HDR image the export would produce (SDR base + gain map) entirely in
    /// memory: encode to an in-memory HEIF (skipping the on-disk write + ISO conversion), then
    /// decode back with `.expandToHDR`. Used by the `.finalOutput` preview to validate fidelity.
    nonisolated private func reconstructHDRFromGainMap(sdrBase: CIImage, hdr: CIImage) throws -> CIImage {
        let data: Data
        let storedFactor = UserDefaults.standard.integer(forKey: "gainMapSubsampleFactor")
        let subsampleFactor = storedFactor > 0 ? storedFactor : 1
        if UserDefaults.standard.bool(forKey: "gainMapRGB") {
            // RGB: round-trip through the exact same HEIC bytes the RGB exporter writes, so the
            // preview matches the file. Subsample to match the export; quality 1.0 for a fidelity view.
            guard let d = encodeRGBGainMapHEICData(hdr: hdr, sdrBase: sdrBase, baseProps: [:],
                                                   subsampleFactor: subsampleFactor, quality: 1.0) else {
                throw ProcessingError.gainMapGenerationFailed
            }
            data = d
        } else if UserDefaults.standard.bool(forKey: "gainMapMonoCoreImage") {
            // Legacy Core Image mono (PQ) — opt-in only.
            let options: [CIImageRepresentationOption: Any] = [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0,
                CIImageRepresentationOption.hdrImage: hdr,
                CIImageRepresentationOption.hdrGainMapAsRGB: false
            ]
            guard let d = encode_ctx.heifRepresentation(of: sdrBase,
                                                        format: .RGB10,
                                                        colorSpace: p3_cs,
                                                        options: options) else {
                throw ProcessingError.gainMapGenerationFailed
            }
            data = d
        } else {
            // Default: hand-assembled luma gain map (Display P3) — same bytes the exporter writes.
            guard let d = encodeMonoManualGainMapHEICData(hdr: hdr, sdrBase: sdrBase, baseProps: [:],
                                                          subsampleFactor: subsampleFactor, quality: 1.0) else {
                throw ProcessingError.gainMapGenerationFailed
            }
            data = d
        }
        guard let reconstructed = CIImage(data: data, options: [.expandToHDR: true]) else {
            throw ProcessingError.gainMapExtractionFailed
        }
        return reconstructed
    }

    /// Extracts the gain map as a standalone CIImage for the `.gainMap` preview. RGB on → visualizes
    /// the 3-channel gain map we compute; mono (default) → visualizes the hand-assembled luma gain map
    /// as grayscale; the legacy Core Image mono path (opt-in) pulls Core Image's luma auxiliary.
    /// The gain map is computed at the export resolution (`gainMapSubsampleFactor`) and then scaled
    /// back up to the SDR base extent — mirroring how the decoder upscales the stored map during
    /// reconstruction — so the preview reflects the 1× / ½× setting (½× looks softer) while keeping
    /// the same pixel geometry as the other previews (zoom / Compare line up).
    nonisolated private func extractGainMapImage(sdrBase: CIImage, hdr: CIImage) throws -> CIImage {
        let storedFactor = UserDefaults.standard.integer(forKey: "gainMapSubsampleFactor")
        let subsampleFactor = storedFactor > 0 ? storedFactor : 1
        // Scale a gain map (built at 1/subsampleFactor) back up to the SDR base extent.
        func upscaledToBase(_ image: CIImage, gmWidth: Int, gmHeight: Int) -> CIImage {
            let baseExtent = sdrBase.extent
            let sx = baseExtent.width / CGFloat(gmWidth)
            let sy = baseExtent.height / CGFloat(gmHeight)
            return image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        if UserDefaults.standard.bool(forKey: "gainMapRGB") {
            guard let gm = computeRGBGainMap(hdr: hdr, sdr: sdrBase, factor: subsampleFactor) else {
                throw ProcessingError.gainMapGenerationFailed
            }
            let img = CIImage(bitmapData: gm.data,
                              bytesPerRow: gm.width * 4,
                              size: CGSize(width: gm.width, height: gm.height),
                              format: .ARGB8,
                              colorSpace: p3_cs)
            return upscaledToBase(img, gmWidth: gm.width, gmHeight: gm.height)
        }
        if !UserDefaults.standard.bool(forKey: "gainMapMonoCoreImage") {
            // Default: visualize our hand-assembled luma gain map. Expand the L008 bytes into ARGB8
            // gray (R=G=B=gain, A=255) so we can build the CIImage with the same .ARGB8 path as RGB.
            guard let gm = computeMonoGainMap(hdr: hdr, sdr: sdrBase, factor: subsampleFactor) else {
                throw ProcessingError.gainMapGenerationFailed
            }
            var argb = [UInt8](repeating: 0, count: gm.width * gm.height * 4)
            gm.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let lum = raw.bindMemory(to: UInt8.self)
                for p in 0..<(gm.width * gm.height) {
                    let v = lum[p], i = p * 4
                    argb[i] = 255; argb[i + 1] = v; argb[i + 2] = v; argb[i + 3] = v
                }
            }
            let img = CIImage(bitmapData: Data(argb),
                              bytesPerRow: gm.width * 4,
                              size: CGSize(width: gm.width, height: gm.height),
                              format: .ARGB8,
                              colorSpace: p3_cs)
            return upscaledToBase(img, gmWidth: gm.width, gmHeight: gm.height)
        }
        // Legacy Core Image mono (PQ) — opt-in only.
        let options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0,
            CIImageRepresentationOption.hdrImage: hdr,
            CIImageRepresentationOption.hdrGainMapAsRGB: false
        ]
        guard let data = encode_ctx.heifRepresentation(of: sdrBase,
                                                       format: .RGB10,
                                                       colorSpace: p3_cs,
                                                       options: options) else {
            throw ProcessingError.gainMapGenerationFailed
        }
        guard let gainMap = CIImage(data: data, options: [.auxiliaryHDRGainMap: true]) else {
            throw ProcessingError.gainMapExtractionFailed
        }
        return gainMap
    }
    
    /// Computes the histogram for the SDR output (no caching; always recomputed).
    /// Important: use the BASE preview without the clipping overlay.
    /// `@concurrent` so the Metal compute + full-res readback runs off the main thread.
    @concurrent nonisolated func histogramForSDROutput(params: PreviewParams) async throws -> HistogramCalculator.HistogramResult {

        // Note: generatePreview() may return an image *with* a clipping overlay.
        // Approach: access the BASE preview cache directly.

        let file = params.url.lastPathComponent
        let baseKey = previewKey(params)

        // Fetch the base preview from cache; on a miss, render it (populates previewBaseCache).
        let cachedBase: CIImage
        if let hit = previewBaseCache.object(forKey: baseKey) {
            cachedBase = hit
        } else {
            // Render off-main to populate the base cache, then read it back.
            _ = try await renderPreviewCore(params: params, baseKey: baseKey)
            guard let rendered = previewBaseCache.object(forKey: baseKey) else {
                throw ProcessingError.imageConversionFailed
            }
            cachedBase = rendered
        }

        // CIImage → CGImage (materializes the tone-map at full res).
        let tCG = Prof.tic()
        guard let cgImage = encode_ctx.createCGImage(cachedBase, from: cachedBase.extent) else {
            throw ProcessingError.imageConversionFailed
        }
        Prof.toc("histSDR.createCGImage [\(file)]", tCG)
        let sdrImage = NSImage(cgImage: cgImage, size: NSSize(width: cachedBase.extent.width, height: cachedBase.extent.height))

        let tMetal = Prof.tic()
        defer { Prof.toc("histSDR.metalHist [\(file)]", tMetal) }
        return try await calculateHistogramFromSDRImage(sdrImage, ciImage: cachedBase)
    }

    /// Helper: compute histogram from an SDR NSImage.
    /// Use Metal when available; otherwise fall back to CPU.
    nonisolated private func calculateHistogramFromSDRImage(
        _ sdrImage: NSImage,
        ciImage: CIImage? = nil
    ) async throws -> HistogramCalculator.HistogramResult {
        
        // print("   → Converting NSImage to CIImage...")
        
        // Use the provided CIImage or build one from the NSImage.
        let workingCIImage: CIImage
        if let provided = ciImage {
            workingCIImage = provided
        } else {
            guard let cgImage = sdrImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                // print("   ❌ Failed to get CGImage from NSImage")
                throw ProcessingError.imageConversionFailed
            }
            workingCIImage = CIImage(cgImage: cgImage)
        }
        
        // print("   ✅ CIImage ready: \(workingCIImage.extent)")
        
        // Try Metal first.
        if let metalCalc = metalHistogram {
            // print("   🚀 Using METAL for histogram calculation...")
            if let result = metalCalc.calculateHistogramFromSDR(
                ciImage: workingCIImage,
                context: encode_ctx,
                smoothWindow: 11
            ) {
                return result
            } else {
                // print("   ⚠️ Metal calculation failed, falling back to CPU...")
            }
        } else {
            // print("   ℹ️ Metal not available, using CPU...")
        }
        
        // Fallback: CPU (legacy implementation).
        // print("   → Calculating histogram (CPU)...")
        guard let histogram = HistogramCalculator.calculateHistogramFromSDR(
            ciImage: workingCIImage,
            context: encode_ctx,
            smoothWindow: 11
        ) else {
            // print("   ❌ Histogram calculation returned nil")
            throw ProcessingError.histogramCalculationFailed
        }
        // print("   ✅ Histogram calculated: \(histogram.xCenters.count) bins")
        
        return histogram
    }

    // MARK: - Raw Data Structures
    
    /// Separate cache for raw pixel data (used for histograms).
    nonisolated(unsafe) private static let rawDataCache = NSCache<NSURL, RawPixelData>()
    
    // MARK: - Public Cache Access
    
    /// Expose the raw-data cache for HDRImage.
    /// Allows HDRImage.loadMetadata() to reuse already-loaded data.
    nonisolated func getCachedRawPixelData(url: URL) -> RawPixelData? {
        let key = url as NSURL
        return Self.rawDataCache.object(forKey: key)
    }

    /// Whether the image's pixel data is currently resident in memory (raw bytes or linear CIImage).
    /// Used by the UI to flag thumbnails that will load quickly (no disk read).
    nonisolated func isLoaded(url: URL) -> Bool {
        let key = url as NSURL
        return Self.rawDataCache.object(forKey: key) != nil || hdrCache.object(forKey: key) != nil
    }
    
    // MARK: - HDR Loading with Raw Data Cache
    
    /// Load HDR once: read raw bytes from disk only once, then cache both the bytes and the CIImage.
    /// Throws ProcessingError.invalidColorSpace if the file isn't the expected HDR CS.
    nonisolated private func loadHDR(url: URL) throws -> CIImage {
        let key = url as NSURL
        
        // CIImage cache hit?
        if let cached = hdrCache.object(forKey: key) {
            // print("📦 [loadHDR] CIImage cache HIT: \(url.lastPathComponent)")
            
            // Check for RawPixelData to be still cached
            if Self.rawDataCache.object(forKey: key) == nil {
                // print("⚠️  [loadHDR] RawPixelData was evicted! Recreating...")
                // RawPixelData was evicted - recreate it
                // Unfortunately we need to read from disk again
                // (we cannot rebuild it from CIImage easily)
                // So DO NOT return here, keep reading from disk
            } else {
                // Ok, both caches own the object
                return cached
            }
        }
        
        // print("⚠️  [loadHDR] CIImage cache MISS: \(url.lastPathComponent)")
        
        // Check raw data cache
        if let rawData = Self.rawDataCache.object(forKey: key) {
            // print("📦 [loadHDR] RawData cache HIT: \(url.lastPathComponent)")
            return try createCIImageFromRawData(rawData, key: key)
        }
        
        // print("⚠️  [loadHDR] RawData cache MISS: \(url.lastPathComponent)")
        
        // No cache: read from disk (ONLY ONCE per session ideally, but cache eviction forces re-reads)
        // print("📂 [loadHDR] Reading from DISK: \(url.lastPathComponent)")
        
        // 1) Load raw bytes and the original CGImage.
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ProcessingError.cannotReadHDR
        }
        
        let width = cgImage.width
        let height = cgImage.height
        let bitsPerComponent = cgImage.bitsPerComponent
        let bitsPerPixel = cgImage.bitsPerPixel
        let componentsPerPixel = bitsPerPixel / bitsPerComponent
        let properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]) ?? [:]
        
        // print("📂 [loadHDR] Image loaded:")
        // print("   File: \(url.lastPathComponent)")
        // print("   Size: \(width)×\(height)")
        // print("   Bits/comp: \(bitsPerComponent)")
        // print("   Bits/pixel: \(bitsPerPixel)")
        // print("   Components: \(componentsPerPixel)")
        // print("   Color space: \(cgImage.colorSpace?.name as? String ?? "nil")")
        
        // Validation
        if componentsPerPixel < 3 {
            // print("   ⚠️ WARNING: Less than 3 components! Might be grayscale")
        }
        
        if bitsPerComponent != 16 {
            // print("   ⚠️ WARNING: Not 16-bit! Might not be true HDR")
        }
        
        let byteOrderInfo = cgImage.byteOrderInfo
        let isBigEndian = (byteOrderInfo == .order16Big || byteOrderInfo == .orderDefault)
        
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data else {
            throw ProcessingError.cannotReadHDR
        }
        
        // Copy raw bytes.
        let dataLength = CFDataGetLength(data)
        let bytePtr = CFDataGetBytePtr(data)!
        let bytes = Array(UnsafeBufferPointer(start: bytePtr, count: dataLength))
        
        // Also load image properties (for metadata; avoids re-reading).
        
        // 2) Build raw data (for fast histograms).
        let rawData = RawPixelData(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            componentsPerPixel: componentsPerPixel,
            isBigEndian: isBigEndian,
            bytes: bytes,
            cgImage: cgImage,
            properties: properties
        )

        // 3) Create and cache a CIImage from raw data (no additional I/O). This also VALIDATES the
        //    color space and throws for non-HDR inputs. Do it BEFORE caching the raw bytes so an
        //    invalid (e.g. 8-bit / non-PQ) image never lands in rawDataCache, where the
        //    16-bit-assuming readers (percentile CDF, headroom, histograms) would later crash on it.
        let residentCI = try createCIImageFromRawData(rawData, key: key)

        let byteCost = dataLength / (1024 * 1024)  // MB
        // Self.rawDataCache.totalCostLimit = 1024  // Max 1GB
        Self.rawDataCache.setObject(rawData, forKey: key, cost: byteCost)

        return residentCI
    }
    
    /// Helper: create a linear Display P3 CIImage from already-loaded RawPixelData.
    nonisolated private func createCIImageFromRawData(_ rawData: RawPixelData, key: NSURL) throws -> CIImage {
        // Create a CIImage from the CGImage with HDR expansion.
        let fileCI = CIImage(cgImage: rawData.cgImage, options: [CIImageOption.expandToHDR: true])
        
        // Validate the color space: accept any PQ/HLG (ITU-R BT.2100) transfer,
        // not only the canonically-named Display P3 PQ. Primaries are normalized
        // by the linearization to extendedLinearDisplayP3 below.
        guard isHDRTransfer(fileCI.colorSpace) else {
            throw ProcessingError.invalidColorSpace(cs_name(fileCI.colorSpace))
        }
        
        // Materialize in linear P3 (per-worker context inside a batch, shared otherwise).
        guard let residentCG = searchCtx.createCGImage(
            fileCI,
            from: fileCI.extent,
            format: .RGBAf,
            colorSpace: linear_p3
        ) else {
            throw ProcessingError.cannotReadHDR
        }
        
        let residentCI = CIImage(cgImage: residentCG, options: nil)
        
        // Cache CIImage
        let mp = Int(fileCI.extent.width * fileCI.extent.height / 1_000_000)
        // hdrCache.totalCostLimit = 800
        hdrCache.setObject(residentCI, forKey: key, cost: mp)
        
        return residentCI
    }
    
    // MARK: - Histogram Generation
    
    /// Fetch raw pixel data from cache (for histogram calculation).
    nonisolated private func getRawPixelData(url: URL) throws -> RawPixelData {
        let key = url as NSURL
        
        // Cache hit?
        if let cached = Self.rawDataCache.object(forKey: key) {
            // print("📦 [getRawPixelData] Cache HIT: \(url.lastPathComponent)")
            return cached
        }
        
        // print("⚠️  [getRawPixelData] Cache MISS, calling loadHDR...")
        
        // Fallback: load now
        _ = try loadHDR(url: url)
        
        guard let cached = Self.rawDataCache.object(forKey: key) else {
            // print("❌ [getRawPixelData] STILL not in cache after loadHDR!")
            throw ProcessingError.cannotReadHDR
        }
        
        // print("✅ [getRawPixelData] Now in cache after loadHDR")
        return cached
    }
    
    /// Computes histogram for the HDR input (with caching).
    /// Use Metal for a 10–50× speedup (when available).
    @concurrent nonisolated func histogramForHDRInput(url: URL) async throws -> HistogramCalculator.HistogramResult {
        
        let cacheKey = NSString(string: "\(url.absoluteString)|hdr")
        let file = url.lastPathComponent

        // print("📊 [histogramForHDRInput] Called for: \(url.lastPathComponent)")

        // Cache hit?
        if let cached = Self.HistogramCache.object(forKey: cacheKey) {
            // print("   ⚡ Cache HIT")
            return cached
        }

        let tHDR = Prof.tic()
        defer { Prof.toc("histHDR.compute(miss) [\(file)]", tHDR) }
        
        // print("   ❌ Cache MISS - calculating...")
        
        // Fetch raw data from cache.
        let rawData = try getRawPixelData(url: url)
        
        // print("   📦 Raw data loaded:")
        // print("      Size: \(rawData.width)×\(rawData.height)")
        // print("      Bytes: \(rawData.bytes.count)")
        // print("      Bits/comp: \(rawData.bitsPerComponent)")
        
        // Try Metal first.
        let histogram: HistogramCalculator.HistogramResult
        
        if let metalCalc = metalHistogram {
            // print("   🚀 Trying METAL for HDR histogram...")
            if let result = metalCalc.calculateHistogramFromHDR(
                fromBytes: rawData.bytes,
                width: rawData.width,
                height: rawData.height,
                bitsPerComponent: rawData.bitsPerComponent,
                componentsPerPixel: rawData.componentsPerPixel,
                isBigEndian: rawData.isBigEndian,
                smoothWindow: 11
            ) {
                // print("   ✅ Metal succeeded")
                
                // Validation: ensure the histogram is not empty.
                let totalCounts = result.lumaCounts.reduce(0, +)
                // print("   📊 Total luma counts: \(totalCounts)")
                
                if totalCounts == 0 {
                    // print("   ⚠️ WARNING: Histogram is empty (all counts = 0)!")
                }
                
                histogram = result
            } else {
                // print("   ⚠️ Metal FAILED, falling back to CPU...")
                guard let cpuResult = HistogramCalculator.calculateHistogram(
                    fromBytes: rawData.bytes,
                    width: rawData.width,
                    height: rawData.height,
                    bitsPerComponent: rawData.bitsPerComponent,
                    componentsPerPixel: rawData.componentsPerPixel,
                    isBigEndian: rawData.isBigEndian,
                    smoothWindow: 11
                ) else {
                    // print("   ❌ CPU also FAILED!")
                    throw ProcessingError.histogramCalculationFailed
                }
                // print("   ✅ CPU succeeded")
                histogram = cpuResult
            }
        } else {
            // print("   ℹ️ Metal not available, using CPU...")
            guard let cpuResult = HistogramCalculator.calculateHistogram(
                fromBytes: rawData.bytes,
                width: rawData.width,
                height: rawData.height,
                bitsPerComponent: rawData.bitsPerComponent,
                componentsPerPixel: rawData.componentsPerPixel,
                isBigEndian: rawData.isBigEndian,
                smoothWindow: 11
            ) else {
                throw ProcessingError.histogramCalculationFailed
            }
            histogram = cpuResult
        }
        
        // Cache result
        Self.HistogramCache.setObject(histogram, forKey: cacheKey)
        
        return histogram
    }
    
    // Histogram cache. Thread-safe NSCache, accessed from the off-main histogram path.
    nonisolated(unsafe) private static let HistogramCache = NSCache<NSString, HistogramCalculator.HistogramResult>()
    
}
