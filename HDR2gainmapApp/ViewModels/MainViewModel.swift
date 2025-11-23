import Foundation
import SwiftUI
import UniformTypeIdentifiers
internal import Combine
import QuartzCore // per CACurrentMediaTime()

/// ViewModel principale che gestisce lo stato dell'app
@MainActor
@Observable
class MainViewModel {
    // MARK: - State
    
    // Immagini caricate
    var images: [HDRImage] = []
    
    // Immagine correntemente selezionata
    var selectedImage: HDRImage? {
        didSet { refreshMeasuredHeadroom() }
    }
    
    // Preview generata per l'immagine selezionata
    var currentPreview: NSImage?
    
    // Stato UI
    var isLoadingPreview = false
    var isExporting = false
    var exportProgress: Double = 0.0
    var exportCurrentFile: String = ""
    
    // Auto-refresh preview when settings change
    var autoRefreshPreview: Bool = true
    
    var measuredHeadroomRaw: Float = 1.0    // valore “reale” dal file HDR
    var measuredHeadroom: Float = 1.0       // comodo per logiche che richiedono ≥ 1.0
    
    // Debouncing
    private var refreshTask: Task<Void, Never>?  // ← AGGIUNGI
    private let refreshDebounceInterval: TimeInterval = 0.3  // ← AGGIUNGI (300ms)
    
    // Errori
    var errorMessage: String?
    var showError = false
    
    // Export results
    var exportResults: ExportResults?
    var showExportSummary = false
    
    // Statistiche di clipping della preview corrente
    struct ClippingStats {
        let clipped: Int   // pixel clippati (da collegare alla tua maschera)
        let total: Int     // pixel totali della preview
    }
    
    // …
    var clippingStats: ClippingStats? = nil
    
    // Computed property: l'immagine corrente è valida per il processing?
    var isCurrentImageValid: Bool {
        // Un'immagine è valida se è selezionata E non ha errori
        return selectedImage != nil && previewError == nil
    }
    
    private let processor = HDRProcessor.shared
    
    // MARK: - Folder Selection
    
    /// Mostra dialog per selezionare la cartella input HDR
    func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select folder containing HDR PNG images"
        
