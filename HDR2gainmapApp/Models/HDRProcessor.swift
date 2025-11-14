import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Bridge tra il codice CLI e SwiftUI - gestisce il processing delle immagini HDR
@MainActor
class HDRProcessor {
    
    private let hdrCache = NSCache<NSURL, CIImage>()

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
        if let name = cs_name(fileCI.colorSpace), name != hdr_required {
            throw ProcessingError.invalidColorSpace(cs_name(fileCI.colorSpace))
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


    /// Converts a hex string into a CIColor. Supports "#RRGGBB" and "#RRGGBBAA".
    /// Fallback is opaque red.
    private func ciColor(from string: String) -> CIColor {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }

        var v: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&v) else {
            return CIColor(red: 1, green: 0, blue: 0, alpha: 1)
        }

        switch hex.count {
        case 6: // RRGGBB
            let r = CGFloat((v & 0xFF0000) >> 16) / 255.0
            let g = CGFloat((v & 0x00FF00) >> 8)  / 255.0
            let b = CGFloat( v & 0x0000FF)        / 255.0
            return CIColor(red: r, green: g, blue: b, alpha: 1)

        case 8: // RRGGBBAA
            let r = CGFloat((v & 0xFF000000) >> 24) / 255.0
            let g = CGFloat((v & 0x00FF0000) >> 16) / 255.0
            let b = CGFloat((v & 0x0000FF00) >> 8)  / 255.0
            let a = CGFloat( v & 0x000000FF)        / 255.0
            return CIColor(red: r, green: g, blue: b, alpha: a)

        default:
            return CIColor(red: 1, green: 0, blue: 0, alpha: 1)
        }
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
    
    private init() {}
    
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
        
        let hdr = try loadHDR(url: image.url)

        let headroom = try await calculateHeadroom(hdr: hdr, settings: image.settings)

        guard var sdr = tonemap_sdr(from: hdr, headroom_ratio: headroom) else {
            throw ProcessingError.tonemapFailed
        }

        if image.settings.showClippedOverlay {
            // convert String → CIColor
            let ciOverlay = ciColor(from: image.settings.overlayColor)

            if let r = addClippingOverlayAndCount(
                hdr: hdr,
                sdr: sdr,
                headroom: headroom,
                overlayColor: ciOverlay,
                context: ctx_linear_p3
            ) {
                sdr = r.imageWithOverlay
                reportClipping?(r.clipped, r.total)
            } else {
                reportClipping?(0, 0)
            }
        } else {
            reportClipping?(0, 0)
        }

        return try ciImageToNSImage(sdr)
    }
    
    /// Esporta singola immagine come HEIC con gain map
    func exportImage(_ image: HDRImage, to outputURL: URL) async throws {
        
        let hdr = try loadHDR(url: image.url)
        
        // Calcola headroom
        let headroom = try await calculateHeadroom(hdr: hdr, settings: image.settings)
        
        // Tonemap SDR base
        guard let sdr_base = tonemap_sdr(from: hdr, headroom_ratio: headroom) else {
            throw ProcessingError.tonemapFailed
        }
        
        // Genera gain map (temp HEIC)
        let tmp_options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0,
            CIImageRepresentationOption.hdrImage: hdr,
            CIImageRepresentationOption.hdrGainMapAsRGB: false
        ]
        
        guard let tmp_data = encode_ctx.heifRepresentation(of: sdr_base,
                                                           format: .RGB10,
                                                           colorSpace: p3_cs,
                                                           options: tmp_options) else {
            throw ProcessingError.gainMapGenerationFailed
        }
        
        guard let gain_map = CIImage(data: tmp_data, options: [.auxiliaryHDRGainMap: true]) else {
            throw ProcessingError.gainMapExtractionFailed
        }
        
        // Aggiungi Maker Apple metadata
        let maker = maker_apple_from_headroom(headroom)
        guard let chosen = maker.default else {
            throw ProcessingError.makerAppleMetadataFailed
        }
        
        var props = hdr.properties
        var maker_apple = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        maker_apple["33"] = chosen.maker33
        maker_apple["48"] = chosen.maker48
        props[kCGImagePropertyMakerAppleDictionary as String] = maker_apple
        let sdr_with_props = sdr_base.settingProperties(props)
        
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
    
    // MARK: - Private Helpers
    
    // MARK: - Headroom

    private func calculateHeadroom(hdr: CIImage, settings: ProcessingSettings) async throws -> Float {
        switch settings.method {
        case .peakMax:
            // Peak calcolato sulla STESSA luminanza della mask (linear_luma),
            // così la soglia è coerente e non genera falsi positivi.
            let peak = peakLuminanceFromLinearLuma(hdr, context: ctx_linear_p3)
            // headroom = max(1.0, 1.0 + peak - peak^ratio)
            // ratio = 0  -> headroom = max(1, peak)  -> 0 clip
            // ratio = 1  -> headroom = 1             -> clip sopra SDR
            return max(1.0, 1.0 + peak - powf(peak, settings.tonemapRatio))

        case .percentile:
            guard let headroom = percentile_headroom(from: hdr,
                                                     context: ctx_linear_p3,
                                                     linear_cs: linear_p3,
                                                     bins: 2048,
                                                     percentile: settings.percentile * 100)
            else {
                throw ProcessingError.headroomCalculationFailed
            }
            return headroom
        }
    }

    /// Peak = massimo assoluto della luminanza lineare (stessa usata per la clip-mask).
    /// Usa CIAreaMaximum su linear_luma(hdr) e legge il canale R.
    private func peakLuminanceFromLinearLuma(_ hdr: CIImage, context: CIContext) -> Float {
        let y = linear_luma(hdr) // tua funzione esistente: Y lineare in R
        // CIAreaMaximum -> immagine 1x1 RGBAf col massimo per canale
        let extent = y.extent
        let filter = CIFilter(name: "CIAreaMaximum",
                              parameters: [kCIInputImageKey: y,
                                           kCIInputExtentKey: CIVector(cgRect: extent)])!
        let maxImg = filter.outputImage!

        var pixel = [Float](repeating: 0, count: 4)
        context.render(maxImg,
                       toBitmap: &pixel,
                       rowBytes: MemoryLayout<Float>.size * 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)
        // pixel[0] = massimo della Y (canale R)
        let peak = pixel[0]
        // Evita valori sub-unitari negativi/NaN per sicurezza
        if !peak.isFinite { return 1.0 }
        return max(peak, 0)
    }
    
