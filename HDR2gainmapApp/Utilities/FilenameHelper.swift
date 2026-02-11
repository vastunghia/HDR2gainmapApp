import Foundation

/// Helper to generate filenames with optional suffix
struct FilenameHelper {
    
    /// Generate a filename with optional suffix applied in a smart way
    static func generateFilename(baseName: String, suffix: String, extension ext: String) -> String {
        // Remove leading / trailing whitespace
        let trimmedSuffix = suffix.trimmingCharacters(in: .whitespaces)
        
        // If suffix is empty, return only base + extension
        guard !trimmedSuffix.isEmpty else {
            return "\(baseName).\(ext)"
        }
        
        // If suffix starts with underscore, use it as it is
        // Othwersie, add underscore
        let finalSuffix: String
        if trimmedSuffix.hasPrefix("_") {
            finalSuffix = trimmedSuffix
        } else {
            finalSuffix = "_\(trimmedSuffix)"
        }
        
        return "\(baseName)\(finalSuffix).\(ext)"
    }
}
