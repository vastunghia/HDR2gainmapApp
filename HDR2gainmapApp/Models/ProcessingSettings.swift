import Foundation
import Observation

/// Processing settings for a single image.
@Observable
class ProcessingSettings {
    
    // MARK: - Tone mapping
    enum TonemapMethod: String, Codable, CaseIterable {
        case peakMax     = "Peak Max"
        case percentile  = "Percentile"
        case direct      = "Direct"
    }
    
    /// Tone mapping method.
    var method: TonemapMethod = .peakMax
    
    // MARK: - Peak Max parameters
    /// In [0, 1] — 0 = no clipping; 1 = headroom = 1 (no tone mapping toward SDR).
    var tonemapRatio: Float = 0.2
    
    // MARK: - Percentile parameters
    /// Percentile in [0, 1] — e.g. 0.999 = 99.9th.
    var percentile: Float = 0.999
    
    // MARK: - Direct parameters (explicit Apple headrooms)
    /// If nil, uses a dynamic default (source = measuredHeadroom).
    var directSourceHeadroom: Float? = nil
    /// If nil, uses a dynamic default (target = 1.0).
    var directTargetHeadroom: Float? = nil
    
    /// Restores Direct defaults (handy for a "Reset" button).
    func resetDirectDefaults(measuredHeadroom: Float) {
        let real = max(1.0, measuredHeadroom)
        directSourceHeadroom = real
        directTargetHeadroom = 1.0
    }
    
    // MARK: - Visualization
    var showClippedOverlay: Bool = true
    var overlayColor: String = "magenta"
    
    // MARK: - Export quality removed (now in UserDefaults/Preferences)
    // var heicQuality: Float = 0.97  // REMOVED
    
    init() {}
}
