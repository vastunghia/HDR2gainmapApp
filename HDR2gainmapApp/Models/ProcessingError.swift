import Foundation

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
    case histogramCalculationFailed
    
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
        case .histogramCalculationFailed: return "Histogram calculation failed"
        }
    }
}
