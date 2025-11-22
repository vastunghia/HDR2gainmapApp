import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// MARK: - ColorSpace Utilities

//// Nome "umano" del color space (o stringa fallback)
func cs_name(_ cs: CGColorSpace?) -> String {
    guard let cs = cs else { return "nil" }
    if let name = cs.name as String? { return name }
    return "unknown"
}

// MARK: - Tonemap Utilities

// Overload generico: controlli espliciti
func tonemap_sdr(from hdr: CIImage,
                 sourceHeadroom: Float,
                 targetHeadroom: Float) -> CIImage? {
    hdr.applyingFilter("CIToneMapHeadroom",
                       parameters: [
                         "inputSourceHeadroom": max(0, sourceHeadroom),
                         "inputTargetHeadroom": max(0, targetHeadroom)
                       ])
}

// Mantieni il vecchio helper per compatibilità: target = 1.0
func tonemap_sdr(from hdr: CIImage, headroom_ratio: Float) -> CIImage? {
    tonemap_sdr(from: hdr, sourceHeadroom: headroom_ratio, targetHeadroom: 1.0)
}

// MARK: - Color Utilities

//func parse_color(_ s: String) -> CIColor {
//    let lower = s.lowercased()
//    switch lower {
//    case "red":     return CIColor(red: 1, green: 0, blue: 0)
//    case "magenta": return CIColor(red: 1, green: 0, blue: 1)
//    case "violet":  return CIColor(red: 0.56, green: 0, blue: 1)
//    default:
//        if lower.hasPrefix("#"), lower.count == 7 {
//            let r_str = String(lower.dropFirst().prefix(2))
//            let g_str = String(lower.dropFirst(3).prefix(2))
//            let b_str = String(lower.dropFirst(5).prefix(2))
//            let r = CGFloat(Int(r_str, radix: 16) ?? 255) / 255.0
//            let g = CGFloat(Int(g_str, radix: 16) ?? 0)   / 255.0
//            let b = CGFloat(Int(b_str, radix: 16) ?? 255) / 255.0
//            return CIColor(red: r, green: g, blue: b)
//        }
//        return CIColor(red: 1, green: 0, blue: 1)
//    }
//}

// MARK: - Luminance Utilities

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

//func max_luminance_hdr(from ci_image: CIImage,
//                       context: CIContext,
//                       linear_cs: CGColorSpace) -> Float? {
//    let y_img = linear_luma(ci_image)
//    let filter = CIFilter.areaMaximum()
//    filter.inputImage = y_img
//    filter.extent = y_img.extent
//    guard let out = filter.outputImage else { return nil }
//
//    var px = [Float](repeating: 0, count: 4)
//    context.render(out,
//                   toBitmap: &px,
//                   rowBytes: MemoryLayout<Float>.size * 4,
//                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
//                   format: .RGBAf,
//                   colorSpace: linear_cs)
//    let y_peak = max(0, px[0])
//    return y_peak
//}

/// Peak = massimo assoluto della Y lineare (stessa Y usata nella mask)
//func peak_luminance_from_linear_luma(_ hdr: CIImage, context: CIContext) -> Float {
//    let y = linear_luma(hdr) // la tua funzione attuale
//    // CIAreaMaximum restituisce un'immagine 1x1 RGBAf con il massimo per canale
//    let extent = y.extent
//    let maxImg = CIFilter(name: "CIAreaMaximum",
//                          parameters: [kCIInputImageKey: y,
//                                       kCIInputExtentKey: CIVector(cgRect: extent)])!.outputImage!
//    var pixel = [Float](repeating: 0, count: 4)
//    context.render(maxImg,
//                   toBitmap: &pixel,
//                   rowBytes: MemoryLayout<Float>.size * 4,
//                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
//                   format: .RGBAf,
//                   colorSpace: nil)
//    return pixel[0] // R = Y
//}

/// Mono image = max(R,G,B) in canale R (CIMaximumComponent), usata per la mask su SDR.
//func monoMaxRGB(from src: CIImage) -> CIImage {
//    CIFilter(name: "CIMaximumComponent", parameters: [kCIInputImageKey: src])!.outputImage!
//}

