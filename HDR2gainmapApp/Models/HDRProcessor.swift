import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Bridge between the CLI pipeline and SwiftUI; orchestrates HDR image processing.
@MainActor
class HDRProcessor {
    
    private let hdrCache = NSCache<NSURL, CIImage>()
    
    // Short‑term preview cache (key = URL + settings fingerprint).
    private let previewBaseCache = NSCache<NSString, CIImage>()
    private let previewOverlayCache = NSCache<NSString, CIImage>()
    private let previewCountsCache = NSCache<NSString, NSDictionary>() // ["c": Int, "t": Int]
    
    private static var peakLuminanceCache = NSCache<NSURL, NSNumber>()
    
    // Percentile-derived headroom lookup (built once per image, then reused for real-time UI updates).
    private static let percentileCDFCache = NSCache<NSURL, PercentileCDFBox>()
    
    // In-flight builders so multiple callers (UI + preview/export) don't duplicate work.
    private var percentileCDFInFlight: [NSURL: Task<PercentileCDFBox, Error>] = [:]
    
    private func previewSettingsFingerprint(_ s: ProcessingSettings) -> String {
        switch s.method {
        case .peakMax:
            return "m=peakMax;r=\(s.tonemapRatio)"
        case .percentile:
            return "m=percentile;p=\(s.percentile)"
        case .direct:
            let sh = s.directSourceHeadroom ?? -1
            let th = s.directTargetHeadroom ?? -1
            return "m=direct;sh=\(sh);th=\(th)"
        }
    }
    private func previewKey(url: URL, settings: ProcessingSettings) -> NSString {
        let k = url.absoluteString + "|" + previewSettingsFingerprint(settings)
        return NSString(string: k)
    }
    
    
    static let shared = HDRProcessor()
    
    private let linear_p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private let p3_cs = CGColorSpace(name: CGColorSpace.displayP3)!
    private let hdr_required = CGColorSpace.displayP3_PQ as String
    
    // Metal-backed histogram calculator (falls back to CPU when unavailable).
    private let metalHistogram = MetalHistogramCalculator()
    
    private lazy var ctx_linear_p3: CIContext = {
        CIContext(options: [.workingColorSpace: linear_p3,
                            .outputColorSpace: linear_p3])
    }()
    
    private lazy var encode_ctx = CIContext()
    
    private init() {
        previewBaseCache.countLimit = 32
        previewOverlayCache.countLimit = 32
        previewCountsCache.countLimit = 64
    }
    
    // MARK: - Public API
    
    // Convenience overload that preserves the original API:
    func generatePreview(for image: HDRImage) async throws -> NSImage {
        try await generatePreview(for: image, reportClipping: nil)
    }
    
    // Nuova versione con callback
    
