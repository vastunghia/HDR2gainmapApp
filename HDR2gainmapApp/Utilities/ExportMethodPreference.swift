import Foundation

/// User-facing export method preference.
enum ExportMethodChoice: String, CaseIterable, Identifiable {
    case heif    // CIContext.writeHEIFRepresentation
    case heif10  // CIContext.writeHEIF10Representation (macOS 14+)
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .heif:   return "writeHEIFRepresentation"
        case .heif10: return "writeHEIF10Representation"
        }
    }
}

/// Read current preference (defaults to .heif).
func resolveExportMethodPreference() -> ExportMethodChoice {
    let raw = UserDefaults.standard.string(forKey: "exportMethodSelectionID")
    return ExportMethodChoice(rawValue: raw ?? ExportMethodChoice.heif.rawValue) ?? .heif
}