// Peak metric-aware: massimo della luminanza (Y) oppure del maxRGB (CIMaximumComponent)
//func peakForMetric(_ hdr: CIImage, metric: ClippingMetricChoice, context: CIContext) -> Float {
//    let mono: CIImage = {
//        switch metric {
//        case .luminance:  return linear_luma(hdr)
//        case .anyChannel: return CIFilter(name: "CIMaximumComponent",
//                                          parameters: [kCIInputImageKey: hdr])!.outputImage!
//        }
//    }()
//    let extent = mono.extent
//    let f = CIFilter(name: "CIAreaMaximum",
//                     parameters: [kCIInputImageKey: mono,
//                                  kCIInputExtentKey: CIVector(cgRect: extent)])!
//    let out = f.outputImage!
//
//    var px = [Float](repeating: 0, count: 4)
//    context.render(out,
//                   toBitmap: &px,
//                   rowBytes: MemoryLayout<Float>.size * 4,
//                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
//                   format: .RGBAf,
//                   colorSpace: nil)
//    let peak = px[0]
//    return peak.isFinite ? max(peak, 0) : 1.0
//}

// Percentile metric-aware: restituisce headroom alla soglia del percentile su Y o su maxRGB
//func percentileHeadroomForMetric(
//    _ hdr: CIImage,
//    metric: ClippingMetricChoice,
//    bins: Int,
//    percentile01 p: Double,
//    context: CIContext
//) -> Float? {
//    let mono: CIImage = {
//        switch metric {
//        case .luminance:  return linear_luma(hdr)
//        case .anyChannel: return CIFilter(name: "CIMaximumComponent",
//                                          parameters: [kCIInputImageKey: hdr])!.outputImage!
//        }
//    }()
//
//    let peak = peakForMetric(hdr, metric: metric, context: context)
//    let norm = max(peak, 1e-9)
//
//    // normalizza a [0,1] il canale R della mono
//    let scale = CIFilter(name: "CIColorMatrix")!
//    scale.setValue(mono, forKey: kCIInputImageKey)
//    scale.setValue(CIVector(x: 1.0/CGFloat(norm), y: 0, z: 0, w: 0), forKey: "inputRVector")
//    scale.setValue(CIVector(x: 0, y: 0, z: 0, w: 0),                   forKey: "inputGVector")
//    scale.setValue(CIVector(x: 0, y: 0, z: 0, w: 0),                   forKey: "inputBVector")
//    scale.setValue(CIVector(x: 0, y: 0, z: 0, w: 1),                   forKey: "inputAVector")
//    guard let monoNorm = scale.outputImage else { return nil }
//
//    // istogramma area su R
//    let count = max(1, min(bins, 4096))
//    let hist = CIFilter(name: "CIAreaHistogram",
//                        parameters: [kCIInputImageKey: monoNorm,
//                                     "inputCount": count,
//                                     kCIInputExtentKey: CIVector(cgRect: monoNorm.extent),
//                                     "inputScale": 1.0])!
//    guard let out = hist.outputImage else { return nil }
//
//    var buf = [Float](repeating: 0, count: count * 4)
//    context.render(out,
//                   toBitmap: &buf,
//                   rowBytes: count * 4 * MemoryLayout<Float>.size,
//                   bounds: CGRect(x: 0, y: 0, width: count, height: 1),
//                   format: .RGBAf,
//                   colorSpace: nil)
//
//    var cdf = 0.0
//    let target = max(0.0, min(1.0, p)) // p in [0,1]
//    let threshCount = target * buf.enumerated().reduce(0.0) { $0 + Double(max(0, Int($1.element))) } // solo R
//    var acc = 0.0
//    var idx = 0
//    for b in 0..<count {
//        acc += Double(max(0, Int(buf[b*4 + 0])))
//        if acc >= threshCount { idx = b; break }
//    }
//
//    // bordo superiore del bin
//    let thresholdNorm = Float(Double(idx + 1) / Double(count))
//    let headroom = thresholdNorm * peak
//    return headroom.isFinite ? max(headroom, 1.0) : 1.0
//}

