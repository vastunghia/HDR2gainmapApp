import SwiftUI

struct RGBYHistogramData {
    /// Bins normalizzati in [0, 1]
    var x: [CGFloat]
    /// Densità normalizzate in [0, 1] per ciascun canale
    var r: [CGFloat]
    var g: [CGFloat]
    var b: [CGFloat]
    var y: [CGFloat]

    /// Posizione normalizzata (0...1) della linea headroom=0 (limite SDR)
    var sdrBoundaryX: CGFloat?
}

extension RGBYHistogramData {
    static let placeholderInput: RGBYHistogramData = {
        let n = 128
        let xs = (0..<n).map { CGFloat($0) / CGFloat(n - 1) }

        let r = xs.map { x in exp(-pow((x - 0.7) / 0.15, 2)) }
        let g = xs.map { x in exp(-pow((x - 0.5) / 0.18, 2)) }
        let b = xs.map { x in exp(-pow((x - 0.3) / 0.12, 2)) }
        let y = (0..<n).map { i in (r[i] + g[i] + b[i]) / 3 }

        return RGBYHistogramData(
            x: xs,
            r: normalize(r),
            g: normalize(g),
            b: normalize(b),
            y: normalize(y),
            sdrBoundaryX: 0.4
        )
    }()

    static let placeholderOutput: RGBYHistogramData = {
        let n = 128
        let xs = (0..<n).map { CGFloat($0) / CGFloat(n - 1) }

        let r = xs.map { x in exp(-pow((x - 0.5) / 0.18, 2)) }
        let g = xs.map { x in exp(-pow((x - 0.45) / 0.18, 2)) }
        let b = xs.map { x in exp(-pow((x - 0.4) / 0.18, 2)) }
        let y = (0..<n).map { i in (r[i] + g[i] + b[i]) / 3 }

        return RGBYHistogramData(
            x: xs,
            r: normalize(r),
            g: normalize(g),
            b: normalize(b),
            y: normalize(y),
            sdrBoundaryX: 0.4
        )
    }()

    private static func normalize(_ values: [CGFloat]) -> [CGFloat] {
        guard let maxVal = values.max(), maxVal > 0 else { return values }
        return values.map { $0 / maxVal }
    }
}
