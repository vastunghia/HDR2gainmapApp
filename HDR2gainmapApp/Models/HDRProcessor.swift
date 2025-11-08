import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Bridge tra il codice CLI e SwiftUI - gestisce il processing delle immagini HDR
@MainActor
class HDRProcessor {
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
    func generatePreview(for image: HDRImage) async throws -> NSImage {
        guard let hdr = CIImage(contentsOf: image.url, options: [.expandToHDR: true]) else {
            throw ProcessingError.cannotReadHDR
        }
        
        // Valida colorspace
        guard let hdr_cs = cs_name(hdr.colorSpace), hdr_cs == hdr_required else {
            throw ProcessingError.invalidColorSpace(cs_name(hdr.colorSpace))
        }
        
        // Calcola headroom
        let headroom = try await calculateHeadroom(hdr: hdr, settings: image.settings)
        
        // Tonemap SDR
        guard let sdr = tonemap_sdr(from: hdr, headroom_ratio: headroom) else {
            throw ProcessingError.tonemapFailed
        }
        
        // Opzionale: aggiungi overlay clipping
        let finalImage = image.settings.showClippedOverlay
            ? try await addClippingOverlay(hdr: hdr, sdr: sdr, headroom: headroom, color: image.settings.overlayColor)
            : sdr
        
        // Converti CIImage → NSImage per preview
        return try ciImageToNSImage(finalImage)
    }
    
    /// Esporta singola immagine come HEIC con gain map
    func exportImage(_ image: HDRImage, to outputURL: URL) async throws {
        guard let hdr = CIImage(contentsOf: image.url, options: [.expandToHDR: true]) else {
            throw ProcessingError.cannotReadHDR
        }
        
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
        
        try encode_ctx.writeHEIFRepresentation(of: sdr_with_props,
                                              to: outputURL,
                                              format: .RGB10,
                                              colorSpace: p3_cs,
                                              options: export_options)
    }
    
    // MARK: - Private Helpers
    
    private func calculateHeadroom(hdr: CIImage, settings: ProcessingSettings) async throws -> Float {
        switch settings.method {
        case .peakMax:
            guard let peak = max_luminance_hdr(from: hdr, context: ctx_linear_p3, linear_cs: linear_p3) else {
                throw ProcessingError.headroomCalculationFailed
            }
            return max(1.0, 1.0 + peak - powf(peak, settings.tonemapRatio))
            
        case .percentile:
            guard let headroom = percentile_headroom(from: hdr,
                                                     context: ctx_linear_p3,
                                                     linear_cs: linear_p3,
                                                     bins: 2048,
                                                     percentile: settings.percentile * 100) else {
                throw ProcessingError.headroomCalculationFailed
            }
            return headroom
        }
    }
    
    private func addClippingOverlay(hdr: CIImage, sdr: CIImage, headroom: Float, color: String) async throws -> CIImage {
        guard let mask = build_clip_mask_image_no_kernel(hdr: hdr, threshold_headroom: headroom) else {
            throw ProcessingError.clipMaskFailed
        }
        
        let solid = parse_color(color)
        
        guard let gen = CIFilter(name: "CIConstantColorGenerator") else {
            throw ProcessingError.clipMaskFailed
        }
        gen.setValue(solid, forKey: kCIInputColorKey)
        guard let color_infinite = gen.outputImage else {
            throw ProcessingError.clipMaskFailed
        }
        let color_img = color_infinite.cropped(to: sdr.extent)
        
        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw ProcessingError.clipMaskFailed
        }
        blend.setValue(color_img, forKey: kCIInputImageKey)
        blend.setValue(sdr, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        
        guard let overlaid = blend.outputImage else {
            throw ProcessingError.clipMaskFailed
        }
        
        return overlaid
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