//func percentile_headroom(from ci_image: CIImage,
//                         context: CIContext,
//                         linear_cs: CGColorSpace,
//                         bins: Int = 1024,
//                         percentile: Float = 99.9) -> Float? {
//    let bin_count = min(max(bins, 1), 2048)
//
//    guard let abs_max = max_luminance_hdr(from: ci_image, context: context, linear_cs: linear_cs),
//          abs_max > 0 else { return 1.0 }
//
//    var y_img = linear_luma(ci_image)
//
//    let norm = CIFilter.colorMatrix()
//    norm.inputImage = y_img
//    let s = CGFloat(1.0) / CGFloat(abs_max)
//    norm.rVector   = CIVector(x: s, y: .zero, z: .zero, w: .zero)
//    norm.gVector   = CIVector(x: .zero, y: 1.0,  z: .zero, w: .zero)
//    norm.bVector   = CIVector(x: .zero, y: .zero, z: 1.0,  w: .zero)
//    norm.aVector   = CIVector(x: .zero, y: .zero, z: .zero, w: 1.0)
//    norm.biasVector = CIVector(x: .zero, y: .zero, z: .zero, w: .zero)
//    y_img = norm.outputImage!
//
//    let hist = CIFilter.areaHistogram()
//    hist.inputImage = y_img
//    hist.extent = y_img.extent
//    hist.count = bin_count
//    hist.scale = 1.0
//
//    guard let hist_image = hist.outputImage else { return nil }
//
//    var buf = [Float](repeating: 0, count: bin_count * 4)
//    context.render(hist_image,
//                   toBitmap: &buf,
//                   rowBytes: MemoryLayout<Float>.size * 4 * bin_count,
//                   bounds: CGRect(x: 0, y: 0, width: bin_count, height: 1),
//                   format: .RGBAf,
//                   colorSpace: linear_cs)
//
//    var cdf = [Double](repeating: 0, count: bin_count)
//    var total: Double = 0
//    for i in 0..<bin_count {
//        let c = Double(max(0, buf[i*4 + 0]))
//        total += c
//        cdf[i] = total
//    }
//    guard total > 0 else { return 1.0 }
//
//    var k = 0
//    let target = Double(percentile) / 100.0 * total
//    while k < bin_count && cdf[k] < target { k += 1 }
//    if k >= bin_count { k = bin_count - 1 }
//
//    let v_norm = (Double(k) + 0.5) / Double(bin_count)
//    let y_percentile = Float(v_norm) * abs_max
//
//    return max(y_percentile, 1.0)
//}

//func pixel_count(of img: CIImage) -> Double {
//    let props = img.properties
//    if let w = props[kCGImagePropertyPixelWidth as String] as? Int,
//       let h = props[kCGImagePropertyPixelHeight as String] as? Int,
//       w > 0, h > 0 {
//        return Double(w * h)
//    }
//    let w = max(0, Int(img.extent.width.rounded()))
//    let h = max(0, Int(img.extent.height.rounded()))
//    return Double(w * h)
//}

/// Misura il peak della luminanza (headroom reale) OFF-MAIN, senza usare HDRProcessor.shared
//func computeMeasuredHeadroomOffMain(url: URL) throws -> Float {
//    // Spazi colore locali
//    let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
//    // Se nel tuo progetto hai una costante "hdr_required" usa quella; altrimenti metti il nome atteso
//    let hdrRequiredName = "Display P3 (PQ)" // adatta se usi una stringa diversa nel check
//
//    // Context locale
//    let ctx = CIContext(options: [
//        .workingColorSpace: linearP3,
//        .outputColorSpace:  linearP3
//    ])
//
//    // 1) Carica file HDR
//    guard let fileCI = CIImage(contentsOf: url, options: [.expandToHDR: true]) else {
//        throw ProcessingError.cannotReadHDR
//    }
//
//    // 2) Valida il colorspace sorgente (stesso criterio che usi in loadHDR)
//    let srcName = cs_name(fileCI.colorSpace)
//    if srcName != hdrRequiredName {
//        throw ProcessingError.invalidColorSpace(srcName)
//    }
//
//    // 3) Materializza in RAM come float linear P3
//    guard let residentCG = ctx.createCGImage(fileCI, from: fileCI.extent, format: .RGBAf, colorSpace: linearP3) else {
//        throw ProcessingError.cannotReadHDR
//    }
//    let residentCI = CIImage(cgImage: residentCG)
//
//    // 4) Luma lineare e massimo via CIAreaMaximum
//    let y = linear_luma(residentCI)
//    let f = CIFilter(name: "CIAreaMaximum",
//                     parameters: [kCIInputImageKey: y,
//                                  kCIInputExtentKey: CIVector(cgRect: y.extent)])!
//    let out = f.outputImage!
//
//    var px = [Float](repeating: 0, count: 4)
//    ctx.render(out,
//               toBitmap: &px,
//               rowBytes: MemoryLayout<Float>.size * 4,
//               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
//               format: .RGBAf,
//               colorSpace: nil)
//
//    let peak = px[0]
//    return max(1.0, peak.isFinite ? peak : 1.0)
//}

