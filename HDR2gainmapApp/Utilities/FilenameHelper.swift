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

    /// The output names that more than one entry of `names` would produce — e.g. `photo.png` and
    /// `photo.tif` both export to `photo.heic`. Compared case-insensitively, as on the default
    /// (case-insensitive) APFS/HFS+ volumes, where `Photo.heic` and `photo.heic` are the same file.
    /// Returns the colliding names lowercased.
    static func collidingNames(_ names: [String]) -> Set<String> {
        var seen = Set<String>(), colliding = Set<String>()
        for name in names {
            let key = name.lowercased()
            if !seen.insert(key).inserted { colliding.insert(key) }
        }
        return colliding
    }
}
