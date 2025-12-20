import Foundation
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// Represents an HDR image and its per-image processing settings and state.
@Observable
class HDRImage: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    
    // Per-image processing settings (stored with the image instance).
    var settings: ProcessingSettings
    
    // Processing state.
    var thumbnailImage: NSImage?
    var previewImage: NSImage?
    var isProcessing = false
    var lastError: String?
    
    // Global metadata cache (key: file URL, value: extracted metadata).
    private static var metadataCache = [URL: ImageMetadata]()
    private var isLoadingMetadata = false
    
    init(url: URL, loadThumbnailImmediately: Bool = true) {
        self.url = url
        self.fileName = url.deletingPathExtension().lastPathComponent
        self.settings = ProcessingSettings()
        
        if loadThumbnailImmediately {
            Task {
                await self.loadThumbnailAsync()
            }
        }
    }
    
    func startThumbnailGeneration() async {
        await loadThumbnailAsync()
    }
    
    /// Loads image metadata with a global cache (avoids re-reading from disk after the first extraction).
    /// Prefers raw pixel bytes already cached by HDRProcessor.loadHDR(), when available.
    @MainActor
    func loadMetadata() async -> ImageMetadata? {
        // print("📋 [HDRImage.loadMetadata] Called for: \(fileName)")
        
        // 1) Global cache hit?
        if let cached = Self.metadataCache[url] {
            // print("   ⚡ Global cache HIT - returning cached metadata")
            return cached
        }
        
        // 2) Already loading? (prevents concurrent extraction for this instance).
        guard !isLoadingMetadata else {
            // print("   ⚠️ Already loading, waiting...")
            try? await Task.sleep(for: .milliseconds(100))
            return Self.metadataCache[url]
        }
        
        isLoadingMetadata = true
        // print("   ❌ Cache MISS - extracting metadata...")
        
        // 3) First, try to reuse raw pixel bytes already cached by HDRProcessor...
        //    (e.g., if the image was already loaded for preview/histograms).
        let metadata: ImageMetadata?
        
        if let cachedRawData = HDRProcessor.shared.getCachedRawPixelData(url: url) {
            // print("   ⚡ METADATA: Using cached raw data from HDRProcessor (NO DISK I/O)")
            metadata = extractMetadataFromCachedData(cachedRawData)
        } else {
            // print("   ⚠️ METADATA: Raw data not cached yet, reading header from disk")
            metadata = await extractMetadataFromDisk()
        }
        
        // 4) Store in the global metadata cache.
        if let metadata = metadata {
            Self.metadataCache[url] = metadata
            // print("   ✅ Metadata cached globally for: \(fileName)")
        } else {
            // print("   ❌ Failed to extract metadata")
        }
        
        isLoadingMetadata = false
        return metadata
    }
    
    /// Extracts metadata from already-cached RawPixelData (zero disk I/O).
    private func extractMetadataFromCachedData(_ rawData: RawPixelData) -> ImageMetadata? {
        // print("   → Extracting metadata from cached raw data...")
        
        let width = rawData.width
        let height = rawData.height
        let bitDepth = rawData.bitsPerComponent
        
        // Use CGImage properties from the cached CGImage.
        let cgImage = rawData.cgImage
        
        var colorSpaceName = "Unknown"
        if let colorSpace = cgImage.colorSpace {
            if let name = colorSpace.name as String? {
                colorSpaceName = name
            }
        }
        
        // Transfer function (detect PQ)
        var transferFunction = "Unknown"
        if colorSpaceName.contains("PQ") || colorSpaceName.contains("ST2084") || colorSpaceName.contains("2084") {
            transferFunction = "PQ (HDR)"
        } else if colorSpaceName.contains("sRGB") || colorSpaceName.contains("RGB") {
            transferFunction = "sRGB"
        }
        
        // File size
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }
        
        // Simplify the color space name for display purposes.
        if colorSpaceName.contains("Display P3") || colorSpaceName.contains("displayP3") {
            colorSpaceName = "Display P3"
        } else if colorSpaceName.contains("P3") {
            colorSpaceName = "Display P3"
        } else if colorSpaceName.contains("sRGB") {
            colorSpaceName = "sRGB"
        } else if colorSpaceName.contains("RGB") && !colorSpaceName.contains("Unknown") {
            colorSpaceName = "RGB"
        }
        
        // print("   ✅ Metadata extracted from cache:")
        // print("      - Color Space: \(colorSpaceName)")
        // print("      - Transfer: \(transferFunction)")
        // print("      - Resolution: \(width)×\(height)")
        // print("      - Bit Depth: \(bitDepth)")
        // print("      - File Size: \(fileSize) bytes")
        
        return ImageMetadata(
            colorSpace: colorSpaceName,
            transferFunction: transferFunction,
            width: width,
            height: height,
            bitDepth: bitDepth,
            fileSize: fileSize
        )
    }
    
    /// Extracts metadata from disk (fallback — only if HDRProcessor has no cached raw data).
    private func extractMetadataFromDisk() async -> ImageMetadata? {
        // print("   📀 Reading from DISK (CGImageSource)...")
        
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            // print("   ❌ Cannot create CGImageSource")
            return nil
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            // print("   ❌ Cannot read properties")
            return nil
        }
        
        // print("   → Extracting metadata from properties...")
        
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let bitDepth = properties[kCGImagePropertyDepth as String] as? Int ?? 8
        
        var colorSpaceName = "Unknown"
        if let profileName = properties[kCGImagePropertyProfileName as String] as? String {
            colorSpaceName = profileName
        } else if let colorModel = properties[kCGImagePropertyColorModel as String] as? String {
            colorSpaceName = colorModel
        }
        
        var transferFunction = "Unknown"
        if colorSpaceName.contains("PQ") || colorSpaceName.contains("ST2084") || colorSpaceName.contains("2084") {
            transferFunction = "PQ (HDR)"
        } else if let colorModel = properties[kCGImagePropertyColorModel as String] as? String,
                  (colorModel.contains("PQ") || colorModel.contains("ST2084")) {
            transferFunction = "PQ (HDR)"
        } else if colorSpaceName.contains("sRGB") || colorSpaceName.contains("RGB") {
            transferFunction = "sRGB"
        }
        
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }
        
        if colorSpaceName.contains("Display P3") || colorSpaceName.contains("displayP3") {
            colorSpaceName = "Display P3"
        } else if colorSpaceName.contains("P3") {
            colorSpaceName = "Display P3"
        } else if colorSpaceName.contains("sRGB") {
            colorSpaceName = "sRGB"
        } else if colorSpaceName.contains("RGB") && !colorSpaceName.contains("Unknown") {
            colorSpaceName = "RGB"
        }
        
        // print("   ✅ Metadata extracted from disk:")
        // print("      - Color Space: \(colorSpaceName)")
        // print("      - Transfer: \(transferFunction)")
        // print("      - Resolution: \(width)×\(height)")
        // print("      - Bit Depth: \(bitDepth)")
        // print("      - File Size: \(fileSize) bytes")
        
        return ImageMetadata(
            colorSpace: colorSpaceName,
            transferFunction: transferFunction,
            width: width,
            height: height,
            bitDepth: bitDepth,
            fileSize: fileSize
        )
    }
    
    // MARK: - Thumbnail Loading
    
    private func loadThumbnailAsync() async {
        let size = CGSize(width: 240, height: 160)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        
        do {
            let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            
            await MainActor.run {
                self.thumbnailImage = thumbnail.nsImage
            }
            
        } catch {
            await self.loadFallbackThumbnail()
        }
    }
    
    private func loadFallbackThumbnail() async {
        guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return
        }
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(cgImageSource, 0, options as CFDictionary) else {
            return
        }
        
        await MainActor.run {
            self.thumbnailImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }
    
}