    func generatePreview(
        for image: HDRImage,
        reportClipping: ((Int, Int) -> Void)?
    ) async throws -> NSImage {
        
        let baseKey = previewKey(url: image.url, settings: image.settings)
        let wantOverlay = image.settings.showClippedOverlay
        
        // 1) HIT overlay?
        if wantOverlay, let cachedOverlay = previewOverlayCache.object(forKey: baseKey) {
            if let ct = previewCountsCache.object(forKey: baseKey) as? [String: Int],
               let c = ct["c"], let t = ct["t"] {
                reportClipping?(c, t)
            } else {
                reportClipping?(0, 0)
            }
            return try ciImageToNSImage(cachedOverlay)
        }
        
        // 2) HIT base?
        if !wantOverlay, let cachedBase = previewBaseCache.object(forKey: baseKey) {
            reportClipping?(0, 0)
            return try ciImageToNSImage(cachedBase)
        }
        
        // 3) MISS → tonemap
        let hdr = try loadHDR(url: image.url)
        
        // Compute headroom using the shared, consistent method.
        // print("   🔍 [generatePreview] About to call getHeadroomForImage...")
        let measuredHeadroom = getHeadroomForImage(url: image.url)
        // print("   🔍 [generatePreview] getHeadroomForImage returned: \(measuredHeadroom)")
        
        let sdrBase: CIImage
        switch image.settings.method {
        case .peakMax:
            // PeakMax: use the derived formula.
            let derivedHeadroom = max(1.0, 1.0 + measuredHeadroom - powf(measuredHeadroom, image.settings.tonemapRatio))
            guard let s = tonemap_sdr(from: hdr, headroom_ratio: derivedHeadroom) else {
                throw ProcessingError.tonemapFailed
            }
            sdrBase = s
            
            //        case .percentile:
            //            // Percentile: derive headroom from the percentile.
            //            guard let percentileHeadroom = calculatePercentileHeadroom(
            //                url: image.url,
            //                percentile: image.settings.percentile
            //            ) else {
            //                throw ProcessingError.headroomCalculationFailed
            //            }
            //            guard let s = tonemap_sdr(from: hdr, headroom_ratio: percentileHeadroom) else {
            //                throw ProcessingError.tonemapFailed
            //            }
            //            sdrBase = s
            
        case .percentile:
            // Percentile: derive the source headroom from image content at the selected percentile.
            // The histogram UI uses the same cached lookup so the magenta indicator stays responsive while dragging.
            let percentileHeadroom = try await percentileHeadroom(url: image.url, percentile: image.settings.percentile)
            guard let s = tonemap_sdr(from: hdr, headroom_ratio: percentileHeadroom) else {
                throw ProcessingError.tonemapFailed
            }
            sdrBase = s
            
        case .direct:
            // Direct: use explicit user-provided values.
            // Defaults to measuredHeadroom when not provided.
            let sH = image.settings.directSourceHeadroom ?? measuredHeadroom
            let tH = image.settings.directTargetHeadroom ?? 1.0
            
            // Clamp to a reasonable range (0.1× to 2× the measured value).
            let maxLimit = max(1.0, measuredHeadroom * 2.0)
            let sH_clamped = min(max(sH, 0.1), maxLimit)
            let tH_clamped = min(max(tH, 0.1), maxLimit)
            
            guard let s = tonemap_sdr(from: hdr, sourceHeadroom: sH_clamped, targetHeadroom: tH_clamped) else {
                throw ProcessingError.tonemapFailed
            }
            sdrBase = s
        }
        
        previewBaseCache.setObject(sdrBase, forKey: baseKey)
        
        // 4) If no overlay is needed, return.
        if !wantOverlay {
            reportClipping?(0, 0)
            return try ciImageToNSImage(sdrBase)
        }
        
        // 5) Overlay needed → build it from the base preview.
        if let r = addColorizedClippingOverlayAndCount(sdr: sdrBase, context: ctx_linear_p3) {
            previewOverlayCache.setObject(r.imageWithOverlay, forKey: baseKey)
            previewCountsCache.setObject(["c": r.clipped, "t": r.total] as NSDictionary, forKey: baseKey)
            reportClipping?(r.clipped, r.total)
            return try ciImageToNSImage(r.imageWithOverlay)
        } else {
            reportClipping?(0, 0)
            return try ciImageToNSImage(sdrBase)
        }
    }
    
    /// Esporta singola immagine come HEIC con gain map
    /// Exports a single image as HEIC with gain map
    func exportImage(_ image: HDRImage, to outputURL: URL) async throws {
        
        let hdr = try loadHDR(url: image.url)
        
        // Compute headroom using the shared, consistent method.
        let measuredHeadroom = getHeadroomForImage(url: image.url)
        
        // Tonemap SDR base
        var sdr: CIImage?
        let derivedHeadroom: Float  // For metadata.
        
        switch image.settings.method {
        case .peakMax:
            let calculated = max(1.0, 1.0 + measuredHeadroom - powf(measuredHeadroom, image.settings.tonemapRatio))
            derivedHeadroom = calculated
            sdr = tonemap_sdr(from: hdr, headroom_ratio: calculated)
            
        case .percentile:
            let percentileHeadroom = try await percentileHeadroom(url: image.url, percentile: image.settings.percentile)
            derivedHeadroom = percentileHeadroom
            sdr = tonemap_sdr(from: hdr, headroom_ratio: percentileHeadroom)
            
        case .direct:
            let sH = image.settings.directSourceHeadroom ?? measuredHeadroom
            let tH = image.settings.directTargetHeadroom ?? 1.0
            
            let maxLimit = max(1.0, measuredHeadroom * 2.0)
            let sH_clamped = min(max(sH, 0.1), maxLimit)
            let tH_clamped = min(max(tH, 0.1), maxLimit)
            
            derivedHeadroom = sH_clamped
            sdr = tonemap_sdr(from: hdr, sourceHeadroom: sH_clamped, targetHeadroom: tH_clamped)
        }
        
        guard let sdrBase = sdr else {
            throw ProcessingError.tonemapFailed
        }
        
        let sdrFinal = sdrBase
        
        // Generate gain map (temp HEIC)
        let tmp_options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0,
            CIImageRepresentationOption.hdrImage: hdr,
            CIImageRepresentationOption.hdrGainMapAsRGB: false
        ]
        
