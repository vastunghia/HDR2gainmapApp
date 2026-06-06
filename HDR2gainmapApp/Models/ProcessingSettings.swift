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
    
    /// Whether the image's tone-mapping/export settings differ from the defaults — drives the
    /// "modified" thumbnail badge. Mode-aware so that "Reset defaults" leaves it false (the reset
    /// writes concrete values into the unused direct/target fields, which we deliberately ignore).
    var isModifiedFromDefaults: Bool {
        switch sourceHeadroomMethod {
        case .peakMax:
            if tonemapRatio != Self.defaultTonemapRatio { return true }
        case .percentile, .direct:
            return true  // not the default (Peak Max) method
        }
        if adjustTargetHeadroom { return true }
        if gainMapAsRGB { return true }
        if !filenameSuffix.isEmpty { return true }
        return false
    }

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
    
    // MARK: - Gain map encoding

    /// Whether to encode the gain map as RGB (3-channel) instead of monochrome (luma).
    /// Diagnostic/experimental: an RGB gain map can carry per-channel boosts and thus
    /// preserve highlight saturation that a luma-only gain map cannot restore.
    var gainMapAsRGB: Bool = false

    // MARK: - Export

    /// Optional suffix to append to exported filenames
    var filenameSuffix: String = ""
    
    init() {}
}
