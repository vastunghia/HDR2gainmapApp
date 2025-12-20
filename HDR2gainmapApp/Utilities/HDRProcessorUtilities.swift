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

/// Legacy helper kept for compatibility (target headroom = 1.0).
func tonemap_sdr(from hdr: CIImage, headroom_ratio: Float) -> CIImage? {
    tonemap_sdr(from: hdr, sourceHeadroom: headroom_ratio, targetHeadroom: 1.0)
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

// MARK: - Apple MakerNote Metadata

/// Helper types for computing Apple MakerNote parameters from a relative headroom value.
struct MakerAppleResult {
    struct Candidate {
        let maker33: Float
        let maker48: Float
        // periphery:ignore
        let stops: Float
        // periphery:ignore
        let branch: String
    }
    // periphery:ignore
    let stops: Float
    // periphery:ignore
    let candidates: [Candidate]
    let `default`: Candidate?
}

/// Computes MakerApple metadata candidates from a relative headroom value (clamped to [1, 8]).
func maker_apple_from_headroom(_ headroom_linear: Float) -> MakerAppleResult {
    let clamped = min(max(headroom_linear, 1.0), 8.0)
    let stops = log2f(clamped)
    var cs: [MakerAppleResult.Candidate] = []
    
    do { let m48 = (1.8 - stops)/20.0;  if m48 >= 0,  m48 <= 0.01 { cs.append(.init(maker33: 0.0, maker48: m48, stops: stops, branch: "<1 & <=0.01")) } }
    do { let m48 = (1.601 - stops)/0.101; if m48 > 0.01, m48.isFinite { cs.append(.init(maker33: 0.0, maker48: m48, stops: stops, branch: "<1 & >0.01")) } }
    do { let m48 = (3.0 - stops)/70.0;   if m48 >= 0,  m48 <= 0.01 { cs.append(.init(maker33: 1.0, maker48: m48, stops: stops, branch: ">=1 & <=0.01")) } }
    do { let m48 = (2.303 - stops)/0.303; if m48 > 0.01, m48.isFinite { cs.append(.init(maker33: 1.0, maker48: m48, stops: stops, branch: ">=1 & >0.01")) } }
    
    let preferred = cs.first { $0.maker33 >= 1.0 && $0.maker48 <= 0.01 }
    ?? cs.first { $0.maker33 >= 1.0 }
    ?? cs.first
    return .init(stops: stops, candidates: cs, default: preferred)
}
