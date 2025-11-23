import Foundation
import Observation

/// Settings di processing per una singola immagine
@Observable
class ProcessingSettings {  // class (non struct) come da tua base

    // MARK: - Tonemap method
    enum TonemapMethod: String, Codable, CaseIterable {
        case peakMax     = "Peak Max"
        case percentile  = "Percentile"
        case direct      = "Direct"      // ← NEW
    }

    /// Metodo di tonemap
    var method: TonemapMethod = .peakMax

    // MARK: - Parametri per Peak Max
    /// [0,1] — 0 => nessun clipping; 1 => headroom=1 (nessun tonemap verso SDR)
    var tonemapRatio: Float = 0.2

    // MARK: - Parametri per Percentile
    /// Percentile su [0,1] — es. 0.999 = 99.9°
    var percentile: Float = 0.999

    // MARK: - Parametri per Direct (espliciti Apple)
    /// Se nil, usa default dinamici (source = measuredHeadroom)
    var directSourceHeadroom: Float? = nil
    /// Se nil, usa default dinamici (target = 1.0)
    var directTargetHeadroom: Float? = nil

    /// Reimposta i default per Direct (comodo per un pulsante "Reset")
    func resetDirectDefaults(measuredHeadroom: Float) {
        let real = max(1.0, measuredHeadroom)
        directSourceHeadroom = real
        directTargetHeadroom = 1.0
    }

    // MARK: - Opzioni visualizzazione
    var showClippedOverlay: Bool = true
    var overlayColor: String = "magenta"

    // MARK: - Opzioni export
    var heicQuality: Float = 0.97

    init() {}
}