        panel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = panel.url {
                Task {
                    await self.loadImagesFromFolder(url)
                }
            }
        }
    }
    
    /// Carica tutte le immagini PNG HDR dalla cartella selezionata
    private func loadImagesFromFolder(_ folderURL: URL) async {
        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            
            let pngFiles = contents.filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            
            guard !pngFiles.isEmpty else {
                self.errorMessage = "No PNG files found in selected folder"
                self.showError = true
                return
            }
            
            // Crea HDRImage objects SENZA generare thumbnail automaticamente
            self.images = pngFiles.map { HDRImage(url: $0, loadThumbnailImmediately: false) }
            
            // Seleziona automaticamente la prima immagine
            if let firstImage = self.images.first {
                await self.selectImage(firstImage)
            }
            
            // Avvia generazione thumbnails in ordine con concorrenza limitata
            await loadThumbnailsInOrder()
            
        } catch {
            self.errorMessage = "Failed to load images: \(error.localizedDescription)"
            self.showError = true
        }
    }
    
    /// Genera thumbnails in ordine con concorrenza limitata (4 alla volta)
    func loadThumbnailsInOrder() async {
        let items = self.images
        guard !items.isEmpty else { return }

        for img in items {
            await img.startThumbnailGeneration()
        }
    }
    
    
    // MARK: - Image Selection
    
    /// Seleziona un'immagine e genera la preview
    func selectImage(_ image: HDRImage) async {
        self.selectedImage = image
        
        // Reset stato precedente per garantire refresh pulito
        self.previewError = nil
        self.currentPreview = nil
        self.clippingStats = nil
        
        // Genera preview automaticamente
        await generatePreview()
        
        refreshMeasuredHeadroom()
        
    }
    
    func refreshMeasuredHeadroom() {
        Task { @MainActor in
            guard let url = self.selectedImage?.url else { return }
            do {
                let raw = try processor.computeMeasuredHeadroomRaw(url: url)
                self.measuredHeadroomRaw = raw
                self.measuredHeadroom = max(1.0, raw)
            } catch {
                self.measuredHeadroomRaw = 1.0
                self.measuredHeadroom   = 1.0
            }
        }
    }
    
    // MARK: - Preview Generation
    
    // Preview error (non blocca la visualizzazione dell'immagine)
    var previewError: String?
    
    /// Genera preview per l'immagine selezionata con i settings correnti
    @MainActor
    func generatePreview() async {
        guard let image = self.selectedImage else { return }
        self.isLoadingPreview = true
        self.previewError = nil
        self.currentPreview = nil
        self.clippingStats = nil
        
        do {
            // ⬇️ usa l’overload con callback: niente più ricalcolo separato
            let preview = try await processor.generatePreview(for: image) { [weak self] clipped, total in
                Task { @MainActor in
                    if total > 0 {
                        self?.clippingStats = ClippingStats(clipped: clipped, total: total)
                    } else {
                        self?.clippingStats = nil
                    }
                }
            }
            
            self.currentPreview = preview
            self.isLoadingPreview = false
            
            // (opzionale) log rapido
            if let s = self.clippingStats {
                print("Clipping full-res: \(s.clipped)/\(s.total) = \(Double(s.clipped) / Double(s.total) * 100)%")
            }
            
        } catch {
            self.isLoadingPreview = false
            self.previewError = error.localizedDescription
            self.currentPreview = nil
            self.clippingStats = nil
            print("❌ Preview failed: \(error.localizedDescription)")
        }
    }
    
    /// Refresh preview (chiamato quando l'utente cambia settings manualmente)
    func refreshPreview() {
        Task {
            await generatePreview()
        }
    }

    /// Refresh preview con debounce (per auto-refresh)
    /// Cancella il task precedente se ancora in attesa
    func debouncedRefreshPreview() {
        // cancella task precedente
        refreshTask?.cancel()

        // feedback immediato
        isLoadingPreview = true

        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(Int(refreshDebounceInterval * 1000)))
            guard !Task.isCancelled else { return }
            await generatePreview()
        }
    }
    
    // MARK: - Export
    
    /// Esporta la singola immagine selezionata
    func exportCurrentImage() {
        guard let image = selectedImage else { return }
        
        let panel = NSSavePanel()
        panel.nameFieldStringValue = image.fileName + ".heic"
        panel.allowedContentTypes = [UTType.heic]
        panel.message = "Choose export location"
        
        panel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = panel.url {
                Task {
                    await self.performExport(images: [image], outputFolder: url.deletingLastPathComponent())
                }
            }
        }
    }
    
    /// Esporta tutte le immagini
    func exportAllImages() {
        guard !images.isEmpty else { return }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder for all images"
        
        panel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = panel.url {
                Task {
                    await self.performExport(images: self.images, outputFolder: url)
                }
            }
        }
    }
    
    /// Esegue l'export di una lista di immagini
    private func performExport(images: [HDRImage], outputFolder: URL) async {
        isExporting = true
        exportProgress = 0.0
        
        var succeeded: [String] = []
        var failed: [(String, String)] = []
        var skipped: [String] = []
        
        let totalCount = images.count
        guard totalCount > 0 else {
            isExporting = false
            exportResults = ExportResults(total: 0, succeeded: [], failed: [], skipped: [])
            showExportSummary = true
            return
        }
        
        for (index, image) in images.enumerated() {
            exportCurrentFile = image.fileName

            var isValid = true
            do {
                _ = try await processor.generatePreview(for: image)
            } catch {
                isValid = false
                skipped.append(image.fileName)
            }
            
            // EXPORT
            if isValid {
                let outputURL = outputFolder
                    .appendingPathComponent(image.fileName)
                    .appendingPathExtension("heic")
                try? FileManager.default.removeItem(at: outputURL)
                do {
                    try await processor.exportImage(image, to: outputURL)
                    succeeded.append(image.fileName)
                } catch {
                    failed.append((image.fileName, error.localizedDescription))
                }
            }
            
            // progress
            exportProgress = Double(index + 1) / Double(totalCount)
        }
        
        // Summary UI
        isExporting = false
        exportResults = ExportResults(
            total: totalCount,
            succeeded: succeeded,
            failed: failed,
            skipped: skipped
        )
        showExportSummary = true
    }
}

// MARK: - Export Results

struct ExportResults {
    let total: Int
    let succeeded: [String]
    let failed: [(fileName: String, reason: String)]
    let skipped: [String]
    
    var successCount: Int { succeeded.count }
    var failedCount: Int { failed.count }
    var skippedCount: Int { skipped.count }
}