// MARK: - Clip Mask Utilities

/// Costruisce una mask binaria (0/1 nel canale R) da un'immagine mono nel canale R.
/// Confronto: R > (threshold + epsilon)
//func build_clip_binary_mask(from monoR: CIImage,
//                                    threshold: Float,
//                                    epsilon: Float = 0) -> CIImage? {
//    // (monoR - (threshold+eps))
//    let sub = CIFilter.colorMatrix()
//    sub.inputImage = monoR
//    sub.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
//    sub.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
//    sub.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
//    sub.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
//    sub.biasVector = CIVector(x: CGFloat(-(threshold + epsilon)), y: 0, z: 0, w: 0)
//    var x = sub.outputImage!
//
//    // clamp negativi, amplifica e riclampa a [0,1] -> binaria
//    let clampPos = CIFilter.colorClamp(); clampPos.inputImage = x
//    clampPos.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
//    clampPos.maxComponents = CIVector(x: 1e9, y: 0, z: 0, w: 1)
//    x = clampPos.outputImage!
//
//    let amp = CIFilter.colorMatrix(); amp.inputImage = x
//    amp.rVector = CIVector(x: 1_000_000, y: 0, z: 0, w: 0)
//    amp.gVector = CIVector(x: 0,         y: 0, z: 0, w: 0)
//    amp.bVector = CIVector(x: 0,         y: 0, z: 0, w: 0)
//    amp.aVector = CIVector(x: 0,         y: 0, z: 0, w: 1)
//    x = amp.outputImage!
//
//    let clamp01 = CIFilter.colorClamp(); clamp01.inputImage = x
//    clamp01.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
//    clamp01.maxComponents = CIVector(x: 1, y: 0, z: 0, w: 1)
//    return clamp01.outputImage
//}

//// 0) Fattorizza: costruisce la MASK BINARIA (valore nel canale R: 0 o 1) senza colorizzarla.
//func build_clip_binary_mask(hdr: CIImage, threshold_headroom: Float) -> CIImage? {
//    var y_img = linear_luma(hdr)
//
//    let sub = CIFilter.colorMatrix()
//    sub.inputImage = y_img
//    sub.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
//    sub.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
//    sub.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
//    sub.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
//    sub.biasVector = CIVector(x: CGFloat(-threshold_headroom), y: 0, z: 0, w: 0)
//    y_img = sub.outputImage!
//
//    let clamp_pos = CIFilter.colorClamp()
//    clamp_pos.inputImage = y_img
//    clamp_pos.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
//    clamp_pos.maxComponents = CIVector(x: 1e9, y: 0, z: 0, w: 1)
//    y_img = clamp_pos.outputImage!
//
//    let gain: CGFloat = 1_000_000
//    let amp = CIFilter.colorMatrix()
//    amp.inputImage = y_img
//    amp.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
//    amp.gVector = CIVector(x: 0,    y: 0, z: 0, w: 0)
//    amp.bVector = CIVector(x: 0,    y: 0, z: 0, w: 0)
//    amp.aVector = CIVector(x: 0,    y: 0, z: 0, w: 1)
//    y_img = amp.outputImage!
//
//    let clamp01 = CIFilter.colorClamp()
//    clamp01.inputImage = y_img
//    clamp01.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
//    clamp01.maxComponents = CIVector(x: 1, y: 0, z: 0, w: 1)
//    return clamp01.outputImage
//}

//func build_clip_mask_image_no_kernel(hdr: CIImage, threshold_headroom: Float) -> CIImage? {
//    guard let binary_r = build_clip_binary_mask(hdr: hdr, threshold_headroom: threshold_headroom) else {
//        return nil
//    }
//    let to_rgb = CIFilter.colorMatrix()
//    to_rgb.inputImage = binary_r
//    to_rgb.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
//    to_rgb.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
//    to_rgb.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
//    to_rgb.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
//    return to_rgb.outputImage
//}

