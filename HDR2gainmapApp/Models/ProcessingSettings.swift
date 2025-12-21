import Foundation
import Observation

/// Processing settings for a single image.
@Observable
class ProcessingSettings {
    
    // MARK: - Default values
    static let defaultTonemapRatio: Float = 0.2  // UI displays as 0.8 (reversed)
    static let defaultPercentile: Float = 0.999  // 99.900%
    static let defaultTargetHeadroom: Float = 1.0
    
    // MARK: - Tone mapping
    
    /// Method for determining source headroom
    enum SourceHeadroomMethod: String, Codable, CaseIterable {
        case peakMax     = "Peak Max"
        case percentile  = "Percentile"
        case direct      = "Direct"
    }
    
    /// Source headroom method
    var sourceHeadroomMethod: SourceHeadroomMethod = .peakMax
    
    // MARK: - Source headroom parameters
    
    /// Peak Max parameter: In [0, 1] — 0 = no clipping; 1 = headroom = 1 (no tone mapping toward SDR).
    var tonemapRatio: Float = defaultTonemapRatio
    
    /// Percentile parameter: Percentile in [0, 1] — e.g. 0.999 = 99.9th.
    var percentile: Float = defaultPercentile
    
    /// Direct parameter: If nil, uses a dynamic default (source = measuredHeadroom).
    var directSourceHeadroom: Float? = nil
    
    // MARK: - Target headroom parameters
    
    /// Whether to allow adjusting target headroom (advanced option)
    var adjustTargetHeadroom: Bool = false
    
    /// Target headroom value: If nil, uses default of 1.0 (SDR).
    var targetHeadroom: Float? = nil
    
    /// Restores defaults for all parameters
    func resetDefaults(measuredHeadroom: Float) {
        // Reset source headroom parameters for all methods
        tonemapRatio = Self.defaultTonemapRatio
        percentile = Self.defaultPercentile
        
        let real = max(1.0, measuredHeadroom)
        directSourceHeadroom = real
        
        // Reset target headroom
        targetHeadroom = Self.defaultTargetHeadroom
        adjustTargetHeadroom = false
    }
    
    // MARK: - Visualization
    var showClippedOverlay: Bool = true
    var overlayColor: String = "magenta"
    
    init() {}
}
