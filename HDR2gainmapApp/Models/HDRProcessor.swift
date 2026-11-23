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
            let r = try await renderPreviewCore(params: params, baseKey: baseKey as String)
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
        let r = try await renderPreviewCore(params: params, baseKey: baseKey as String)
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
        baseKey: String
    ) async throws -> (image: NSImage, clipped: Int, total: Int, detailed: DetailedClippingStats?) {

        // Cross the actor boundary as a value-type `String` (Sendable); the NSCache API below wants
        // an `NSString`, so re-bridge here. The bridge is lossless and cheap.
        let baseKey = baseKey as NSString

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

    /// Warms the caches for `image` (headroom, percentile CDF + HDR histogram, preview base/overlay)
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
            _ = try? await renderPreviewCore(params: params, baseKey: baseKey as String)
        }

        // Warm the HDR-input histogram too: it depends only on the source image (not the
        // tone-map settings), and the foreground selection otherwise recomputes it (~320 ms)
        // on every navigation. Caching it here makes that a hit.
        if Task.isCancelled { return }
        _ = try? await histogramForHDRInput(url: params.url)
    }
    
    // MARK: - Export

    /// Export settings, captured once (on the main actor) when an export starts — so a running batch
    /// is unaffected by Settings changes made meanwhile, and the off-main encode never reads
    /// preferences itself.
    nonisolated struct ExportOptions: Sendable {
        /// 3-channel (RGB) gain map instead of luma (GUI default: on, registered in the App init).
        let rgbGainMap: Bool
        /// Gain-map resolution divisor: 1 = full, 2 = half.
        let gainMapSubsampleFactor: Int
        /// HEIC lossy-compression quality.
        let quality: Double

        static let defaultQuality = 0.95

        /// The current preferences (`gainMapRGB`, `gainMapSubsampleFactor`, `heicExportQuality`), with
        /// the fallbacks the engine has always used.
        static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> ExportOptions {
            let storedFactor = defaults.integer(forKey: "gainMapSubsampleFactor")
            let storedQuality = defaults.double(forKey: "heicExportQuality")
            return ExportOptions(
                rgbGainMap: defaults.bool(forKey: "gainMapRGB"),
                gainMapSubsampleFactor: storedFactor > 0 ? storedFactor : 1,
                quality: storedQuality > 0 ? storedQuality : defaultQuality
            )
        }
    }

    /// Renders `params` as a gain-map HEIC and writes it to `outputURL`, entirely off the main actor
    /// (`@concurrent`), so the UI stays responsive during an export.
    ///
    /// Writing: the whole file is encoded in memory first and written only once that succeeded, so a
    /// failed or cancelled export never touches an existing file at `outputURL`. The write itself
    /// goes straight to `outputURL` (non-atomic) on purpose: an atomic write or temp-then-rename needs
    /// a sibling temp file, which a file-scoped NSSavePanel grant forbids and which already failed on
    /// external volumes (v1.3.1/1.3.2 history). Writing the exact granted path works for single
    /// exports, batch folders and external disks alike.
    ///
    /// Cancellation is honored between stages (load, tone-map, gain map + encode, write).
    @concurrent nonisolated func export(params: PreviewParams, options: ExportOptions,
                                        to outputURL: URL) async throws {
        let data = try await encodeExport(params: params, options: options)
        try Task.checkCancellation()
        do {
            try data.write(to: outputURL, options: [])
        } catch {
            throw ProcessingError.writeFailed("\(outputURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Encodes `params` as a gain-map HEIC in memory. The SDR base comes from the same builder as
    /// the preview (`buildSDRBase`), so the file matches what was previewed.
    nonisolated private func encodeExport(params: PreviewParams, options: ExportOptions) async throws -> Data {
        try Task.checkCancellation()
        let hdr = try loadHDR(url: params.url)
        let measuredHeadroom = getHeadroomForImage(url: params.url)

        try Task.checkCancellation()
        let sdrBase = try await buildSDRBase(hdr: hdr, params: params, measuredHeadroom: measuredHeadroom)

        try Task.checkCancellation()
        let props = exportProperties(for: params.url)

        // Both kinds are computed by us and assembled as an ISO 21496-1 gain map (Core Image emits only
        // a luma gain map on macOS 15, RGB only on macOS 26+). The SDR base is the same for both.
        let data = options.rgbGainMap
            ? encodeRGBGainMapHEICData(hdr: hdr, sdrBase: sdrBase, baseProps: props,
                                       subsampleFactor: options.gainMapSubsampleFactor, quality: options.quality)
            : encodeMonoManualGainMapHEICData(hdr: hdr, sdrBase: sdrBase, baseProps: props,
                                              subsampleFactor: options.gainMapSubsampleFactor, quality: options.quality)
        guard let data else {
            try Task.checkCancellation()   // nil because the export was cancelled mid-encode
            throw ProcessingError.gainMapGenerationFailed
        }
        return data
    }

    /// The source file's preserved metadata, prepared for the output: the Apple MakerNote headroom
    /// tags (33 & 48) of Apple's legacy gain-map scheme stripped — the output carries an ISO 21496-1
    /// gain map instead (when Core Image encoded the gain map, their presence switched it to the
    /// legacy scheme) — and the app appended to the TIFF `Software` tag.
    nonisolated private func exportProperties(for url: URL) -> [String: Any] {
        var props = extractMetadata(from: url)

        if var makerApple = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] {
            makerApple["33"] = nil
            makerApple["48"] = nil
            props[kCGImagePropertyMakerAppleDictionary as String] = makerApple
        }

        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "<undetermined>"
        if let originalSoftware = tiff["Software"] as? String, !originalSoftware.isEmpty {
            tiff["Software"] = "\(originalSoftware) + HDR2gainmap App v\(appVersion)"
        } else {
            tiff["Software"] = "HDR2gainmapApp v\(appVersion)"
        }
        props[kCGImagePropertyTIFFDictionary as String] = tiff

        // The app does not resize; should that change, set kCGImagePropertyPixelWidth/Height here.
        return props
    }

    // MARK: - RGB Gain Map (`ExportOptions.rgbGainMap`)

    /// Encode the SDR base + a 3-channel (RGB) ISO 21496-1 gain map into an in-memory HEIC `Data`.
    /// Core Image only emits a luma gain map on macOS 15 (RGB is macOS 26+), so we compute the
    /// per-channel gain ourselves. Shared by the export and the RGB `.finalOutput` preview, so both
    /// reconstruct from the exact same bytes. Core Image only emits a luma gain map on macOS 15 (RGB
    /// is macOS 26+), so we render the per-channel gain, build the `ChannelMetadata` XMP, and attach
    /// the payload via `CGImageDestinationAddAuxiliaryDataInfo` with the ISO gain map aux type.
    /// Verified on macOS 15 Intel (reconstructs in Core Image and validates in Adobe's Gain Map Demo App).
    nonisolated private func encodeRGBGainMapHEICData(hdr: CIImage, sdrBase: CIImage,
                                                      baseProps: [String: Any],
                                                      subsampleFactor: Int, quality: Double) -> Data? {
        guard let gm = computeRGBGainMap(hdr: hdr, sdr: sdrBase, factor: subsampleFactor) else { return nil }
        guard let meta = isoGainMapMetadata(channels: 3, gainMapMaxStops: gm.gainMapMaxStops) else { return nil }
        if Task.isCancelled { return nil }   // callers report this as a CancellationError
        guard let baseCG = encode_ctx.createCGImage(sdrBase, from: sdrBase.extent,
                                                    format: .RGB10, colorSpace: p3_cs) else { return nil }
        if Task.isCancelled { return nil }

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
        if Task.isCancelled { return nil }

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

    // MARK: - Manual mono gain map (DEFAULT mono path)

    /// Encode the SDR base + a single-channel (luma) ISO 21496-1 gain map into an in-memory HEIC
    /// `Data`. Mirrors `encodeRGBGainMapHEICData` but emits an `L008` (8-bit, 1-channel) aux, tagged by
    /// us (`gainmap_cs`, ITUR_2100_PQ — see there) instead of letting Core Image pick, with 1-channel
    /// `ChannelMetadata`. The DEFAULT monochrome path in GUI and CLI; the Core Image one is opt-in.
    nonisolated private func encodeMonoManualGainMapHEICData(hdr: CIImage, sdrBase: CIImage,
                                                             baseProps: [String: Any],
                                                             subsampleFactor: Int, quality: Double) -> Data? {
        guard let gm = computeMonoGainMap(hdr: hdr, sdr: sdrBase, factor: subsampleFactor) else { return nil }
        guard let meta = isoGainMapMetadata(channels: 1, gainMapMaxStops: gm.gainMapMaxStops) else { return nil }
        if Task.isCancelled { return nil }   // callers report this as a CancellationError
        guard let baseCG = encode_ctx.createCGImage(sdrBase, from: sdrBase.extent,
                                                    format: .RGB10, colorSpace: p3_cs) else { return nil }
        if Task.isCancelled { return nil }

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
        if Task.isCancelled { return nil }

        // Display-P3 / D65 luminance weights (shared with the headroom / CDF / histogram analysis).
        let (wr, wg, wb) = Constants.displayP3LumaWeights
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

    // MARK: - Metadata Extraction

    /// Extracts EXIF/IPTC/TIFF metadata from cache (zero disk I/O)
    nonisolated private func extractMetadata(from url: URL) -> [String: Any] {
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
    nonisolated private func filterMetadataForPreservation(_ properties: [String: Any]) -> [String: Any] {
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
    /// `@unchecked Sendable`: every stored property is an immutable `let`, so instances (built off the
    /// main actor in `analyzeLinearImage`, then handed back and cached) are safe to share across actors.
    nonisolated final class PercentileCDFBox: NSObject, @unchecked Sendable {
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
        
        // Built by the one-pass linear-image analysis (together with the headroom and the HDR
        // histogram). Off the main actor: on a cold cache it loads and renders the image. Throws if
        // the image can't be loaded → returns false.
        let task = Task.detached(priority: .utility) { [self] () throws -> PercentileCDFBox in
            try analyzeLinearImage(url: url).cdf
        }

        // Registered before the first suspension point, so concurrent callers really share it.
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
    
    /// Number of luminance buckets of the percentile CDF.
    nonisolated static let percentileCDFBins = 2048

    /// Upper end of the percentile CDF's range, in linear units (1.0 = reference white): the peak
    /// luminance, floored at 0.001 nit so a black image still gets a valid, non-zero range.
    nonisolated static func percentileCDFRange(forPeak peak: Float) -> Float {
        max(peak, 0.001 / Constants.referenceHDRwhiteNit)
    }

    /// Uniform luminance histogram over [0, `range`] (linear units) in `bins` buckets — the CPU
    /// twin of the Metal `luminanceBinsLinear` kernel (same binning and clamping).
    nonisolated static func luminanceBins(pixels: UnsafePointer<Float>, width: Int, height: Int,
                                          rowStride: Int, range: Float, bins: Int) -> [Int] {
        let (wr, wg, wb) = Constants.displayP3LumaWeights
        let scale = Float(bins) / range
        let top = Float(bins)
        var histogram = [Int](repeating: 0, count: bins)
        histogram.withUnsafeMutableBufferPointer { hist in
            for y in 0..<height {
                let row = pixels + y * rowStride
                for x in 0..<width {
                    let p = row + x * 4
                    let v = (wr * p[0] + wg * p[1] + wb * p[2]) * scale
                    // Negative → first bin, ≥ bins → last bin (as before); written so that NaN / ±inf
                    // can't trap the Int conversion.
                    let idx = v >= 1 ? (v < top ? Int(v) : bins - 1) : 0
                    hist[idx] += 1
                }
            }
        }
        return histogram
    }

    /// Prefix sums of the luminance buckets → the percentile lookup table.
    private nonisolated static func makePercentileCDF(luminanceBins: [Int], range: Float) -> PercentileCDFBox {
        var cdf = [Int](repeating: 0, count: luminanceBins.count)
        var running = 0
        for i in luminanceBins.indices {
            running += luminanceBins[i]
            cdf[i] = running
        }
        return PercentileCDFBox(maxNits: range * Constants.referenceHDRwhiteNit,
                                cdf: cdf, bins: luminanceBins.count)
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

    /// Clip-detection threshold for the tone-mapped SDR base. A clipped pixel is one whose channel
    /// (or luma) is pinned **at the SDR ceiling** (≈1.0), not strictly above it: `CIToneMapHeadroom`
    /// caps its output at the target headroom (1.0), so on neutral/monochrome content the crushed
    /// highlights land *at* 1.0 and a strict `>1` test misses them entirely (saturated colour content
    /// overshoots past 1.0, which is why a `>1` test only appeared to work there). 0.9999 catches the
    /// pinned pixels while staying tight enough not to flag near-white-but-unclipped tones; verified
    /// to leave colour-image counts essentially unchanged.
    nonisolated static let clipCeilingThreshold: CGFloat = 0.9999

    /// Worst per-channel clip fraction (0...1) of the SDR rendering: `max(frac_R, frac_G, frac_B)`,
    /// where `frac_c` is the fraction of pixels whose channel c is pinned at the SDR ceiling (counted
    /// independently of the other channels). Limiting this curbs single-channel clipping (e.g. a
    /// clipped R channel shifts the reconstructed tint toward yellow).
    nonisolated private func maxPerChannelClipFraction(sdr: CIImage, context: CIContext) -> Double {
        let total = Int(sdr.extent.width) * Int(sdr.extent.height)
        guard total > 0 else { return 0 }
        // One render: the area average of the 3-channel ceiling mask is (frac_R, frac_G, frac_B).
        let avg = areaAverage(channelClipMask(sdr), context: context)
        func fraction(_ v: Float) -> Double { Double(pixelCount(fraction: v, total: total)) / Double(total) }
        return max(fraction(avg[0]), max(fraction(avg[1]), fraction(avg[2])))
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

    /// Maximum Display-P3 luminance over the linear image (linear 1.0 = reference white, so this is
    /// the measured headroom as is). CPU twin of the Metal `maxLuminanceLinear` kernel: non-finite
    /// values are skipped, so the result is always finite and ≥ 0.
    nonisolated static func peakLuminance(pixels: UnsafePointer<Float>, width: Int,
                                          height: Int, rowStride: Int) -> Float {
        let (wr, wg, wb) = Constants.displayP3LumaWeights
        var peak: Float = 0
        for y in 0..<height {
            let row = pixels + y * rowStride
            for x in 0..<width {
                let p = row + x * 4
                let luminance = wr * p[0] + wg * p[1] + wb * p[2]
                if luminance > peak, luminance.isFinite { peak = luminance }   // NaN never compares greater
            }
        }
        return peak
    }
    
    /// Measured headroom of `url` (cached): the peak luminance of its linear image, relative to SDR
    /// reference white. See `analyzeLinearImage`. Returns 1.0 (uncached) if the image can't be read.
    nonisolated func getHeadroomForImage(url: URL) -> Float {
        if let cached = Self.peakLuminanceCache.object(forKey: url as NSURL) {
            return cached.floatValue
        }
        do {
            return try analyzeLinearImage(url: url).headroom
        } catch {
            return 1.0
        }
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
    /// two stay in lock-step. Categories for clipped SDR pixels (a channel pinned at the ceiling, ≈1):
    /// - red/green/blue: only R / G / B clipped; yellow/magenta/cyan: 2 channels clipped.
    /// - "*_dim" variants: the above when **Y is also at the ceiling** (luma clipped too); `all3`: R&G&B all clipped.
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

        // Per-channel masks: a channel pinned at the SDR ceiling (≈1.0) counts as clipped.
        let thr = Self.clipCeilingThreshold
        let rMask = thresh01(extractChannel(sdr, r: 1, g: 0, b: 0), threshold: thr)
        let gMask = thresh01(extractChannel(sdr, r: 0, g: 1, b: 0), threshold: thr)
        let bMask = thresh01(extractChannel(sdr, r: 0, g: 0, b: 1), threshold: thr)

        // Luma (Y) mask, to split "bright" (Y below ceiling) from "dim" (Y at ceiling).
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

    /// Counts clipped pixels per category (opacity-independent). The 13 binary masks are packed three
    /// to an image — one per colour channel — so `CIAreaAverage` yields three counts per render
    /// (5 renders instead of 13). Counts match the overlay, which paints the same masks.
    nonisolated func computeClippingStats(
        sdr: CIImage,
        context: CIContext
    ) -> (clipped: Int, total: Int, detailedStats: DetailedClippingStats)? {
        guard let m = clippingCategoryMasks(sdr: sdr) else { return nil }
        let total = m.total

        // Mask (in R) moved to `channel`, with 1 in the other colour channels, so multiplying three
        // of them packs them as (a, b, c, 1).
        func inChannel(_ mask: CIImage, _ channel: Int) -> CIImage {
            let f = CIFilter.colorMatrix()
            f.inputImage = mask
            let pick = CIVector(x: 1, y: 0, z: 0, w: 0), none = CIVector(x: 0, y: 0, z: 0, w: 0)
            f.rVector = channel == 0 ? pick : none
            f.gVector = channel == 1 ? pick : none
            f.bVector = channel == 2 ? pick : none
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            f.biasVector = CIVector(x: channel == 0 ? 0 : 1, y: channel == 1 ? 0 : 1, z: channel == 2 ? 0 : 1, w: 0)
            return f.outputImage!
        }
        func counts(_ masks: [CIImage]) -> [Int] {
            var packed = inChannel(masks[0], 0)
            for (i, mask) in masks.enumerated().dropFirst() { packed = andMask(packed, inChannel(mask, i)) }
            let avg = areaAverage(packed.cropped(to: sdr.extent), context: context)
            return (0..<masks.count).map { pixelCount(fraction: avg[$0], total: total) }
        }

        let a = counts([m.onlyR_bright, m.onlyG_bright, m.onlyB_bright])
        let b = counts([m.rg_bright, m.rb_bright, m.gb_bright])
        let c = counts([m.onlyR_dim, m.onlyG_dim, m.onlyB_dim])
        let d = counts([m.rg_dim, m.rb_dim, m.gb_dim])
        let e = counts([m.all3])
        let detailedStats = DetailedClippingStats(
            total: total,
            redOnly: a[0], greenOnly: a[1], blueOnly: a[2],
            yellowBright: b[0], magentaBright: b[1], cyanBright: b[2],
            redDim: c[0], greenDim: c[1], blueDim: c[2],
            yellowDim: d[0], magentaDim: d[1], cyanDim: d[2],
            white: e[0]
        )
        return (detailedStats.totalClipped, total, detailedStats)
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
    
    
    /// 3-channel ceiling mask of `sdr`: R, G and B are each 1 where that channel is pinned at the SDR
    /// ceiling (≥ `clipCeilingThreshold`), else 0. Per channel it is the same arithmetic as
    /// `thresh01(extractChannel(…))` (used by the overlay), so one render yields all three channels.
    nonisolated private func channelClipMask(_ sdr: CIImage) -> CIImage {
        let thr = Self.clipCeilingThreshold
        let sub = CIFilter.colorMatrix()
        sub.inputImage = sdr
        sub.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        sub.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        sub.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        sub.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        sub.biasVector = CIVector(x: -thr, y: -thr, z: -thr, w: 0)

        let clampPos = CIFilter.colorClamp()
        clampPos.inputImage = sub.outputImage!
        clampPos.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampPos.maxComponents = CIVector(x: 1e6, y: 1e6, z: 1e6, w: 1)

        let gain: CGFloat = 1_000_000
        let amp = CIFilter.colorMatrix()
        amp.inputImage = clampPos.outputImage!
        amp.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        amp.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        amp.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        amp.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        let clamp01 = CIFilter.colorClamp()
        clamp01.inputImage = amp.outputImage!
        clamp01.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp01.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp01.outputImage!
    }

    /// Per-channel mean of `image` over its extent (one `CIAreaAverage` render), as RGBA floats.
    nonisolated private func areaAverage(_ image: CIImage, context: CIContext) -> [Float] {
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = image.extent
        var px = [Float](repeating: 0, count: 4)
        guard let out = f.outputImage else { return px }
        context.render(out, toBitmap: &px, rowBytes: MemoryLayout<Float>.size * 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return px
    }

    /// A fraction of `total` pixels (from an area average or histogram bin) as a pixel count.
    nonisolated private func pixelCount(fraction: Float, total: Int) -> Int {
        Int((max(0, min(1, fraction)) * Float(total)).rounded(.toNearestOrAwayFromZero))
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
                try Task.checkCancellation()
                throw ProcessingError.gainMapGenerationFailed
            }
            data = d
        } else {
            // Luma gain map — same bytes the exporter writes.
            guard let d = encodeMonoManualGainMapHEICData(hdr: hdr, sdrBase: sdrBase, baseProps: [:],
                                                          subsampleFactor: subsampleFactor, quality: 1.0) else {
                try Task.checkCancellation()
                throw ProcessingError.gainMapGenerationFailed
            }
            data = d
        }
        guard let reconstructed = CIImage(data: data, options: [.expandToHDR: true]) else {
            throw ProcessingError.gainMapExtractionFailed
        }
        return reconstructed
    }

    /// Extracts the gain map as a standalone CIImage for the `.gainMap` preview: the 3-channel gain map
    /// we compute when RGB is on, else the hand-assembled luma gain map as grayscale.
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
                try Task.checkCancellation()
                throw ProcessingError.gainMapGenerationFailed
            }
            let img = CIImage(bitmapData: gm.data,
                              bytesPerRow: gm.width * 4,
                              size: CGSize(width: gm.width, height: gm.height),
                              format: .ARGB8,
                              colorSpace: p3_cs)
            return upscaledToBase(img, gmWidth: gm.width, gmHeight: gm.height)
        }
        // Luma: visualize our hand-assembled luma gain map. Expand the L008 bytes into ARGB8
        // gray (R=G=B=gain, A=255) so we can build the CIImage with the same .ARGB8 path as RGB.
        guard let gm = computeMonoGainMap(hdr: hdr, sdr: sdrBase, factor: subsampleFactor) else {
            try Task.checkCancellation()
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
            _ = try await renderPreviewCore(params: params, baseKey: baseKey as String)
            guard let rendered = previewBaseCache.object(forKey: baseKey) else {
                throw ProcessingError.imageConversionFailed
            }
            cachedBase = rendered
        }

        let tMetal = Prof.tic()
        defer { Prof.toc("histSDR.metalHist [\(file)]", tMetal) }
        return try calculateHistogramFromSDR(cachedBase)
    }

    /// SDR histogram of `workingCIImage`: Metal when available, else CPU.
    nonisolated private func calculateHistogramFromSDR(
        _ workingCIImage: CIImage
    ) throws -> HistogramCalculator.HistogramResult {
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

    // MARK: - Source decode cache

    /// Cache of each input's source decode (ImageIO `CGImage` + properties): re-linearizes after
    /// `hdrCache` evicts the linear image without touching the disk, and backs metadata reads.
    nonisolated(unsafe) private static let rawDataCache = NSCache<NSURL, RawPixelData>()
    
    // MARK: - Public Cache Access
    
    /// Expose the raw-data cache for HDRImage.
    /// Allows HDRImage.loadMetadata() to reuse already-loaded data.
    nonisolated func getCachedRawPixelData(url: URL) -> RawPixelData? {
        let key = url as NSURL
        return Self.rawDataCache.object(forKey: key)
    }

    /// Whether the image's pixel data is currently resident in memory (source decode or linear CIImage).
    /// Used by the UI to flag thumbnails that will load quickly (no disk read).
    nonisolated func isLoaded(url: URL) -> Bool {
        let key = url as NSURL
        return Self.rawDataCache.object(forKey: key) != nil || hdrCache.object(forKey: key) != nil
    }
    
    // MARK: - HDR Loading with Raw Data Cache
    
    /// Load HDR once: decode the file once, then cache both the source decode and the materialized
    /// linear CIImage. Throws ProcessingError.invalidColorSpace if the file isn't the expected HDR CS.
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
        
        // 1) Open the source (ImageIO decodes lazily, when Core Image first reads the pixels).
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ProcessingError.cannotReadHDR
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]) ?? [:]

        // 2) Source decode + metadata. The encoded pixel bytes themselves are no longer copied out:
        //    every measurement reads the linearized image instead (see `analyzeLinearImage`).
        let rawData = RawPixelData(
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: cgImage.bitsPerComponent,
            cgImage: cgImage,
            properties: properties
        )

        // 3) Linearize + cache (no additional I/O). This also VALIDATES the color space and throws
        //    for non-HDR inputs — before anything is cached, so an invalid image never lands in
        //    either cache.
        let residentCI = try createCIImageFromRawData(rawData, key: key)

        // Cost = the decoded source size, in MB (an estimate: ImageIO owns that buffer).
        let decodedMB = max(1, cgImage.bytesPerRow * cgImage.height / (1024 * 1024))
        Self.rawDataCache.setObject(rawData, forKey: key, cost: decodedMB)

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
        
        // Linear P3 image (per-worker context inside a batch, shared otherwise). NOTE: this
        // `createCGImage` overload is *deferred* — it returns at once and renders when the pixels are
        // first needed; Core Image then keeps its own GPU copy. Deliberately kept that way: forcing
        // it (`deferred: false`) puts 16 B/px of floats in RAM that Core Image re-uploads on every
        // render (measured: a 22 MP preview + stats went from ~1.5 s to ~14 s). Reading pixels on the
        // CPU from this CGImage would re-render each time, so the measurements render it themselves
        // (see `analyzeLinearImage`).
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
    
    // MARK: - Linear-image analysis (single source for every HDR measurement)

    /// What the one-pass analysis measures on an image's linear pixels.
    nonisolated struct LinearImageAnalysis: Sendable {
        let headroom: Float                                  // peak luminance (1.0 = reference white)
        let cdf: PercentileCDFBox                            // percentile lookup table
        let histogram: HistogramCalculator.HistogramResult   // HDR-input histogram
    }

    /// Measures `url` once — measured headroom, percentile CDF and HDR-input histogram — from a
    /// single render of its linear image, and fills the three caches those feed. The linear image is
    /// exactly what `CIToneMapHeadroom` consumes (extended-linear Display P3, 1.0 = reference
    /// white), decoded by Core Image from whatever the file carries, so the measurements hold for PQ
    /// and HLG inputs and any source primaries. (They used to scan the file's encoded samples and
    /// always decode them as PQ: an HLG input measured ~10× too bright.)
    /// GPU when Metal is available (per-worker calculator inside a batch); CPU otherwise.
    @discardableResult
    nonisolated private func analyzeLinearImage(url: URL) throws -> LinearImageAnalysis {
        let image = try loadHDR(url: url)
        let bins = Self.percentileCDFBins

        let measured: MetalHistogramCalculator.LinearMeasurements
        if let metal = searchHistogram,
           let m = metal.measureLinear(ciImage: image, context: searchCtx, colorSpace: linear_p3,
                                       luminanceBinCount: bins,
                                       luminanceRange: Self.percentileCDFRange(forPeak:)) {
            measured = m
        } else {
            measured = try withLinearPixels(of: image) { pixels, width, height, rowStride in
                let peak = Self.peakLuminance(pixels: pixels, width: width, height: height, rowStride: rowStride)
                let range = Self.percentileCDFRange(forPeak: peak)
                guard let histogram = HistogramCalculator.calculateHistogramFromLinear(
                    pixels: pixels, width: width, height: height, rowStride: rowStride) else {
                    throw ProcessingError.histogramCalculationFailed
                }
                return MetalHistogramCalculator.LinearMeasurements(
                    peakLuminance: peak,
                    histogram: histogram,
                    luminanceBins: Self.luminanceBins(pixels: pixels, width: width, height: height,
                                                      rowStride: rowStride, range: range, bins: bins),
                    luminanceRange: range)
            }
        }

        let analysis = LinearImageAnalysis(
            headroom: measured.peakLuminance,
            cdf: Self.makePercentileCDF(luminanceBins: measured.luminanceBins, range: measured.luminanceRange),
            histogram: measured.histogram)
        let key = url as NSURL
        Self.peakLuminanceCache.setObject(NSNumber(value: analysis.headroom), forKey: key)
        Self.percentileCDFCache.setObject(analysis.cdf, forKey: key)
        Self.HistogramCache.setObject(analysis.histogram, forKey: Self.hdrHistogramKey(url))
        return analysis
    }

    /// CPU fallback only: renders `image` (linear P3, RGBA Float32) into a temporary buffer and runs
    /// `body` over it. `rowStride` is in floats. The pointer is valid only inside `body`.
    nonisolated private func withLinearPixels<T>(
        of image: CIImage,
        _ body: (_ pixels: UnsafePointer<Float>, _ width: Int, _ height: Int, _ rowStride: Int) throws -> T
    ) throws -> T {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { throw ProcessingError.cannotReadHDR }
        var buffer = [Float](repeating: 0, count: width * height * 4)
        searchCtx.render(image, toBitmap: &buffer, rowBytes: width * 4 * MemoryLayout<Float>.stride,
                         bounds: image.extent, format: .RGBAf, colorSpace: linear_p3)
        return try buffer.withUnsafeBufferPointer { pixels in
            try body(pixels.baseAddress!, width, height, width * 4)
        }
    }

    // MARK: - Histogram Generation

    nonisolated private static func hdrHistogramKey(_ url: URL) -> NSString {
        NSString(string: "\(url.absoluteString)|hdr")
    }

    /// Computes the histogram for the HDR input (cached), via the one-pass linear-image analysis.
    @concurrent nonisolated func histogramForHDRInput(url: URL) async throws -> HistogramCalculator.HistogramResult {
        if let cached = Self.HistogramCache.object(forKey: Self.hdrHistogramKey(url)) {
            return cached
        }
        let tHDR = Prof.tic()
        defer { Prof.toc("histHDR.compute(miss) [\(url.lastPathComponent)]", tHDR) }
        return try analyzeLinearImage(url: url).histogram
    }
    
    // Histogram cache. Thread-safe NSCache, accessed from the off-main histogram path.
    nonisolated(unsafe) private static let HistogramCache = NSCache<NSString, HistogramCalculator.HistogramResult>()
    
}