// 2) NUOVO: stessa mask + conteggio full-res.
//    'context' lo puoi passare (riusa il tuo CIContext), altrimenti creane uno locale.
//func build_clip_mask_image_and_count(hdr: CIImage,
//                                     threshold_headroom: Float,
//                                     context: CIContext) -> (mask: CIImage, clipped: Int, total: Int)? {
//    guard let binary_r = build_clip_binary_mask(hdr: hdr, threshold_headroom: threshold_headroom) else {
//        return nil
//    }
//
//    // Colorizza in RGB per ottenere la mask da mostrare (come facevi già)
//    let to_rgb = CIFilter.colorMatrix()
//    to_rgb.inputImage = binary_r
//    to_rgb.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
//    to_rgb.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
//    to_rgb.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
//    to_rgb.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
//    guard let rgbMask = to_rgb.outputImage else { return nil }
//
//    // Conteggio: renderizza la *binaria* e conta i pixel con R > 0
//    let w = Int(binary_r.extent.width.rounded())
//    let h = Int(binary_r.extent.height.rounded())
//    guard w > 0, h > 0 else { return nil }
//
//    let clipped = countNonZeroR_inRGBA8(binary_r, width: w, height: h, context: context)
//    let total = w * h
//    return (mask: rgbMask, clipped: clipped, total: total)
//}

// 3) Supporto: renderizza in RGBA8 e conta i pixel con canale R > 0.
//    (Per mask mono, R=G=B; l’alpha è tipicamente 255 ovunque e NON va usata per il conteggio.)
/// Render RGBA8 and count pixels with R > 0 (mask content, not alpha).
//func countNonZeroR_inRGBA8(_ image: CIImage, width: Int, height: Int, context: CIContext) -> Int {
//    let rowBytes = width * 4
//    var buffer = [UInt8](repeating: 0, count: rowBytes * height)
//
//    context.render(
//        image,
//        toBitmap: &buffer,
//        rowBytes: rowBytes,
//        bounds: CGRect(x: 0, y: 0, width: width, height: height),
//        format: .RGBA8,
//        colorSpace: CGColorSpaceCreateDeviceRGB()
//    )
//
//    var count = 0
//    var i = 0
//    for _ in 0..<height {
//        for _ in 0..<width {
//            if buffer[i] > 0 { count += 1 } // use >=128 for harder binarization
//            i += 4
//        }
//    }
//    return count
//}

// Mono image per la mask in base alla preferenza utente.
// .luminance -> linear_luma(hdr) nel canale R
// .anyChannel -> CIMaximumComponent(hdr) (≈ maxRGB), sempre mono in R
//func monoForClippingMetric(from src: CIImage) -> CIImage {
//    switch AppPrefs.clippingMetric {
//    case .luminance:
//        return linear_luma(src) // Y lineare calcolata sui canali di 'src'
//    case .anyChannel:
//        // Max per canale, restituisce immagine "grigia" in R=G=B
//        return CIFilter(name: "CIMaximumComponent",
//                        parameters: [kCIInputImageKey: src])!.outputImage!
//    }
//}

// MARK: - Maker Apple Metadata

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

//func stops_from_maker_apple(maker33: Float, maker48: Float) -> (stops: Float, branch: String)? {
//    if maker33 < 1.0 {
//        if maker48 <= 0.01 { return (-20.0*maker48 + 1.8, "<1 & <=0.01") }
//        else               { return (-0.101*maker48 + 1.601, "<1 & >0.01") }
//    } else {
//        if maker48 <= 0.01 { return (-70.0*maker48 + 3.0, ">=1 & <=0.01") }
//        else               { return (-0.303*maker48 + 2.303, ">=1 & >0.01") }
//    }
//}

//struct MakerValidationDiffs {
//    let target_stops: Float
//    let forward_stops: Float
//    let abs_stops_diff: Float
//    let target_headroom: Float
//    let forward_headroom: Float
//    let rel_headroom_diff: Float
//    let branch: String
//}

//func validate_maker_apple(headroom_linear: Float,
//                          maker33: Float,
//                          maker48: Float,
//                          tol_stops_abs: Float = 0.01,
//                          tol_headroom_rel: Float = 0.02) -> (ok: Bool, diffs: MakerValidationDiffs?) {
//    let target_headroom = max(headroom_linear, 1.0)
//    let target_stops = log2f(target_headroom)
//    guard let (forward_stops, branch) = stops_from_maker_apple(maker33: maker33, maker48: maker48) else {
//        return (false, nil)
//    }
//    let forward_headroom = powf(2.0, max(forward_stops, 0.0))
//    let abs_stops_diff = abs(forward_stops - target_stops)
//    let rel_headroom_diff = abs(forward_headroom - target_headroom) / target_headroom
//    let ok = (abs_stops_diff <= tol_stops_abs) && (rel_headroom_diff <= tol_headroom_rel)
//    return (ok, .init(target_stops: target_stops, forward_stops: forward_stops, abs_stops_diff: abs_stops_diff,
//                      target_headroom: target_headroom, forward_headroom: forward_headroom,
//                      rel_headroom_diff: rel_headroom_diff, branch: branch))
//}

