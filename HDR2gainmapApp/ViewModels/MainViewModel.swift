import Foundation
import SwiftUI
import UniformTypeIdentifiers
internal import Combine
import QuartzCore // For CACurrentMediaTime()

/// Primary view model that owns the app state and coordinates processing/export.
@MainActor
@Observable
class MainViewModel {
    // MARK: - State
    
    // Loaded images
    var images: [HDRImage] = []
    
    // Currently selected image
    var selectedImage: HDRImage? {
        didSet { refreshMeasuredHeadroom() }
    }
    
    // Preview generated for the selected image
    var currentPreview: NSImage?
    
    // UI state
    var isLoadingPreview = false
    var isLoadingNewImage = false
    var isExporting = false
    var exportProgress: Double = 0.0
    var exportCurrentFile: String = ""
    
    var measuredHeadroomRaw: Float = 1.0    // Raw headroom value measured from the HDR file
    var measuredHeadroom: Float = 1.0       // Clamped convenience value (always ≥ 1.0)
    
    // Token used by views to force a redraw once the percentile → headroom lookup table becomes available.
    // (Views only invalidate when they read a property that changes.)
    var percentileHeadroomCacheGeneration: Int = 0
    
    // Histogram State
    var hdrHistogram: HistogramCalculator.HistogramResult?
    var sdrHistogram: HistogramCalculator.HistogramResult?
    var isLoadingHistograms = false
    
    // Separate debouncing for preview and histograms
    private var refreshTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
    private let refreshDebounceInterval: TimeInterval = 0.3
    
    // Errors
    var errorMessage: String?
    var showError = false
    
    // Export results
    var exportResults: ExportResults?
    var showExportSummary = false
    
    // Clipping statistics for the current preview
    struct ClippingStats {
        let clipped: Int   // Number of clipped pixels (hooked up by the processor callback)
        let total: Int     // Total number of pixels in the preview
    }
    
    // (optional) Additional per-preview stats
    var clippingStats: ClippingStats? = nil
    
    // Whether the currently selected image can be processed/exported
    var isCurrentImageValid: Bool {
        // Valid if an image is selected and the preview pipeline has no error
        return selectedImage != nil && previewError == nil
    }    // MARK: - Histogram Reference Lines
    //
    // Note: During development, a few helper properties/functions for drawing histogram reference lines
    // (SDR white, source/target headroom, nit → x mapping, etc.) lived here as experiments.
    // They were removed to keep the view model focused on state and orchestration.
    // If you reintroduce reference lines, prefer keeping the math close to the histogram rendering code.
    
    private let processor = HDRProcessor.shared
    
    // MARK: - Folder Selection
    
    /// Presents a panel to pick the input folder containing HDR PNGs.
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
    
    /// Loads all HDR PNG images from the selected folder.
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
            
            // Create HDRImage objects without triggering thumbnail generation yet.
            self.images = pngFiles.map { HDRImage(url: $0, loadThumbnailImmediately: false) }
            
            // Auto-select the first image.
            if let firstImage = self.images.first {
                await self.selectImage(firstImage)
            }
            
