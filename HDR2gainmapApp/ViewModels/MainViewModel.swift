import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// ViewModel principale che gestisce lo stato dell'app
@MainActor
@Observable
class MainViewModel {
    // MARK: - State
    
    // Immagini caricate
    var images: [HDRImage] = []
    
    // Immagine correntemente selezionata
    var selectedImage: HDRImage?
    
    // Preview generata per l'immagine selezionata
    var currentPreview: NSImage?
    
    // Stato UI
    var isLoadingPreview = false
    var isExporting = false
    var exportProgress: Double = 0.0
    var exportCurrentFile: String = ""
    
    // Auto-refresh preview when settings change
    var autoRefreshPreview: Bool = true
    
    // Debouncing
    private var refreshTask: Task<Void, Never>?  // ← AGGIUNGI
    private let refreshDebounceInterval: TimeInterval = 0.3  // ← AGGIUNGI (300ms)
    
    // Errori
    var errorMessage: String?
    var showError = false
    
    // Export results
    var exportResults: ExportResults?
    var showExportSummary = false
    
    // Preview error (marca immagini non valide)
//    var previewError: String?

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
    private func loadThumbnailsInOrder() async {
        let maxConcurrentTasks = 4 // Ottimale per 6-core CPU
        
        await withTaskGroup(of: Void.self) { group in
            var index = 0
            
            // Avvia i primi N task
            for i in 0..<min(maxConcurrentTasks, images.count) {
                group.addTask {
                    await self.images[i].startThumbnailGeneration()
                }
                index = i + 1
            }
            
            // Man mano che i task finiscono, avviane di nuovi
            for await _ in group {
                if index < images.count {
                    let currentIndex = index
                    group.addTask {
                        await self.images[currentIndex].startThumbnailGeneration()
                    }
                    index += 1
                }
            }
        }
    }
    
    // MARK: - Image Selection
    
    /// Seleziona un'immagine e genera la preview
    func selectImage(_ image: HDRImage) async {
        self.selectedImage = image
        
        // Reset stato precedente per garantire refresh pulito
        self.previewError = nil
        self.currentPreview = nil
        
        // Genera preview automaticamente
        await generatePreview()
    }
    
    // MARK: - Preview Generation
    
    // Preview error (non blocca la visualizzazione dell'immagine)
    var previewError: String?
    
    // Fallback image quando preview fallisce
//    var fallbackImage: NSImage?
    
    /// Genera preview per l'immagine selezionata con i settings correnti
    func generatePreview() async {
        guard let image = selectedImage else {
            isLoadingPreview = false
            return
        }
        
        print("🔄 Generating preview for: \(image.fileName)")
        
        if !isLoadingPreview {
            isLoadingPreview = true
        }
        
        // Reset preview error
        previewError = nil
        
        do {
            let preview = try await processor.generatePreview(for: image)
            self.currentPreview = preview
            self.isLoadingPreview = false
            print("✅ Preview generated successfully for: \(image.fileName)")
        } catch {
            self.isLoadingPreview = false
            
            // Salva l'errore
            let errorMsg = error.localizedDescription
            self.previewError = errorMsg
            
            // Resetta currentPreview
            self.currentPreview = nil
            
            print("❌ Preview generation failed for: \(image.fileName)")
            print("   Error: \(errorMsg)")
            print("   Image marked as invalid - UI will show error message")
        }
    }
    
//    /// Carica immagine fallback quando preview fallisce
//    private func loadFallbackImage(for image: HDRImage, error: String) async {
//        let imageURL = image.url
//        let imageName = image.fileName
//        
//        print("📸 Loading fallback image for: \(imageName)")
//        
//        // Carica in background thread
//        let loadedImage = await Task.detached(priority: .userInitiated) {
//            NSImage(contentsOf: imageURL)
//        }.value
//        
//        if let nsImage = loadedImage {
//            print("✅ Fallback image loaded successfully")
//            print("   Fallback image size: \(nsImage.size)")
//            
//            // IMPORTANTE: Assegna tutto insieme per triggerare un singolo update
//            self.fallbackImage = nsImage
//            self.previewError = error
//            self.currentPreview = nil
//            
//            print("   State after assignment - error: \(self.previewError != nil), fallback: \(self.fallbackImage != nil)")
//        } else {
//            print("❌ Failed to load fallback image")
//            self.previewError = error  // Mostra almeno l'errore
//        }
//    }
    
    /// Refresh preview (chiamato quando l'utente cambia settings)
    func refreshPreview() {
        Task {
            await generatePreview()
        }
    }
    
    /// Refresh preview con debounce (per auto-refresh)
    /// Cancella il task precedente se ancora in attesa
    func debouncedRefreshPreview() {
        // Cancella il task precedente se esiste
        refreshTask?.cancel()
        
        // Setta isLoadingPreview SUBITO (per feedback visivo immediato)
        // NON verrà resettato fino al completamento del refresh
        isLoadingPreview = true
        
        // Crea nuovo task con delay
        refreshTask = Task {
            // Aspetta il debounce interval
            try? await Task.sleep(for: .milliseconds(Int(refreshDebounceInterval * 1000)))
            
            // Se il task è stato cancellato, NON resettare isLoadingPreview
            // (verrà resettato dal prossimo task o dal completamento)
            guard !Task.isCancelled else {
                return  // ← RIMOSSO il reset di isLoadingPreview qui
            }
            
            // Esegui il refresh (generatePreview gestirà isLoadingPreview)
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
        var skipped: [String] = []  // ← AGGIUNGI questa riga
        
        let totalCount = images.count
        
        for (index, image) in images.enumerated() {
            exportCurrentFile = image.fileName
            
            // Verifica se l'immagine è valida prima di esportare
            // (genera preview per controllare validità)
            var isValid = true
            do {
                _ = try await processor.generatePreview(for: image)
            } catch {
                // Immagine non valida, skippa
                isValid = false
                skipped.append(image.fileName)
                print("⏭️ Skipping invalid image: \(image.fileName) - \(error.localizedDescription)")
            }
            
            if isValid {
                let outputURL = outputFolder
                    .appendingPathComponent(image.fileName)
                    .appendingPathExtension("heic")
                
                do {
                    try await processor.exportImage(image, to: outputURL)
                    succeeded.append(image.fileName)
                } catch {
                    failed.append((image.fileName, error.localizedDescription))
                }
            }
            
            // Update progress
            exportProgress = Double(index + 1) / Double(totalCount)
        }
        
        // Show summary
        isExporting = false
        exportResults = ExportResults(
            total: totalCount,
            succeeded: succeeded,
            failed: failed,
            skipped: skipped  // ← AGGIUNGI questo parametro
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