// MARK: - luma diagnostics

/// Media su 1x1 RGBAf dell'immagine passata (canale R).
//private func meanR(_ img: CIImage, context: CIContext) -> Float {
//    let f = CIFilter(name: "CIAreaAverage",
//                     parameters: [kCIInputImageKey: img,
//                                  kCIInputExtentKey: CIVector(cgRect: img.extent)])!
//    let out = f.outputImage!
//    var px = [Float](repeating: 0, count: 4)
//    context.render(out, toBitmap: &px,
//                   rowBytes: MemoryLayout<Float>.size * 4,
//                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
//                   format: .RGBAf, colorSpace: nil)
//    return px[0]
//}

/// Crea una mask binaria R∈{0,1} per (value > threshold+eps) su un'immagine "mono" nel canale R.
//private func binaryMaskRGreaterThan(_ monoR: CIImage, threshold: Float, epsilon: Float = 0) -> CIImage {
//    // outR = clamp( (inR - (threshold+eps)) * huge, 0, 1 )
//    let sub = CIFilter.colorMatrix()
//    sub.inputImage = monoR
//    sub.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
//    sub.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
//    sub.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
//    sub.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
//    sub.biasVector = CIVector(x: CGFloat(-(threshold + epsilon)), y: 0, z: 0, w: 0)
//    let pos = CIFilter.colorClamp()
//    pos.inputImage = sub.outputImage!
//    pos.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
//    pos.maxComponents = CIVector(x: 1e9, y: 0, z: 0, w: 1)
//
//    let amp = CIFilter.colorMatrix()
//    amp.inputImage = pos.outputImage!
//    amp.rVector = CIVector(x: 1_000_000, y: 0, z: 0, w: 0)
//    amp.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
//    amp.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
//    amp.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
//
//    let clamp01 = CIFilter.colorClamp()
//    clamp01.inputImage = amp.outputImage!
//    clamp01.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
//    clamp01.maxComponents = CIVector(x: 1, y: 0, z: 0, w: 1)
//    return clamp01.outputImage!
//}

/// Calcola tre percentuali (rapide) sopra soglia: luma>1, maxRGB>1, e per canale.
//func quickClippingDiagnostics(hdr: CIImage, context: CIContext) -> (lumaPct: Double, maxRGBPct: Double, rPct: Double, gPct: Double, bPct: Double) {
//    // Luma lineare nel canale R
//    let Y = linear_luma(hdr)
//
//    // MaxRGB (grigio) → usa CIMaximumComponent
//    let maxComp = CIFilter(name: "CIMaximumComponent", parameters: [kCIInputImageKey: hdr])!.outputImage!
//
//    // Mask binarie > 1.0
//    let eps: Float = 1e-6
//    let mY   = binaryMaskRGreaterThan(Y,        threshold: 1.0, epsilon: eps)
//    let mMax = binaryMaskRGreaterThan(maxComp,  threshold: 1.0, epsilon: eps)
//
//    // Per canale: isola R/G/B e soglia ciascuno
//    func channel(_ which: String) -> CIImage {
//        let m = CIFilter(name: "CIColorMatrix")!
//        m.setValue(hdr, forKey: kCIInputImageKey)
//        switch which {
//        case "R":
//            m.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
//        case "G":
//            m.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputRVector")
//        default: // "B"
//            m.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputRVector")
//        }
//        m.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
//        m.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
//        m.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
//        return m.outputImage!
//    }
//    let mR = binaryMaskRGreaterThan(channel("R"), threshold: 1.0, epsilon: eps)
//    let mG = binaryMaskRGreaterThan(channel("G"), threshold: 1.0, epsilon: eps)
//    let mB = binaryMaskRGreaterThan(channel("B"), threshold: 1.0, epsilon: eps)
//
//    // Percentuali = media R delle maschere (R è 0/1) → una render 1x1 ciascuna
//    let yPct   = Double(meanR(mY,   context: context)) * 100.0
//    let maxPct = Double(meanR(mMax, context: context)) * 100.0
//    let rPct   = Double(meanR(mR,   context: context)) * 100.0
//    let gPct   = Double(meanR(mG,   context: context)) * 100.0
//    let bPct   = Double(meanR(mB,   context: context)) * 100.0
//
//    return (yPct, maxPct, rPct, gPct, bPct)
//}
