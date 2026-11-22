import Foundation

nonisolated struct Constants {
    static let referenceHDRwhiteNit : Float = 203.0
    static let displayedHeadroomInStops : Float = 4.0
    static let maxHistogramNit : Float = referenceHDRwhiteNit * pow(2.0, displayedHeadroomInStops)

    /// Display P3 (D65) luminance weights — the Y row of the P3→XYZ matrix. The engine works in
    /// extended-linear Display P3, so every luminance it computes on that data (measured headroom,
    /// percentile CDF, HDR histogram, mono gain map) uses these. Mirrored in `HistogramShaders.metal`.
    static let displayP3LumaWeights: (r: Float, g: Float, b: Float) = (0.2290, 0.6917, 0.0793)
}
