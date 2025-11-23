import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Bridge tra il codice CLI e SwiftUI - gestisce il processing delle immagini HDR
@MainActor
class HDRProcessor {
    
    private let hdrCache = NSCache<NSURL, CIImage>()
    
    // Cache short-term delle preview (chiave = URL + fingerprint settings)
    private let previewBaseCache = NSCache<NSString, CIImage>()
    private let previewOverlayCache = NSCache<NSString, CIImage>()
    private let previewCountsCache = NSCache<NSString, NSDictionary>() // ["c": Int, "t": Int]

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

    /// Load HDR once, validate source colorspace, then materialize into a RAM-backed CIImage.
    /// Throws ProcessingError.invalidColorSpace if the file isn't the expected HDR CS.
    private func loadHDR(url: URL) throws -> CIImage {
        let key = url as NSURL
        if let cached = hdrCache.object(forKey: key) {
            return cached
        }

        // 1) Open file-backed CIImage (no conversion yet)
        guard let fileCI = CIImage(contentsOf: url, options: [.expandToHDR: true]) else {
            throw ProcessingError.cannotReadHDR
        }

        // 2) VALIDATE source colorspace BEFORE we convert it to linear
        let name = cs_name(fileCI.colorSpace)
        guard name == hdr_required else {
            throw ProcessingError.invalidColorSpace(name) // passa il nome reale per un messaggio utile
        }

        // 3) Materialize into a RAM-backed CGImage (float, linear P3)
        guard let residentCG = ctx_linear_p3.createCGImage(
            fileCI,
            from: fileCI.extent,
            format: .RGBAf,
            colorSpace: linear_p3
        ) else {
            throw ProcessingError.cannotReadHDR
        }

        let residentCI = CIImage(cgImage: residentCG, options: nil)

        // 4) Cache with a cost (MP) budget
        let mp = Int(fileCI.extent.width * fileCI.extent.height / 1_000_000)
        hdrCache.totalCostLimit = 800 // tune in base alla RAM
        hdrCache.setObject(residentCI, forKey: key, cost: mp)

        return residentCI
    }
    
    static let shared = HDRProcessor()
    
    private let linear_p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private let p3_cs = CGColorSpace(name: CGColorSpace.displayP3)!
    private let hdr_required = CGColorSpace.displayP3_PQ as String
    
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
    
    /// Genera preview tonemappata per un'immagine HDR
    // Mantieni la tua versione "vecchia":
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
        let derivedHeadroom: Float = try await calculateHeadroom(hdr: hdr, settings: image.settings)

        let sdrBase: CIImage
        switch image.settings.method {
        case .peakMax, .percentile:
            guard let s = tonemap_sdr(from: hdr, headroom_ratio: derivedHeadroom) else {
                throw ProcessingError.tonemapFailed
            }
            sdrBase = s

        case .direct:
            let real = peakLuminanceFromLinearLuma(hdr, context: ctx_linear_p3)
            let maxLimit = max(1.0, real * 2.0)
            let sH = min(max(image.settings.directSourceHeadroom ?? real, 0), maxLimit)
            let tH = min(max(image.settings.directTargetHeadroom ?? 1.0, 0), maxLimit)
            guard let s = tonemap_sdr(from: hdr, sourceHeadroom: sH, targetHeadroom: tH) else {
                throw ProcessingError.tonemapFailed
            }
            sdrBase = s
        }

        previewBaseCache.setObject(sdrBase, forKey: baseKey)

        // 4) Se non serve overlay, ritorna
        if !wantOverlay {
            reportClipping?(0, 0)
            return try ciImageToNSImage(sdrBase)
        }

