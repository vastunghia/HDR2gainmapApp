import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// MARK: - ColorSpace Utilities

/// Human-readable color space name (fallback string).
func cs_name(_ cs: CGColorSpace?) -> String {
    guard let cs = cs else { return "nil" }
    if let name = cs.name as String? { return name }
    return "unknown"
}

// MARK: - Tone Mapping Utilities

/// General overload with explicit headroom controls.
func tonemap_sdr(from hdr: CIImage,
                 sourceHeadroom: Float,
                 targetHeadroom: Float) -> CIImage? {
    hdr.applyingFilter("CIToneMapHeadroom",
                       parameters: [
                        "inputSourceHeadroom": max(0, sourceHeadroom),
                        "inputTargetHeadroom": max(0, targetHeadroom)
                       ])
}

// MARK: - Luminance Utilities

/// Extracts linear luminance using Rec.709 coefficients (0.2126, 0.7152, 0.0722).
func linear_luma(_ src: CIImage) -> CIImage {
    let m = CIFilter.colorMatrix()
    m.inputImage = src
    m.rVector   = CIVector(x: 0.2126, y: 0,      z: 0,      w: 0)
    m.gVector   = CIVector(x: 0.7152, y: 0,      z: 0,      w: 0)
    m.bVector   = CIVector(x: 0.0722, y: 0,      z: 0,      w: 0)
    m.aVector   = CIVector(x: 0,      y: 0,      z: 0,      w: 1)
    m.biasVector = CIVector(x: 0,     y: 0,      z: 0,      w: 0)
    return m.outputImage!
}