//    // Vecchia API (se vuoi mantenerla per altri punti del codice)
//    func addClippingOverlay(
//        hdr: CIImage,
//        threshold_headroom: Float,
//        overlayColor: CIColor,
//        context: CIContext
//    ) -> CIImage? {
//        addClippingOverlayAndCount(hdr: hdr,
//                                   threshold_headroom: threshold_headroom,
//                                   overlayColor: overlayColor,
//                                   context: context)?.imageWithOverlay
//    }
    
    // MARK: - Overlay + count (nuovo)

    /// Build the clipping overlay over the SDR image and also return (clipped,total) at full-res.
    func addClippingOverlayAndCount(
        hdr: CIImage,
        sdr: CIImage,
        headroom: Float,
        overlayColor: CIColor,
        context: CIContext
    ) -> (imageWithOverlay: CIImage, clipped: Int, total: Int)? {

        // 1) Binary mask (R channel 0/1) at HDR/native size
        guard let binary = build_clip_binary_mask(hdr: hdr, threshold_headroom: headroom) else { return nil }
        let w = Int(binary.extent.width.rounded())
        let h = Int(binary.extent.height.rounded())
        guard w > 0, h > 0 else { return nil }

        // 2) Count clipped pixels by examining R channel (NOT alpha)
//        let clipped = countNonZeroR_inRGBA8(binary, width: w, height: h, context: context)
//        let total = w * h
        let (clipped, total) = clippedCountViaAreaAverage(binaryMaskR: binary, context: ctx_linear_p3)

        // 3) Sposta la binaria nel canale ALPHA: A = R, e azzera RGB (CIBlendWithAlphaMask guarda l'alpha)
        let toAlpha = CIFilter.colorMatrix()
        toAlpha.inputImage = binary
        toAlpha.rVector = CIVector(x: 0, y: 0, z: 0, w: 0) // out R = 0
        toAlpha.gVector = CIVector(x: 0, y: 0, z: 0, w: 0) // out G = 0
        toAlpha.bVector = CIVector(x: 0, y: 0, z: 0, w: 0) // out B = 0
        toAlpha.aVector = CIVector(x: 1, y: 0, z: 0, w: 0) // out A = in R
        guard let alphaMask = toAlpha.outputImage else { return nil }

        // 4) Tint + compositing controllato dal canale alpha della mask
        let tint = CIImage(color: overlayColor).cropped(to: sdr.extent)
        guard let composited = CIFilter(name: "CIBlendWithAlphaMask",
                                        parameters: [
                                          kCIInputImageKey: tint,
                                          kCIInputBackgroundImageKey: sdr,
                                          kCIInputMaskImageKey: alphaMask
                                        ])?.outputImage else { return nil }

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
    
//    /// Conta i pixel clippati sull'immagine **alla risoluzione nativa** (quella d'export),
//    /// usando le stesse impostazioni/tonemap della preview/export.
//    /// Ritorna (clipped, total) oppure nil in caso di problemi.
//    func computeClippingStatsFullRes(for image: HDRImage) async -> (clipped: Int, total: Int)? {
//        guard let hdr = CIImage(contentsOf: image.url, options: [.expandToHDR: true]) else { return nil }
//
//        let headroom: Float
//        do {
//            headroom = try await calculateHeadroom(hdr: hdr, settings: image.settings)
//        } catch {
//            return nil
//        }
//
//        guard let mask = build_clip_mask_image_no_kernel(hdr: hdr, threshold_headroom: headroom) else {
//            return nil
//        }
//
//        let w = Int(mask.extent.width.rounded())
//        let h = Int(mask.extent.height.rounded())
//        guard w > 0, h > 0 else { return nil }
//
//        // ⬇️ Usa il conteggio su RGBA8 (non A8)
//        let clipped = countNonZeroPixelsRGBA8(mask, width: w, height: h, context: ctx_linear_p3)
//        let total = w * h
//        return (clipped, total)
//    }

    /// Renderizza la mask in RGBA8 e conta i pixel con canale R > 0.
    /// (Per mask mono, R=G=B; l'alpha della mask è tipicamente 255 ovunque.)
    private func countNonZeroPixelsRGBA8(_ image: CIImage, width: Int, height: Int, context: CIContext) -> Int {
        let rowBytes = width * 4
        var buffer = [UInt8](repeating: 0, count: rowBytes * height)

        context.render(
            image,
            toBitmap: &buffer,
            rowBytes: rowBytes,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        var count = 0
        var i = 0
        // RGBA8 → [R,G,B,A] per pixel
        for _ in 0..<height {
            for _ in 0..<width {
                let r = buffer[i]
                if r > 0 { count += 1 }    // oppure: if r >= 128 { … } per soglia dura
                i += 4
            }
        }
        return count
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
