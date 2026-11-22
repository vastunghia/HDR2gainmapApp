import CoreImage.CIFilterBuiltins

/// Cached source decode of an input file: the ImageIO `CGImage` (re-linearized when the linear
/// image is evicted from `HDRProcessor`'s cache, and read for display metadata) plus the file's
/// properties (Exif/TIFF/GPS… preserved on export). The encoded pixel samples are deliberately not
/// kept: every measurement runs on the linearized image (`HDRProcessor.analyzeLinearImage`), which is
/// correct whatever the input transfer (PQ or HLG) — the samples themselves are not.
/// All stored properties are immutable (`let`), so it is safe to read from any thread and to
/// hand between actors; `@unchecked Sendable` covers the non-Sendable `[String: Any]` field.
nonisolated final class RawPixelData: @unchecked Sendable {
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let cgImage: CGImage
    let properties: [String: Any]

    init(width: Int, height: Int, bitsPerComponent: Int, cgImage: CGImage, properties: [String: Any]) {
        self.width = width
        self.height = height
        self.bitsPerComponent = bitsPerComponent
        self.cgImage = cgImage
        self.properties = properties
    }
}
