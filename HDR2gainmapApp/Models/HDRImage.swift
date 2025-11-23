import Foundation
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// Rappresenta un'immagine HDR con i suoi settings e stato di processing
@Observable
class HDRImage: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    
    // Settings per il processing (memorizzati per immagine)
    var settings: ProcessingSettings
    
    // Stato del processing
    var thumbnailImage: NSImage?
    var previewImage: NSImage?
    var isProcessing = false
    var lastError: String?
    
    init(url: URL, loadThumbnailImmediately: Bool = true) {
        self.url = url
        self.fileName = url.deletingPathExtension().lastPathComponent
        self.settings = ProcessingSettings() // Settings di default
        
        // Genera thumbnail in background solo se richiesto
        // (permette al ViewModel di controllare l'ordine)
        if loadThumbnailImmediately {
            Task {
                await self.loadThumbnailAsync()
            }
        }
    }
    
    // Metodo pubblico per trigger manuale (chiamato dal ViewModel)
    func startThumbnailGeneration() async {
        await loadThumbnailAsync()
    }
    
    // Carica metadata del file immagine
    func loadMetadata() async -> ImageMetadata? {
        guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        
        // Ottieni properties dell'immagine
        guard let properties = CGImageSourceCopyPropertiesAtIndex(cgImageSource, 0, nil) as? [String: Any] else {
            return nil
        }
        
        // Dimensioni
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        
        // Bit depth
        let bitDepth = properties[kCGImagePropertyDepth as String] as? Int ?? 8
        
        // Color space
        var colorSpaceName = "Unknown"
        if let colorModel = properties[kCGImagePropertyColorModel as String] as? String {
            // Prova a ottenere il nome specifico
            if let profileName = properties[kCGImagePropertyProfileName as String] as? String {
                colorSpaceName = profileName
            } else {
                colorSpaceName = colorModel
            }
        }
        
        // Prova a determinare transfer function dal color space
        //        if transferFunction == "Unknown" {
        var transferFunction = "Unknown"
        if colorSpaceName.contains("PQ"){
            transferFunction = "PQ (HDR)"
            }
        //        }
        
        // File size
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }
        
        // Semplifica il nome del color space
        if colorSpaceName.contains("Display P3") || colorSpaceName.contains("P3") {
            colorSpaceName = "Display P3"
        } else if colorSpaceName.contains("sRGB") {
            colorSpaceName = "sRGB"
        } else if colorSpaceName.contains("RGB") {
            colorSpaceName = "RGB"
        }
        
        return ImageMetadata(
            colorSpace: colorSpaceName,
            transferFunction: transferFunction,
            width: width,
            height: height,
            bitDepth: bitDepth,
            fileSize: fileSize
        )
    }
    
    private func loadThumbnailAsync() async {
        
        // Usa QuickLook Thumbnailing per thumbnails veloci e ottimizzate
        let size = CGSize(width: 240, height: 160) // 2x della dimensione display per Retina
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
            // Fallback più leggero: carica solo i metadata senza decodificare
            await self.loadFallbackThumbnail()
        }
    }
    
    // Fallback: genera thumbnail downsampled (più efficiente del vecchio metodo)
    private func loadFallbackThumbnail() async {
        guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return
        }
        
        // Opzioni per downsampling: carica solo i dati necessari
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240, // Larghezza max
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(cgImageSource, 0, options as CFDictionary) else {
            return
        }
        
        await MainActor.run {
            self.thumbnailImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }
}