        // 5) Serve overlay → costruiscilo dalla base
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
    func exportImage(_ image: HDRImage, to outputURL: URL) async throws {
        
        let hdr = try loadHDR(url: image.url)
        
        // Calcola headroom
        let derivedHeadroom: Float = try await calculateHeadroom(hdr: hdr, settings: image.settings)

        // Tonemap SDR base
        var sdr: CIImage?
        switch image.settings.method {
        case .peakMax, .percentile:
            sdr = tonemap_sdr(from: hdr, headroom_ratio: derivedHeadroom)

        case .direct:
            // misura headroom reale per default/limiti
            let real = peakLuminanceFromLinearLuma(hdr, context: ctx_linear_p3)
            let maxLimit = max(1.0, real * 2.0)

            // prendi i valori impostati dall’utente, con fallback ragionevoli
            let sH = min(max(image.settings.directSourceHeadroom ?? real, 0), maxLimit)
            let tH = min(max(image.settings.directTargetHeadroom ?? 1.0, 0), maxLimit)

            sdr = tonemap_sdr(from: hdr, sourceHeadroom: sH, targetHeadroom: tH)
        }

        guard let sdrBase = sdr else {
            throw ProcessingError.tonemapFailed
        }
        
        let sdrFinal = sdrBase
        
        // Genera gain map (temp HEIC)
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
        
        // Aggiungi Maker Apple metadata
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
        
        // Export finale
        let export_options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: image.settings.heicQuality,
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
    
    // MARK: - Headroom

    /// Peak = massimo assoluto della luminanza lineare (stessa usata per la clip-mask).
    /// Usa CIAreaMaximum su linear_luma(hdr) e legge il canale R.
    // Peak dalla stessa luminanza lineare usata per la curva
    private func peakLuminanceFromLinearLuma(_ hdr: CIImage, context: CIContext) -> Float {
        let y = linear_luma(hdr)
        let f = CIFilter(name: "CIAreaMaximum",
                         parameters: [kCIInputImageKey: y,
                                      kCIInputExtentKey: CIVector(cgRect: y.extent)])!
        let out = f.outputImage!
        var px = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &px,
                       rowBytes: MemoryLayout<Float>.size * 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return px[0].isFinite ? max(px[0], 0) : 1.0
    }

    private func calculateHeadroom(hdr: CIImage, settings: ProcessingSettings) async throws -> Float {
        switch settings.method {
        case .peakMax:
            let peak = peakLuminanceFromLinearLuma(hdr, context: ctx_linear_p3)
            return max(1.0, 1.0 + peak - powf(peak, settings.tonemapRatio))

        case .percentile:
            let pShown = settings.percentile // se la vedi qui, stai passando il valore giusto
            guard let headroom = percentileHeadroomFromLinearLuma(
                hdr, bins: 2048, percentile01: Double(settings.percentile), context: ctx_linear_p3
            ) else {
                throw ProcessingError.headroomCalculationFailed
            }
            print("🔎 Percentile=\(pShown) → headroom=\(headroom)")
            return headroom

        case .direct:
            // Non usato per il tonemap (si usa l’overload con source/target),
            // ma restituiamo un valore sensato per chiamanti generici: il "source headroom" risolto.
            let real = peakLuminanceFromLinearLuma(hdr, context: ctx_linear_p3)
            return real
        }
    }
    
    // Calcola l'headroom come il valore di Y (lineare) al percentile p∈[0,1]
    func percentileHeadroomFromLinearLuma(
        _ hdr: CIImage,
        bins: Int,
        percentile01 p: Double,
        context: CIContext
    ) -> Float? {
        // 1) Luma lineare
        let y = linear_luma(hdr)

        // 2) Picco Y reale per normalizzare l’istogramma in [0,1]
        let peak = peakLuminanceFromLinearLuma(hdr, context: context)
        guard peak.isFinite, peak > 0 else { return 1.0 }

        // 3) yNorm = Y / peak  (∈ [0,1])
        let scale = CIFilter.colorMatrix()
        scale.inputImage = y
        scale.rVector   = CIVector(x: 1.0/CGFloat(peak), y: 0, z: 0, w: 0)
        scale.gVector   = CIVector(x: 0, y: 0, z: 0, w: 0)
        scale.bVector   = CIVector(x: 0, y: 0, z: 0, w: 0)
        scale.aVector   = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let yNorm = scale.outputImage else { return nil }

        // 4) Istogramma su yNorm (canale R), con conteggi in *float*
        let count = max(1, min(bins, 4096))
        let hist = CIFilter(name: "CIAreaHistogram", parameters: [
            kCIInputImageKey: yNorm,
            "inputCount": count,
            // 'inputScale': 1.0 → i valori del buffer sono frazioni che sommano a 1.0
            "inputScale": 1.0,
            kCIInputExtentKey: CIVector(cgRect: yNorm.extent)
        ])!
        guard let out = hist.outputImage else { return nil }

        var buf = [Float](repeating: 0, count: count * 4)
        context.render(out,
                       toBitmap: &buf,
                       rowBytes: count * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: count, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)

        // 5) Somma e cumulata in *double*, senza cast a Int
        var total = 0.0
        for b in 0..<count { total += Double(buf[b*4 + 0]) }  // solo canale R
        guard total > 0 else { return 1.0 }

        let target = min(max(p, 0.0), 1.0) * total
        var acc = 0.0
        var idx = count - 1
        for b in 0..<count {
            acc += Double(buf[b*4 + 0])
            if acc >= target { idx = b; break }
        }

        // 6) Soglia normalizzata → headroom in unità “Y reale”
        let thresholdNorm = Double(idx + 1) / Double(count)   // (0..1]
        let headroom = Float(thresholdNorm) * peak
        return headroom.isFinite ? headroom : 1.0
    }

    @MainActor
    func computeMeasuredHeadroomRaw(url: URL) throws -> Float {
        let hdr = try loadHDR(url: url)
        let peak = peakLuminanceFromLinearLuma(hdr, context: ctx_linear_p3)
        return peak.isFinite ? peak : 1.0
    }
    
    // MARK: - Overlay + count

    /// Overlay multicolore dei pixel clippati su SDR (maxRGB > 1):
    /// - rosso/verde/blu: clip solo di R / G / B
    /// - giallo/magenta/ciano: clip di 2 canali
    /// - **dim** (metà luminanza) per i casi sopra quando **Y ≥ 1** ma non RGB
    /// - **nero** quando **tutti e tre** i canali sono clippati (R&G&B > 1)
    func addColorizedClippingOverlayAndCount(
        sdr: CIImage,
        context: CIContext
    ) -> (imageWithOverlay: CIImage, clipped: Int, total: Int)? {

        // --- Helpers -----------------------------------------------------------
        func extractChannel(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
            // porta sempre il canale selezionato nel canale R dell’output (mono in R)
            let m = CIFilter.colorMatrix()
            m.inputImage = img
            if r == 1 {
                m.rVector = CIVector(x: 1, y: 0, z: 0, w: 0) // usa R → R
            } else if g == 1 {
                m.rVector = CIVector(x: 0, y: 1, z: 0, w: 0) // usa G → R
            } else {
                m.rVector = CIVector(x: 0, y: 0, z: 1, w: 0) // usa B → R
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

        // --- 1) Maschere per canale (soglia 1.0 + epsilon opzionale) ---------
        let eps: CGFloat = 1e-6
        let thr: CGFloat = 1.0 + eps

        let rMono = extractChannel(sdr, r: 1, g: 0, b: 0)
        let gMono = extractChannel(sdr, r: 0, g: 1, b: 0)
        let bMono = extractChannel(sdr, r: 0, g: 0, b: 1)

        let rMask = thresh01(rMono, threshold: thr)
        let gMask = thresh01(gMono, threshold: thr)
        let bMask = thresh01(bMono, threshold: thr)

        // --- 2) Maschera Y (luminanza) su SDR -------------------------------
        let yMono = linear_luma(sdr)                 // usa la tua funzione top-level
        let yMask = thresh01(yMono, threshold: thr)  // 1 dove Y ≥ 1 (±eps)

        // --- 3) Categorie esclusive per canali ------------------------------
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
        
        // --- DEBUG LOG: percentuali per categoria --------------------------------
        do {
            // Helper: frazione (0..1) dalla mask binaria (R=mask), via CIAreaAverage
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

        // nero per RGB (ultimo, sopra tutti)
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
}

// MARK: - Errors

enum ProcessingError: LocalizedError {
    case cannotReadHDR
    case invalidColorSpace(String?)
    case tonemapFailed
    case headroomCalculationFailed
    case gainMapGenerationFailed
    case gainMapExtractionFailed
    case makerAppleMetadataFailed
    case clipMaskFailed
    case imageConversionFailed
    
    var errorDescription: String? {
        switch self {
        case .cannotReadHDR: return "Cannot read HDR image"
        case .invalidColorSpace(let cs): return "Invalid colorspace: \(cs ?? "nil")"
        case .tonemapFailed: return "Tonemapping failed"
        case .headroomCalculationFailed: return "Headroom calculation failed"
        case .gainMapGenerationFailed: return "Gain map generation failed"
        case .gainMapExtractionFailed: return "Gain map extraction failed"
        case .makerAppleMetadataFailed: return "Maker Apple metadata generation failed"
        case .clipMaskFailed: return "Clip mask generation failed"
        case .imageConversionFailed: return "Image conversion failed"
        }
    }
}
