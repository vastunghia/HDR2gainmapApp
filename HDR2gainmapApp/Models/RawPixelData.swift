import CoreImage.CIFilterBuiltins

/// Structure to cache raw raw pixel data among with required metadata.
/// All stored properties are immutable (`let`), so it is safe to read from any thread and to
/// hand between actors; `@unchecked Sendable` covers the non-Sendable `[String: Any]` field.
nonisolated final class RawPixelData: @unchecked Sendable {
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let componentsPerPixel: Int
    let isBigEndian: Bool
    let bytes: [UInt8]
    let cgImage: CGImage
    let properties: [String: Any]
    
    init(width: Int, height: Int, bitsPerComponent: Int, componentsPerPixel: Int,
         isBigEndian: Bool, bytes: [UInt8], cgImage: CGImage, properties: [String: Any]) {
        self.width = width
        self.height = height
        self.bitsPerComponent = bitsPerComponent
        self.componentsPerPixel = componentsPerPixel
        self.isBigEndian = isBigEndian
        self.bytes = bytes
        self.cgImage = cgImage
        self.properties = properties
    }
}