        guard let tmp_data = encode_ctx.heifRepresentation(of: sdrFinal,
                                                           format: .RGB10,
                                                           colorSpace: p3_cs,
                                                           options: tmp_options) else {
            throw ProcessingError.gainMapGenerationFailed
        }
        
        guard let gain_map = CIImage(data: tmp_data, options: [.auxiliaryHDRGainMap: true]) else {
            throw ProcessingError.gainMapExtractionFailed
        }
        
        // Add Apple Maker metadata.
        let maker = maker_apple_from_headroom(derivedHeadroom)
        guard let chosen = maker.default else {
            throw ProcessingError.makerAppleMetadataFailed
        }
        
        var props = hdr.properties
        var maker_apple = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        maker_apple["33"] = chosen.maker33
        maker_apple["48"] = chosen.maker48
        props[kCGImagePropertyMakerAppleDictionary as String] = maker_apple
        let sdr_with_props = sdrFinal.settingProperties(props)
        
        // Read quality from UserDefaults (set in Preferences)
        let heicQuality = UserDefaults.standard.double(forKey: "heicExportQuality")
        let quality = (heicQuality > 0) ? heicQuality : 0.97  // Fallback to 0.97 if not set
        
        // Final export
        let export_options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality,
            CIImageRepresentationOption.hdrGainMapImage: gain_map,
            CIImageRepresentationOption.hdrGainMapAsRGB: false
        ]
        
        let method = resolveExportMethodPreference()
        switch method {
        case .heif:
            try encode_ctx.writeHEIFRepresentation(of: sdr_with_props,
                                                   to: outputURL,
                                                   format: .RGB10,
                                                   colorSpace: p3_cs,
                                                   options: export_options)
        case .heif10:
            try encode_ctx.writeHEIF10Representation(of: sdr_with_props,
                                                     to: outputURL,
                                                     colorSpace: p3_cs,
                                                     options: export_options)
        }
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
        
        // Ensure raw bytes are already cached (loadHDR is called by preview/histograms, and headroom measurement also warms it).
        let rawData: RawPixelData
        do {
            rawData = try getRawPixelData(url: url)
        } catch {
            return false
        }
        
        // Use the cached peak luminance (computed via Metal when available) to normalize the CDF.
        let peakHeadroom = getHeadroomForImage(url: url)
        let peakNits = max(0.001, peakHeadroom * Constants.referenceHDRwhiteNit)
        
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
    
    
    /// Computes headroom from a percentile on raw pixel data.
    ///
    /// This is primarily used by preview/export. The histogram UI should call `cachedPercentileHeadroom`
    /// so it stays responsive while the user drags the Percentile slider.
    //    private func calculatePercentileHeadroom(url: URL, percentile: Float) -> Float? {
    //        if let cached = cachedPercentileHeadroom(url: url, percentile: percentile) {
    //            return cached
    //        }
    //
    //        do {
    //            let rawData = try getRawPixelData(url: url)
    //            let peakHeadroom = getHeadroomForImage(url: url)
    //            let peakNits = max(0.001, peakHeadroom * Constants.referenceHDRwhiteNit)
    //
    //            let box = Self.buildPercentileCDF(
    //                bytes: rawData.bytes,
    //                width: rawData.width,
    //                height: rawData.height,
    //                componentsPerPixel: rawData.componentsPerPixel,
    //                isBigEndian: rawData.isBigEndian,
    //                peakNits: peakNits,
    //                bins: 2048
    //            )
    //
    //            Self.percentileCDFCache.setObject(box, forKey: url as NSURL)
    //            return Self.headroomFromCDF(box, percentile: percentile)
    //        } catch {
    //            return nil
    //        }
    //    }
    
    // MARK: - Headroom
    
    
    //            print("🔎 Percentile=\(pShown) → headroom=\(headroom)")
    
    /// Computes raw headroom (no cache; prefer getHeadroomForImage() instead).
    /// Use Metal for a 10–100× speedup (when available).
    @MainActor
    func computeMeasuredHeadroomRaw(url: URL) throws -> Float {
        // Fetch raw pixel data from cache.
        let rawData = try getRawPixelData(url: url)
        
        // Try Metal first.
        let peakNits: Float
        
        if let metalCalc = metalHistogram,
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
    @MainActor
    func getHeadroomForImage(url: URL) -> Float {
        let key = url as NSURL
        
        // Cache hit?
        if let cached = Self.peakLuminanceCache.object(forKey: key) {
            // print("   ⚡ Peak luminance cache HIT (0ms): \(cached.floatValue)")
            return cached.floatValue
        }
        
        // print("   ❌ Peak luminance cache MISS, calculating...")
        
        do {
            let headroom = try computeMeasuredHeadroomRaw(url: url)
            
            // Validation
            // print("   📊 Computed headroom: \(headroom)")
            
            if headroom <= 1.0 {
                // print("   ⚠️ WARNING: Headroom is 1.0 or less! This might indicate:")
                // print("      - Image is SDR (not HDR)")
                // print("      - Peak luminance calculation failed")
                // print("      - Corrupted image data")
            }
            
            Self.peakLuminanceCache.setObject(NSNumber(value: headroom), forKey: key)
            
            return headroom
        } catch {
            // print("   ❌ Failed to compute headroom: \(error)")
            return 1.0
        }
    }
    
    /// Computes absolute peak luminance (nits) from raw pixel data.
    private func calculatePeakLuminanceNits(
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
    
    /// Multi-color overlay for clipped SDR pixels (maxRGB > 1):
    /// - red/green/blue: only R / G / B is clipped.
    /// - yellow/magenta/cyan: 2 channels clipped.
    /// - **dim** (half intensity) for the above cases when **Y ≥ 1** but not full RGB clipping.
    /// - **black** when **all three** channels are clipped (R&G&B > 1).
    func addColorizedClippingOverlayAndCount(
        sdr: CIImage,
        context: CIContext
    ) -> (imageWithOverlay: CIImage, clipped: Int, total: Int)? {
        
        // --- Helpers -----------------------------------------------------------
        func extractChannel(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
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
        
        func thresh01(_ monoR: CIImage, threshold: CGFloat = 1.0) -> CIImage {
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
        
        func andMask(_ a: CIImage, _ b: CIImage) -> CIImage {
            let f = CIFilter.multiplyCompositing()
            f.inputImage = a
            f.backgroundImage = b
            return f.outputImage!
        }
        
        func andNot(_ a: CIImage, _ b: CIImage) -> CIImage {
            andMask(a, invert01(b)) // a ∧ ¬b
        }
        
        func maxMask(_ a: CIImage, _ b: CIImage) -> CIImage {
            let f = CIFilter.maximumCompositing()
            f.inputImage = a
            f.backgroundImage = b
            return f.outputImage!
        }
        
        func toAlpha(_ monoR: CIImage) -> CIImage {
            let m = CIFilter.colorMatrix()
            m.inputImage = monoR
            m.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            m.aVector = CIVector(x: 1, y: 0, z: 0, w: 0) // alpha := R
            return m.outputImage!
        }
        
        func layer(color: CIColor, mask: CIImage, over bg: CIImage) -> CIImage {
            let tint = CIImage(color: color).cropped(to: sdr.extent)
            let alpha = toAlpha(mask)
            return CIFilter(name: "CIBlendWithAlphaMask",
                            parameters: [kCIInputImageKey: tint,
                               kCIInputBackgroundImageKey: bg,
                                     kCIInputMaskImageKey: alpha])!.outputImage!
        }
        
        // --- 1) Per-channel masks (threshold 1.0 + optional epsilon) ---------
        let eps: CGFloat = 1e-6
        let thr: CGFloat = 1.0 + eps
        
        let rMono = extractChannel(sdr, r: 1, g: 0, b: 0)
        let gMono = extractChannel(sdr, r: 0, g: 1, b: 0)
        let bMono = extractChannel(sdr, r: 0, g: 0, b: 1)
        
        let rMask = thresh01(rMono, threshold: thr)
        let gMask = thresh01(gMono, threshold: thr)
        let bMask = thresh01(bMono, threshold: thr)
        
        // --- 2) Maschera Y (luminanza) su SDR -------------------------------
        let yMono = linear_luma(sdr)                 // Use the top-level helper function.
        let yMask = thresh01(yMono, threshold: thr)  // 1 dove Y ≥ 1 (±eps)
        
        // --- 3) Mutually exclusive channel categories ------------------------------
        let notR = invert01(rMask), notG = invert01(gMask), notB = invert01(bMask)
        
        let all3  = andMask(andMask(rMask, gMask), bMask)
        
        let onlyR = andMask(andMask(rMask, notG), notB)
        let onlyG = andMask(andMask(gMask, notR), notB)
        let onlyB = andMask(andMask(bMask, notR), notG)
        
        let rgOnly = andMask(andMask(rMask, gMask), notB)
        let rbOnly = andMask(andMask(rMask, bMask), notG)
        let gbOnly = andMask(andMask(gMask, bMask), notR)
        
        // --- 4) Split “bright/dim” in base a Y ------------------------------
        // bright: categoria ∧ ¬Y ; dim: categoria ∧ Y
        let onlyR_bright = andNot(onlyR, yMask), onlyR_dim = andMask(onlyR, yMask)
        let onlyG_bright = andNot(onlyG, yMask), onlyG_dim = andMask(onlyG, yMask)
        let onlyB_bright = andNot(onlyB, yMask), onlyB_dim = andMask(onlyB, yMask)
        
        let rg_bright = andNot(rgOnly, yMask), rg_dim = andMask(rgOnly, yMask)
        let rb_bright = andNot(rbOnly, yMask), rb_dim = andMask(rbOnly, yMask)
        let gb_bright = andNot(gbOnly, yMask), gb_dim = andMask(gbOnly, yMask)
        
        // --- 5) Conteggio: any channel clipped (coerente con maxRGB) --------
        let anyMask = maxMask(maxMask(rMask, gMask), bMask)
        let (clipped, total) = clippedCountViaAreaAverage(binaryMaskR: anyMask, context: context)
        
        // --- DEBUG: per-category percentages --------------------------------
        do {
            // Helper: compute fraction (0..1) from a binary mask (R=mask) via CIAreaAverage.
            func fraction(_ maskR: CIImage, ctx: CIContext) -> Double {
                let avg = CIFilter.areaAverage()
                avg.inputImage = maskR
                avg.extent = maskR.extent
                let out = avg.outputImage!
                var px = [Float](repeating: 0, count: 4)
                ctx.render(out,
                           toBitmap: &px,
                           rowBytes: MemoryLayout<Float>.size * 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf,
                           colorSpace: nil)
                return Double(px[0].isFinite ? px[0] : 0)
            }
            func pct(_ x: Double) -> String { String(format: "%.3f%%", x * 100.0) }
        }
        
        // --- 6) Compositing a layer: bright → dim → black (all3) ------------
        var composited = sdr
        
        // bright (pieni)
        composited = layer(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1), mask: onlyR_bright, over: composited) // red
        composited = layer(color: CIColor(red: 0, green: 1, blue: 0, alpha: 1), mask: onlyG_bright, over: composited) // green
        composited = layer(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1), mask: onlyB_bright, over: composited) // blue
        composited = layer(color: CIColor(red: 1, green: 1, blue: 0, alpha: 1), mask: rg_bright,   over: composited) // yellow
        composited = layer(color: CIColor(red: 1, green: 0, blue: 1, alpha: 1), mask: rb_bright,   over: composited) // magenta
        composited = layer(color: CIColor(red: 0, green: 1, blue: 1, alpha: 1), mask: gb_bright,   over: composited) // cyan
        
        // dim (mezzo)
        composited = layer(color: CIColor(red: 0.5, green: 0,   blue: 0,   alpha: 1), mask: onlyR_dim, over: composited)
        composited = layer(color: CIColor(red: 0,   green: 0.5, blue: 0,   alpha: 1), mask: onlyG_dim, over: composited)
        composited = layer(color: CIColor(red: 0,   green: 0,   blue: 0.5, alpha: 1), mask: onlyB_dim, over: composited)
        composited = layer(color: CIColor(red: 0.5, green: 0.5, blue: 0,   alpha: 1), mask: rg_dim,    over: composited)
        composited = layer(color: CIColor(red: 0.5, green: 0,   blue: 0.5, alpha: 1), mask: rb_dim,    over: composited)
        composited = layer(color: CIColor(red: 0,   green: 0.5, blue: 0.5, alpha: 1), mask: gb_dim,    over: composited)
        
        // Black for RGB (last, on top of everything).
        composited = layer(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1), mask: all3, over: composited)
        
        return (composited, clipped, total)
    }
    
    
    private func clippedCountViaAreaAverage(binaryMaskR: CIImage, context: CIContext) -> (Int, Int) {
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
    
    private func ciImageToNSImage(_ ciImage: CIImage) throws -> NSImage {
        guard let cgImage = encode_ctx.createCGImage(ciImage, from: ciImage.extent) else {
            throw ProcessingError.imageConversionFailed
        }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: ciImage.extent.width, height: ciImage.extent.height))
        return nsImage
    }
    
    /// Computes the histogram for the SDR output (no caching; always recomputed).
    /// Important: use the BASE preview without the clipping overlay.
    func histogramForSDROutput(image: HDRImage) async throws -> HistogramCalculator.HistogramResult {
        
        // print("🔍 [SDR Histogram] Requested for: \(image.url.lastPathComponent)")
        // print("   Method: \(image.settings.method)")
        // print("   ⚡ NO CACHE - always regenerating")
        
        // Note: generatePreview() may return an image *with* a clipping overlay.
        // Approach: access the BASE preview cache directly.
        
        let baseKey = previewKey(url: image.url, settings: image.settings)
        
        // print("   → Checking preview base cache with key: \(baseKey)")
        
        // Try to fetch the base preview from cache.
        if let cachedBase = previewBaseCache.object(forKey: baseKey) {
            // print("   ✅ Found cached base preview (without overlay)")
            
            // Converti CIImage → NSImage
            guard let cgImage = encode_ctx.createCGImage(cachedBase, from: cachedBase.extent) else {
                // print("   ❌ Failed to create CGImage from cached CIImage")
                throw ProcessingError.imageConversionFailed
            }
            let sdrImage = NSImage(cgImage: cgImage, size: NSSize(width: cachedBase.extent.width, height: cachedBase.extent.height))
            
            return try await calculateHistogramFromSDRImage(sdrImage, ciImage: cachedBase)
        }
        
        // Cache miss: generate a full preview (this populates previewBaseCache).
        // print("   ⚠️ Base preview not in cache, generating...")
        let sdrImage = try await generatePreview(for: image)
        
        // The base preview should now be cached; try again.
        if let cachedBase = previewBaseCache.object(forKey: baseKey) {
            // print("   ✅ Base preview now cached after generation")
            
            guard let cgImage = encode_ctx.createCGImage(cachedBase, from: cachedBase.extent) else {
                throw ProcessingError.imageConversionFailed
            }
            let baseImage = NSImage(cgImage: cgImage, size: NSSize(width: cachedBase.extent.width, height: cachedBase.extent.height))
            
            return try await calculateHistogramFromSDRImage(baseImage, ciImage: cachedBase)
        }
        
        // Fallback: use the generated image (may include overlay, but better than nothing).
        // print("   ⚠️ Using generated image (may include overlay if enabled)")
        
        // We need a CIImage for the Metal path (convert from NSImage).
        guard let cgImage = sdrImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProcessingError.imageConversionFailed
        }
        let ciImage = CIImage(cgImage: cgImage)
        
        return try await calculateHistogramFromSDRImage(sdrImage, ciImage: ciImage)
    }
    
    /// Helper: compute histogram from an SDR NSImage.
    /// Use Metal when available; otherwise fall back to CPU.
    private func calculateHistogramFromSDRImage(
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
    
    // MARK: - Histogram Calculation
    
    // Histogram cache (key = URL + range fingerprint).
    
    
    
    // MARK: - Raw Data Structures
    
    /// Separate cache for raw pixel data (used for histograms).
    private static let rawDataCache = NSCache<NSURL, RawPixelData>()
    
    // MARK: - Public Cache Access
    
    /// Expose the raw-data cache for HDRImage.
    /// Allows HDRImage.loadMetadata() to reuse already-loaded data.
    func getCachedRawPixelData(url: URL) -> RawPixelData? {
        let key = url as NSURL
        return Self.rawDataCache.object(forKey: key)
    }
    
    // MARK: - HDR Loading with Raw Data Cache
    
    /// Load HDR once: read raw bytes from disk only once, then cache both the bytes and the CIImage.
    /// Throws ProcessingError.invalidColorSpace if the file isn't the expected HDR CS.
    private func loadHDR(url: URL) throws -> CIImage {
        let key = url as NSURL
        
        // CIImage cache hit?
        if let cached = hdrCache.object(forKey: key) {
            return cached
        }
        
        // If we don't have a cached CIImage, check whether raw bytes are cached.
        if let rawData = Self.rawDataCache.object(forKey: key) {
            // Raw bytes are cached: rebuild the CIImage without re-reading from disk.
            return try createCIImageFromRawData(rawData, key: key)
        }
        
        // No cache: read from disk (only once).
        // print("📂 Loading from disk: \(url.lastPathComponent)")
        
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
        
        // 2) Cache raw data (for fast histograms).
        let rawData = RawPixelData(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            componentsPerPixel: componentsPerPixel,
            isBigEndian: isBigEndian,
            bytes: bytes,
            cgImage: cgImage
        )
        
        let byteCost = dataLength / (1024 * 1024)  // MB
        Self.rawDataCache.totalCostLimit = 1024  // Max 1GB
        Self.rawDataCache.setObject(rawData, forKey: key, cost: byteCost)
        
        // 3) Create and cache a CIImage from raw data (no additional I/O).
        return try createCIImageFromRawData(rawData, key: key)
    }
    
    /// Helper: create a linear Display P3 CIImage from already-loaded RawPixelData.
    private func createCIImageFromRawData(_ rawData: RawPixelData, key: NSURL) throws -> CIImage {
        // Create a CIImage from the CGImage with HDR expansion.
        let fileCI = CIImage(cgImage: rawData.cgImage, options: [CIImageOption.expandToHDR: true])
        
        // Validate the color space.
        let name = cs_name(fileCI.colorSpace)
        guard name == hdr_required else {
            throw ProcessingError.invalidColorSpace(name)
        }
        
        // Materialize in linear P3
        guard let residentCG = ctx_linear_p3.createCGImage(
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
        hdrCache.totalCostLimit = 800
        hdrCache.setObject(residentCI, forKey: key, cost: mp)
        
        return residentCI
    }
    
    // MARK: - Histogram Generation
    
    /// Fetch raw pixel data from cache (for histogram calculation).
    private func getRawPixelData(url: URL) throws -> RawPixelData {
        let key = url as NSURL
        
        // It should always be cached after loadHDR, but handle edge cases.
        if let cached = Self.rawDataCache.object(forKey: key) {
            return cached
        }
        
        // Fallback: load now (triggers loadHDR and populates the cache).
        _ = try loadHDR(url: url)
        
        guard let cached = Self.rawDataCache.object(forKey: key) else {
            throw ProcessingError.cannotReadHDR
        }
        
        return cached
    }
    
    /// Computes histogram for the HDR input (with caching).
    /// Use Metal for a 10–50× speedup (when available).
    func histogramForHDRInput(url: URL) async throws -> HistogramCalculator.HistogramResult {
        
        let cacheKey = NSString(string: "\(url.absoluteString)|hdr")
        
        // print("📊 [histogramForHDRInput] Called for: \(url.lastPathComponent)")
        
        // Cache hit?
        if let cached = Self.HistogramCache.object(forKey: cacheKey) {
            // print("   ⚡ Cache HIT")
            return cached
        }
        
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
    
    
    // Histogram cache.
    private static let HistogramCache = NSCache<NSString, HistogramCalculator.HistogramResult>()
    
    
    
    
}