            // Start thumbnail generation in order (throttled).
            await loadThumbnailsInOrder()
            
        } catch {
            self.errorMessage = "Failed to load images: \(error.localizedDescription)"
            self.showError = true
        }
    }
    
    /// Generates thumbnails in order (generation is internally throttled).
    func loadThumbnailsInOrder() async {
        let items = self.images
        guard !items.isEmpty else { return }
        
        for img in items {
            await img.startThumbnailGeneration()
        }
    }
    
    
    // MARK: - Image Selection
    
    /// Selects an image and triggers preview + histogram generation.
    func selectImage(_ image: HDRImage) async {
        
        // Note: the thumbnail list view may toggle the "new image" loading spinner and clear histograms immediately.
        // Here we switch selection, reset per-image state, generate the preview first, then compute histograms.
        
        
        // Switch selection (triggers a headroom refresh via `didSet`).
        self.selectedImage = image
        
        // Reset previous state
        self.previewError = nil
        self.currentPreview = nil
        self.clippingStats = nil
        
        // Generate the preview first.
        await generatePreview(refreshHistograms: false)
        
        // Hide the "new image" spinner after the preview is ready; histograms run afterwards.
        self.isLoadingNewImage = false
        
        // Generate histograms afterwards (keeps the selection UI feeling snappy).
        await generateHistograms()
    }
    
    func refreshMeasuredHeadroom() {
        Task { @MainActor in
            guard let url = self.selectedImage?.url else { return }
            
            // Use getHeadroomForImage() (cached) instead of re-measuring headroom each time.
            let raw = processor.getHeadroomForImage(url: url)
            self.measuredHeadroomRaw = raw
            self.measuredHeadroom = max(1.0, raw)
            
            // Warm up the percentile lookup table so the histogram headroom indicator can update in real time
            // while the user drags the Percentile slider (preview generation is debounced).
            Task {
                let _ = await self.processor.prewarmPercentileCDF(url: url)
                self.percentileHeadroomCacheGeneration &+= 1
            }
            
        }
    }
    
    /// Returns a cached percentile-derived source headroom for the currently selected image.
    /// - Note: Returns nil until HDRProcessor has finished building the lookup table for the selected image.
    func cachedPercentileSourceHeadroom() -> Float? {
        guard let image = selectedImage else { return nil }
        return processor.cachedPercentileHeadroom(url: image.url, percentile: image.settings.percentile)
        
    }
    
    // MARK: - Preview
    
    // Preview error (does not prevent showing the rest of the UI).
    var previewError: String?
    
    /// Generates a preview for the selected image using the current settings.
    /// - Parameter refreshHistograms: If true, regenerates histograms after the preview finishes.
    @MainActor
    func generatePreview(refreshHistograms: Bool = true) async {
        // print("\n🖼️ [generatePreview] CALLED (refreshHistograms: \(refreshHistograms))")
        
        guard let image = self.selectedImage else {
            // print("   ⚠️ No image selected")
            return
        }
        
        // print("   📸 Image: \(image.url.lastPathComponent)")
        // print("   ⚙️ Settings: \(image.settings.method)")
        
        self.isLoadingPreview = true
        self.previewError = nil
        self.currentPreview = nil
        self.clippingStats = nil
        
        do {
            // print("   → Generating preview from processor...")
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
            // print("   ✅ Preview generated: \(Int(preview.size.width))x\(Int(preview.size.height))")
            
            //            if let s = self.clippingStats {
            //                print("   📊 Clipping: \(s.clipped)/\(s.total) = \(String(format: "%.2f", Double(s.clipped) / Double(s.total) * 100))%")
            //            }
            
        } catch {
            self.isLoadingPreview = false
            self.previewError = error.localizedDescription
            self.currentPreview = nil
            self.clippingStats = nil
            // print("   ❌ Preview failed: \(error.localizedDescription)")
        }
        
        // Generate histograms only if requested.
        if refreshHistograms {
            // print("   → Now calling generateHistograms()...")
            await generateHistograms()
        } else {
            // print("   ⏭️ Skipping histogram generation (refreshHistograms=false)")
        }
        
        // print("   🏁 generatePreview() completed\n")
    }
    
    /// Refreshes the preview (called when the user changes settings manually).
    /// Also regenerates histograms because tone-mapping settings changed.
    func refreshPreview() {
        Task {
            await generatePreview(refreshHistograms: true)
        }
    }
    
    /// Refreshes the preview without regenerating histograms.
    /// Used for the `showClippedOverlay` toggle (visual overlay only).
    func refreshPreviewOnly() {
        // print("\n🎨 [refreshPreviewOnly] CALLED - overlay toggle")
        
        guard let image = self.selectedImage else {
            // print("   ⚠️ No image selected")
            return
        }
        
        // Ask the processor for a preview that matches the current overlay setting.
        Task {
            do {
                // print("   → Getting preview with current overlay setting...")
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
                // print("   ✅ Preview updated (overlay toggled)")
                
            } catch {
                // print("   ❌ Preview refresh failed: \(error)")
            }
        }
    }
    
    /// Refreshes the preview using a debounce timer (for auto-refresh).
    /// Histograms are refreshed after the preview completes.
    func debouncedRefreshPreview() {
        // print("\n⏱️ [debouncedRefreshPreview] CALLED")
        
        // Cancella task precedente
        if refreshTask != nil {
            // print("   🔄 Cancelling previous refresh task")
            refreshTask?.cancel()
        }
        
        // Feedback immediato
        isLoadingPreview = true
        // print("   ⏳ isLoadingPreview = true, starting debounce timer (\(refreshDebounceInterval)s)...")
        
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(Int(refreshDebounceInterval * 1000)))
            guard !Task.isCancelled else {
                // print("   ❌ Debounce task cancelled (user still changing settings)")
                return
            }
            
            // print("   ✅ Debounce timer expired, calling generatePreview()...")
            // generatePreview(refreshHistograms: true) triggers generateHistograms() afterwards.
            await generatePreview(refreshHistograms: true)
        }
    }
    
    // MARK: - Histograms
    
    /// Generates histograms for the selected image (HDR input and SDR output).
    /// - HDR histogram: computed from the source image (can be cached).
    /// - SDR histogram: reflects tone-mapping parameters (currently recomputed).
    func generateHistograms() async {
        // print("\n🎨 [generateHistograms] CALLED")
        
        guard let image = selectedImage else {
            // print("   ⚠️ No image selected, clearing histograms")
            self.hdrHistogram = nil
            self.sdrHistogram = nil
            return
        }
        
        // print("   📸 Image: \(image.url.lastPathComponent)")
        // print("   ⚙️ Method: \(image.settings.method)")
        
        // Cancel any in-flight histogram generation task.
        if histogramTask != nil {
            // print("   🔄 Cancelling previous histogram task")
            histogramTask?.cancel()
        }
        
        self.isLoadingHistograms = true
        // print("   ⏳ isLoadingHistograms = true")
        
        histogramTask = Task {
            // print("   🚀 Histogram task started")
            
            do {
                // HDR histogram: can be cached after the first generation (the source image doesn't change).
                // print("   → Calculating HDR histogram (may use cache)...")
                let hdrHist = try await processor.histogramForHDRInput(url: image.url)
                // print("   ✅ HDR histogram done: \(hdrHist.xCenters.count) bins")
                
                guard !Task.isCancelled else {
                    // print("   ❌ Task cancelled after HDR")
                    return
                }
                
                // SDR histogram: recomputed because tone-mapping parameters may change.
                // print("   → Calculating SDR histogram (always fresh, no cache)...")
                let sdrHist = try await processor.histogramForSDROutput(image: image)
                // print("   ✅ SDR histogram done: \(sdrHist.xCenters.count) bins")
                
                guard !Task.isCancelled else {
                    // print("   ❌ Task cancelled after SDR")
                    return
                }
                
                // Update both histograms together (single UI update).
                // print("   → Updating UI with new histograms...")
                self.hdrHistogram = hdrHist
                self.sdrHistogram = sdrHist
                self.isLoadingHistograms = false
                
                // print("   ✅✅ HISTOGRAMS UPDATED SUCCESSFULLY ✅✅")
                // print("      HDR bins: \(hdrHist.xCenters.count), range: 0..\(Int(hdrHist.centersNit.last ?? 0)) nit")
                // print("      SDR bins: \(sdrHist.xCenters.count), range: 0..\(Int(sdrHist.centersNit.last ?? 0)) nit")
                // print("      isLoadingHistograms = false")
                
            } catch {
                guard !Task.isCancelled else {
                    // print("   ❌ Task cancelled during error handling")
                    return
                }
                
                // print("   ❌❌ HISTOGRAM GENERATION FAILED ❌❌")
                // print("      Error: \(error.localizedDescription)")
                self.hdrHistogram = nil
                self.sdrHistogram = nil
                self.isLoadingHistograms = false
            }
        }
        
        // Aspetta che finisca (non blocca UI perché siamo già async)
        await histogramTask?.value
        // print("   🏁 Histogram task completed\n")
    }
    
    // MARK: - Caching notes
    
    /*
     Caching notes
     
     This view model intentionally does not implement its own caches.
     Any caching is handled by `HDRProcessor`.
     
     Current behavior from this view model:
     - HDR histogram: requested via `histogramForHDRInput(url:)` (processor may cache).
     - SDR histogram: requested via `histogramForSDROutput(image:)` (treated as always fresh here).
     - Preview: requested via `generatePreview(for:)` (processor may cache).
     */
    
    // MARK: - Export
    
    /// Exports the currently selected image.
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
    
    /// Exports all loaded images.
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
    
    /// Performs export for a list of images.
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
