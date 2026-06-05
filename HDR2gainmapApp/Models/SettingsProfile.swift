import Foundation

/// Serializable "development profile" for a folder of HDR images: the source folder,
/// the producing app version, and — only for images whose tone-mapping differs from the
/// defaults — their core settings. Images left at default are omitted entirely, so the
/// file stays sparse.
///
/// These DTOs live in the app target only (the CLI does not import/export profiles). They
/// are intentionally separate from the `@Observable` `ProcessingSettings` so that only the
/// *core* tone-mapping fields are persisted and the Observation machinery is not involved.

// MARK: - Core settings DTO

/// Sparse, Codable snapshot of the core tone-mapping fields. Every field is optional:
/// only the ones that differ from `ProcessingSettings()` defaults are populated, and the
/// synthesized `Codable` conformance omits `nil` fields (via `encodeIfPresent`).
struct CoreSettingsDTO: Codable {
    var sourceHeadroomMethod: ProcessingSettings.SourceHeadroomMethod?
    var tonemapRatio: Float?
    var percentile: Float?
    var directSourceHeadroom: Float?
    var adjustTargetHeadroom: Bool?
    var targetHeadroom: Float?

    /// True when no field is populated (i.e. the image is entirely at defaults).
    var isEmpty: Bool {
        sourceHeadroomMethod == nil
            && tonemapRatio == nil
            && percentile == nil
            && directSourceHeadroom == nil
            && adjustTargetHeadroom == nil
            && targetHeadroom == nil
    }
}

// MARK: - Per-image entry

struct ImageSettingsEntry: Codable {
    /// File name *with* extension (`url.lastPathComponent`), used to match on import.
    var fileName: String
    var settings: CoreSettingsDTO
}

// MARK: - Profile file

struct SettingsProfile: Codable {
    /// Schema version of the file format, distinct from `appVersion`. Bump when the on-disk
    /// shape changes in an incompatible way; readers reject files newer than they understand.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var appVersion: String
    var exportedAt: Date
    var folderPath: String
    var folderName: String
    var images: [ImageSettingsEntry]
}

// MARK: - ProcessingSettings <-> DTO bridging

extension ProcessingSettings {
    /// Builds a sparse DTO containing only the core fields that differ from the defaults.
    /// Returns `nil` when everything is at default, so callers can omit the image entirely.
    ///
    /// Note: `resetDefaults(measuredHeadroom:)` writes concrete values into
    /// `directSourceHeadroom`/`targetHeadroom`, so an image the user explicitly "reset" is
    /// reported as non-default and will be persisted. This is harmless over-storage; the
    /// concrete values are simply re-applied on import.
    func makeCoreDTO() -> CoreSettingsDTO? {
        var dto = CoreSettingsDTO()

        if sourceHeadroomMethod != .peakMax {
            dto.sourceHeadroomMethod = sourceHeadroomMethod
        }
        if tonemapRatio != Self.defaultTonemapRatio {
            dto.tonemapRatio = tonemapRatio
        }
        if percentile != Self.defaultPercentile {
            dto.percentile = percentile
        }
        if let direct = directSourceHeadroom {
            dto.directSourceHeadroom = direct
        }
        // `targetHeadroom` only affects the pipeline when the adjustment is enabled, so we
        // persist it only alongside `adjustTargetHeadroom == true`. This also avoids storing
        // the harmless 1.0 that the UI may write when the toggle is turned off.
        if adjustTargetHeadroom {
            dto.adjustTargetHeadroom = true
            if let target = targetHeadroom {
                dto.targetHeadroom = target
            }
        }

        return dto.isEmpty ? nil : dto
    }

    /// Applies the fields present in `dto`; absent fields are left untouched (a freshly
    /// created `ProcessingSettings` already holds the defaults).
    func applyCoreDTO(_ dto: CoreSettingsDTO) {
        if let method = dto.sourceHeadroomMethod { sourceHeadroomMethod = method }
        if let ratio = dto.tonemapRatio { tonemapRatio = ratio }
        if let pct = dto.percentile { percentile = pct }
        if let direct = dto.directSourceHeadroom { directSourceHeadroom = direct }
        if let adjust = dto.adjustTargetHeadroom { adjustTargetHeadroom = adjust }
        if let target = dto.targetHeadroom { targetHeadroom = target }
    }
}
