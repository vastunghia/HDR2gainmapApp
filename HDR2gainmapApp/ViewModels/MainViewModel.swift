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

    // Folder the loaded images came from (used as the source path for settings profiles
    // and as the default location of the folder picker on import).
    private(set) var inputFolderURL: URL?

    // IDs of images whose pixel data is currently resident in cache (drives the "bolt" thumbnail
    // badge). Refreshed by a lightweight poll + after each selection.
    private(set) var warmImageIDs: Set<UUID> = []
    
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
    
    // Detailed clipping statistics
    var detailedClippingStats: HDRProcessor.DetailedClippingStats?
    
    // Show legend window
    var showLegendWindow = false {
        didSet {
            if showLegendWindow {
                showLegendWindowNative()
            } else {
                hideLegendWindowNative()
            }
        }
    }
    
    // Native window controller
    private var legendWindowController: ClippingLegendWindowController?
    
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

    // Background pre-load of the images adjacent to the current selection.
    private var prefetchTask: Task<Void, Never>?

    // Periodic poll that keeps `warmImageIDs` in sync with the cache (catches evictions too).
    private var cacheStatusTask: Task<Void, Never>?
    
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
    ///
    /// When `profile` is supplied, each entry's settings are applied to the matching image
    /// (matched by `url.lastPathComponent`). Returns the list of profile file names that had
    /// no match in the folder, so the caller can warn about missing images.
    @discardableResult
    private func loadImagesFromFolder(_ folderURL: URL, applying profile: SettingsProfile? = nil) async -> [String] {
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
                return []
            }

            // Create HDRImage objects without triggering thumbnail generation yet.
            self.images = pngFiles.map { HDRImage(url: $0, loadThumbnailImmediately: false) }
            self.inputFolderURL = folderURL

            // Apply an imported profile, collecting file names with no match in this folder.
            var missing: [String] = []
            if let profile {
                let imagesByName = Dictionary(
                    self.images.map { ($0.url.lastPathComponent, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                for entry in profile.images {
                    if let image = imagesByName[entry.fileName] {
                        image.settings.applyCoreDTO(entry.settings)
                    } else {
                        missing.append(entry.fileName)
                    }
                }
            }

            // Warn about missing images right away — before the (slow) first-preview and
            // thumbnail work below — so the alert appears promptly instead of seconds later.
            if !missing.isEmpty {
                let list = missing.joined(separator: "\n• ")
                self.errorMessage = "Imported settings, but these images from the profile were not found in the folder:\n\n• \(list)"
                self.showError = true
                await Task.yield()  // let SwiftUI present the alert before the heavy work starts
            }

            // Keep the thumbnail cache badges in sync from now on.
            startCacheStatusPolling()

            // Auto-select the first image.
            if let firstImage = self.images.first {
                await self.selectImage(firstImage)
            }

            // Start thumbnail generation in order (throttled).
            await loadThumbnailsInOrder()

            return missing

        } catch {
            self.errorMessage = "Failed to load images: \(error.localizedDescription)"
            self.showError = true
            return []
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
        
        let tTotal = Prof.tic()
        let file = image.url.lastPathComponent
        defer { Prof.toc("selectImage TOTAL [\(file)]", tTotal) }

        // A new selection takes priority over any in-flight background prefetch.
        prefetchTask?.cancel()

        // Switch selection (triggers a headroom refresh via `didSet`).
        self.selectedImage = image

        // Reset previous state
        self.previewError = nil
        self.currentPreview = nil
        self.clippingStats = nil

        // Generate the preview first.
        let tPrev = Prof.tic()
        await generatePreview(for: image, refreshHistograms: false)
        Prof.toc("selectImage.generatePreview [\(file)]", tPrev)

        // Hide the "new image" spinner after the preview is ready; histograms run afterwards.
        self.isLoadingNewImage = false

        // Generate histograms afterwards (keeps the selection UI feeling snappy).
        let tHist = Prof.tic()
        await generateHistograms()
        Prof.toc("selectImage.generateHistograms [\(file)]", tHist)

        // Now that the foreground work is done, warm the neighbors in the background.
        schedulePrefetch(around: image)

        // Reflect the freshly-cached image (and any evictions) in the thumbnail badges.
        refreshCacheStatus()

        // Debug: Print cache stats
        // processor.printCacheStats()

    }

    // MARK: - Keyboard / sequential navigation

    /// Selects an image the way a thumbnail tap does: show the loading state, clear histograms,
    /// let SwiftUI render, then load. Shared by the thumbnail tap and the arrow-key navigation.
    func userSelect(_ image: HDRImage) {
        Task { @MainActor in
            isLoadingNewImage = true
            hdrHistogram = nil
            sdrHistogram = nil

            // Give SwiftUI a chance to render the loading state before heavy work starts.
            try? await Task.sleep(for: .milliseconds(1))

            await selectImage(image)
        }
    }

    /// Moves the selection by `offset` positions in `images`, stopping at the edges (no wrap).
    func advanceSelection(by offset: Int) {
        guard let current = selectedImage,
              let idx = images.firstIndex(where: { $0.id == current.id }) else { return }
        let target = idx + offset
        guard images.indices.contains(target) else { return }   // stop at the edges
        userSelect(images[target])
    }

    // MARK: - Cache status (thumbnail "bolt" badge)

    /// Recomputes which images are resident in cache and publishes the result only when it changes
    /// (so stable state causes no thumbnail redraws).
    func refreshCacheStatus() {
        var warm = Set<UUID>()
        for img in images where processor.isLoaded(url: img.url) {
            warm.insert(img.id)
        }
        if warm != warmImageIDs {
            warmImageIDs = warm
        }
    }

    /// Starts a lightweight poll that keeps `warmImageIDs` current, including cache evictions.
    private func startCacheStatusPolling() {
        cacheStatusTask?.cancel()
        cacheStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshCacheStatus()
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
    }

    /// Pre-warms the caches (raw bytes, headroom, percentile CDF, preview) for the images adjacent
    /// to `image` — next first, then previous — on a low-priority, cancellable background task.
    /// Lets sequential navigation through the thumbnail bar feel near-instant without slowing down
    /// the user's work on the current image.
    private func schedulePrefetch(around image: HDRImage) {
        prefetchTask?.cancel()

        guard let index = images.firstIndex(where: { $0.id == image.id }) else { return }

        // Snapshot the neighbors' settings on the main actor into Sendable params.
        var jobs: [HDRProcessor.PreviewParams] = []
        if index + 1 < images.count {
            let n = images[index + 1]
            jobs.append(processor.previewParams(url: n.url, settings: n.settings))
        }
        if index - 1 >= 0 {
            let p = images[index - 1]
            jobs.append(processor.previewParams(url: p.url, settings: p.settings))
        }
        guard !jobs.isEmpty else { return }

        prefetchTask = Task(priority: .utility) { [processor] in
            for job in jobs {
                if Task.isCancelled { return }
                await processor.prewarm(params: job)
            }
        }
    }

    func refreshMeasuredHeadroom() {
        guard let url = self.selectedImage?.url else { return }
        let file = url.lastPathComponent
        Task {
            // Measure headroom off the main actor: on a cold cache this reads from disk and runs
            // a Metal/CPU luminance scan, which must not block the UI.
            let tHead = Prof.tic()
            let raw = await Task.detached(priority: .userInitiated) { [processor] in
                processor.getHeadroomForImage(url: url)
            }.value
            Prof.toc("refreshHeadroom.getHeadroom [\(file)]", tHead)

            // Ignore if the selection changed while measuring.
            guard self.selectedImage?.url == url else { return }
            self.measuredHeadroomRaw = raw
            self.measuredHeadroom = max(1.0, raw)

            // Warm up the percentile lookup table so the histogram headroom indicator can update in
            // real time while the user drags the Percentile slider (preview generation is debounced).
            let tCDF = Prof.tic()
            let _ = await self.processor.prewarmPercentileCDF(url: url)
            Prof.toc("refreshHeadroom.prewarmCDF [\(file)]", tCDF)
            guard self.selectedImage?.url == url else { return }
            self.percentileHeadroomCacheGeneration &+= 1
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
    func generatePreview(
        for image: HDRImage,
        refreshHistograms: Bool = true
    ) async {
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
            let preview = try await processor.generatePreview(for: image) { [weak self] clipped, total, detailedStats in
                Task { @MainActor in
                    if total > 0 {
                        self?.clippingStats = ClippingStats(clipped: clipped, total: total)
                        self?.detailedClippingStats = detailedStats
                    } else {
                        self?.clippingStats = nil
                        self?.detailedClippingStats = nil
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
    //    func refreshPreview() {
    //        Task {
    //            await generatePreview(refreshHistograms: true)
    //        }
    //    }
    
    /// Refreshes the preview without regenerating histograms.
    /// Used for the `showClippedOverlay` toggle (visual overlay only).
    func refreshPreviewOnly() {
        guard let image = self.selectedImage else {
            return
        }
        
        Task {
            do {
                let preview = try await processor.generatePreview(for: image) { [weak self] clipped, total, detailedStats in  // ✅ Added detailedStats
                    Task { @MainActor in
                        if total > 0 {
                            self?.clippingStats = ClippingStats(clipped: clipped, total: total)
                            self?.detailedClippingStats = detailedStats  // ✅ Store detailed stats
                        } else {
                            self?.clippingStats = nil
                            self?.detailedClippingStats = nil
                        }
                    }
                }
                
                self.currentPreview = preview
            } catch {
                // Handle error
            }
        }
    }
    
    /// Refreshes the preview using a debounce timer (for auto-refresh).
    /// Histograms are refreshed after the preview completes.
    func debouncedRefreshPreview() {
        // print("\n⏱️ [debouncedRefreshPreview] CALLED")
        
        if refreshTask != nil {
            // print("   🔄 Cancelling previous refresh task")
            refreshTask?.cancel()
        }
        
        // Immediate feedback
        isLoadingPreview = true
        // print("   ⏳ isLoadingPreview = true, starting debounce timer (\(refreshDebounceInterval)s)...")
        
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(Int(refreshDebounceInterval * 1000)))
            guard !Task.isCancelled else {
                // print("   ❌ Debounce task cancelled (user still changing settings)")
                return
            }
            
            // ✅ Check that selectedImage exists
            guard let image = self.selectedImage else {
                self.isLoadingPreview = false
                return
            }
            
            // print("   ✅ Debounce timer expired, calling generatePreview()...")
            // generatePreview(refreshHistograms: true) triggers generateHistograms() afterwards.
            await generatePreview(for: image, refreshHistograms: true)
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

        // DIAGNOSTIC: measures how long the main-actor Task waits before its body starts running
        // (i.e. main-actor scheduling latency), to explain the ~430 ms gap in the warm case.
        let tEntry = Prof.tic()

        histogramTask = Task {
            // print("   🚀 Histogram task started")
            Prof.toc("genHist.taskStartLatency [\(image.url.lastPathComponent)]", tEntry)
            let tBody = Prof.tic()
            defer { Prof.toc("genHist.body [\(image.url.lastPathComponent)]", tBody) }

            do {
                let file = image.url.lastPathComponent
                // HDR histogram: can be cached after the first generation (the source image doesn't change).
                // print("   → Calculating HDR histogram (may use cache)...")
                let tHDR = Prof.tic()
                let hdrHist = try await processor.histogramForHDRInput(url: image.url)
                Prof.toc("hist.HDR [\(file)]", tHDR)
                // print("   ✅ HDR histogram done: \(hdrHist.xCenters.count) bins")

                guard !Task.isCancelled else {
                    // print("   ❌ Task cancelled after HDR")
                    return
                }

                // SDR histogram: recomputed because tone-mapping parameters may change.
                // Snapshot the live settings on the main actor before the off-main compute.
                // print("   → Calculating SDR histogram (always fresh, no cache)...")
                let sdrParams = processor.previewParams(url: image.url, settings: image.settings)
                let tInter = Prof.tic()
                let sdrHist = try await processor.histogramForSDROutput(params: sdrParams)
                Prof.toc("hist.SDR [\(file)]", tInter)
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
    
    // MARK: - Settings Profile (export / import)

    /// Exports the per-image tone-mapping settings of the loaded folder to a JSON profile.
    /// Only images whose core settings differ from the defaults are included.
    func exportSettingsProfile() {
        guard !images.isEmpty else { return }

        let folderURL = inputFolderURL ?? images.first?.url.deletingLastPathComponent()
        let folderPath = folderURL?.path ?? ""
        let folderName = folderURL?.lastPathComponent ?? "images"

        let entries: [ImageSettingsEntry] = images.compactMap { image in
            guard let dto = image.settings.makeCoreDTO() else { return nil }
            return ImageSettingsEntry(fileName: image.url.lastPathComponent, settings: dto)
        }

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "<undetermined>"
        let profile = SettingsProfile(
            schemaVersion: SettingsProfile.currentSchemaVersion,
            appVersion: appVersion,
            exportedAt: Date(),
            folderPath: folderPath,
            folderName: folderName,
            images: entries
        )

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(folderName)-settings.json"
        panel.allowedContentTypes = [UTType.json]
        panel.message = "Choose where to save the tone-mapping settings profile"

        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(profile)
                try data.write(to: url, options: .atomic)
            } catch {
                self.errorMessage = "Failed to save settings profile: \(error.localizedDescription)"
                self.showError = true
            }
        }
    }

    /// Imports a JSON settings profile: lets the user pick the file, then (to satisfy the
    /// sandbox) confirm the source folder via an open panel pre-positioned on the saved path.
    /// Loads the folder, applies the matching settings, and warns about any missing images.
    func importSettingsProfile() {
        let filePanel = NSOpenPanel()
        filePanel.canChooseFiles = true
        filePanel.canChooseDirectories = false
        filePanel.allowsMultipleSelection = false
        filePanel.allowedContentTypes = [UTType.json]
        filePanel.message = "Choose a tone-mapping settings profile to import"

        filePanel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let fileURL = filePanel.url else { return }

            let profile: SettingsProfile
            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                profile = try decoder.decode(SettingsProfile.self, from: data)
            } catch {
                self.errorMessage = "Failed to read settings profile: \(error.localizedDescription)"
                self.showError = true
                return
            }

            guard profile.schemaVersion <= SettingsProfile.currentSchemaVersion else {
                self.errorMessage = "This settings profile was created by a newer version of the app and can't be read. Please update the app."
                self.showError = true
                return
            }

            // Confirm the source folder (grants sandbox access), defaulting to the saved path.
            let folderPanel = NSOpenPanel()
            folderPanel.canChooseFiles = false
            folderPanel.canChooseDirectories = true
            folderPanel.allowsMultipleSelection = false
            folderPanel.message = "Confirm the folder containing the HDR images for this profile"
            if !profile.folderPath.isEmpty {
                folderPanel.directoryURL = URL(fileURLWithPath: profile.folderPath, isDirectory: true)
            }

            folderPanel.begin { [weak self] folderResponse in
                guard let self else { return }
                guard folderResponse == .OK, let folderURL = folderPanel.url else { return }

                // loadImagesFromFolder surfaces the "missing images" warning itself, early.
                Task {
                    await self.loadImagesFromFolder(folderURL, applying: profile)
                }
            }
        }
    }

    // MARK: - Export

    /// Exports the currently selected image.
    func exportCurrentImage() {
        guard let image = selectedImage else { return }
        
        let panel = NSSavePanel()
        
        // Generate filename with suffix
        let baseName = image.fileName
        let suffix = image.settings.filenameSuffix
        let defaultName = FilenameHelper.generateFilename(
            baseName: baseName,
            suffix: suffix,
            extension: "heic"
        )
        
        panel.nameFieldStringValue = defaultName
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
            
            // Gives control to MainActor for one cycle,
            // so that SwiftUI can render the overlay before
            // starting the hard work
            try? await Task.sleep(for: .milliseconds(32))
            
            var isValid = true
            do {
                _ = try await processor.generatePreview(for: image)
            } catch {
                isValid = false
                skipped.append(image.fileName)
            }
            
            // EXPORT
            if isValid {
                // Generate filename with suffix
                let baseName = image.fileName
                let suffix = image.settings.filenameSuffix
                let filename = FilenameHelper.generateFilename(
                    baseName: baseName,
                    suffix: suffix,
                    extension: "heic"
                )
                
                let outputURL = outputFolder.appendingPathComponent(filename)
                
                try? FileManager.default.removeItem(at: outputURL)
                do {
                    try await processor.exportImage(image, to: outputURL)
                    succeeded.append(filename)  // ✅ Use final name
                } catch {
                    failed.append((filename, error.localizedDescription))
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
    
    // MARK: - Clipping Legend / Stats Window
    
    private func showLegendWindowNative() {
        if legendWindowController == nil {
            legendWindowController = ClippingLegendWindowController(viewModel: self)
        }
        legendWindowController?.show()
    }
    
    private func hideLegendWindowNative() {
        legendWindowController?.hide()
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
