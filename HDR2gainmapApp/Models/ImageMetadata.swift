import Foundation

/// Simple metadata extracted from the image header (no full decode).
struct ImageMetadata {
    let colorSpace: String
    let transferFunction: String
    let width: Int
    let height: Int
    let bitDepth: Int
    let fileSize: Int64
    
    var resolutionString: String {
        let mpix = Double(width * height) / 1_000_000.0
        return "\(width) × \(height) (\(String(format: "%.1f", mpix)) Mpix)"
    }
    
    var bitDepthString: String {
        return "\(bitDepth)-bit"
    }
    
    var fileSizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: fileSize)
    }
}
