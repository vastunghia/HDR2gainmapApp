import CoreImage.CIFilterBuiltins

/// Structure to cache raw raw pixel data among with required metadata
class RawPixelData {
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let componentsPerPixel: Int
    let isBigEndian: Bool
    let bytes: [UInt8]
    let cgImage: CGImage  // CGImage originale per ricreare CIImage
    //        let properties: [String: Any]
    
    init(width: Int, height: Int, bitsPerComponent: Int, componentsPerPixel: Int, isBigEndian: Bool, bytes: [UInt8], cgImage: CGImage) {
        self.width = width
        self.height = height
        self.bitsPerComponent = bitsPerComponent
        self.componentsPerPixel = componentsPerPixel
        self.isBigEndian = isBigEndian
        self.bytes = bytes
        self.cgImage = cgImage
    }
}
