import Foundation
import Observation

/// Settings di processing per una singola immagine
@Observable
class ProcessingSettings {  // ← Cambiato da struct a class
    enum TonemapMethod: String, Codable, CaseIterable {
        case peakMax = "Peak Max"
        case percentile = "Percentile"
    }
    
    // Metodo di tonemap
    var method: TonemapMethod = .peakMax
    
    // Parametri per Peak Max
    var tonemapRatio: Float = 0.2
    
    // Parametri per Percentile
    var percentile: Float = 0.999
    
    // Opzioni visualizzazione
    var showClippedOverlay: Bool = true
    var overlayColor: String = "magenta"
    
    // Opzioni export
    var heicQuality: Float = 0.97
    
    init() {}  // ← Aggiungi init vuoto
}
