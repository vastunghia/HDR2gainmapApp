import Foundation

nonisolated struct Constants {
    static let referenceHDRwhiteNit : Float = 203.0
    static let displayedHeadroomInStops : Float = 4.0
    static let maxHistogramNit : Float = referenceHDRwhiteNit * pow(2.0, displayedHeadroomInStops)
}
