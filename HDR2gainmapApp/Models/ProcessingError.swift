import Foundation

enum ProcessingError: LocalizedError {
    case cannotReadHDR
    case invalidColorSpace(String?)
    case tonemapFailed
    case headroomCalculationFailed
    case gainMapGenerationFailed
    case gainMapExtractionFailed
    case clipMaskFailed
    case imageConversionFailed
    case histogramCalculationFailed
    case isoConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotReadHDR: return "Cannot read HDR image"
        case .invalidColorSpace(let cs): return "Invalid colorspace: \(cs ?? "nil")"
        case .tonemapFailed: return "Tonemapping failed"
        case .headroomCalculationFailed: return "Headroom calculation failed"
        case .gainMapGenerationFailed: return "Gain map generation failed"
        case .gainMapExtractionFailed: return "Gain map extraction failed"
        case .clipMaskFailed: return "Clip mask generation failed"
        case .imageConversionFailed: return "Image conversion failed"
        case .histogramCalculationFailed: return "Histogram calculation failed"
        case .isoConversionFailed(let msg): return "ISO conversion failed: \(msg)"
        }
    }
}
