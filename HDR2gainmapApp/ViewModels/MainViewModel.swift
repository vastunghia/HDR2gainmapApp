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

    // HDR CIImage backing the preview for the HDR views (input / final output), rendered through
    // the EDR Metal path. nil for SDR / gain-map views (those use the NSImage above).
    var currentPreviewCIImage: CIImage?

    // Which view the preview pane shows (SDR tone-map / HDR input / final output / gain map).
    // Global viewing state, not persisted and not part of per-image ProcessingSettings.
    var previewMode: PreviewMode = .sdrTonemapped

    // Pixel-peeping zoom state for the Metal display path. A click zooms toward `zoomAnchorUnit`
    // (top-left unit coordinate in the image); a second click resets to fit.
    var isZoomed = false
    var zoomAnchorUnit = CGPoint(x: 0.5, y: 0.5)

    // Comparison ("double view") state. When `isComparison` is true the preview shows
    // `comparisonLeftMode` and `comparisonRightMode` split at `comparisonSplit` (0…1 of width).
    var isComparison = false
    var comparisonLeftMode: PreviewMode = .hdrInput
    var comparisonRightMode: PreviewMode = .finalOutput
    var comparisonSplit: CGFloat = 0.5
    var currentLeftCIImage: CIImage?
    var currentRightCIImage: CIImage?

    /// Per-image snapshot of the preview pane's view-state, so returning to an image restores how it
    /// was left (Single/Compare, which previews, zoom). Keyed by `HDRImage.id`; absence = never seen.
    private struct PreviewViewState {
        var isComparison: Bool
        var previewMode: PreviewMode
        var comparisonLeftMode: PreviewMode
        var comparisonRightMode: PreviewMode
        var comparisonSplit: CGFloat
        var isZoomed: Bool
        var zoomAnchorUnit: CGPoint
    }
    private var previewStates: [UUID: PreviewViewState] = [:]

    /// Snapshots the live preview view-state (for persisting the outgoing image's).
    private func capturePreviewState() -> PreviewViewState {
        PreviewViewState(isComparison: isComparison, previewMode: previewMode,
                         comparisonLeftMode: comparisonLeftMode, comparisonRightMode: comparisonRightMode,
                         comparisonSplit: comparisonSplit, isZoomed: isZoomed, zoomAnchorUnit: zoomAnchorUnit)
    }

    /// Applies a snapshot back onto the live preview view-state (for restoring an incoming image's).
    private func applyPreviewState(_ s: PreviewViewState) {
        isComparison = s.isComparison
        previewMode = s.previewMode
        comparisonLeftMode = s.comparisonLeftMode
        comparisonRightMode = s.comparisonRightMode
        comparisonSplit = s.comparisonSplit
        isZoomed = s.isZoomed
        zoomAnchorUnit = s.zoomAnchorUnit
    }

    /// Zoom in toward a point given as a top-left unit coordinate (0…1) within the image.
    func zoom(toUnitPoint p: CGPoint) {
        zoomAnchorUnit = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        isZoomed = true
    }

    /// Return to aspect-fit.
    func resetZoom() { isZoomed = false }

    /// Toggles the "ready for export" flag on the selected image (M key).
    func toggleMarkForSelected() { selectedImage?.isMarked.toggle() }

    // MARK: - Comparison (double view)

    /// Switches between single and comparison view, regenerating the preview. The zoom state
    /// (`isZoomed` + `zoomAnchorUnit`) is deliberately preserved across the switch — both surfaces
    /// share it, and the anchor is a mode-independent unit coordinate — so toggling modes keeps the
    /// current zoom level and position.
    func setComparison(_ on: Bool) {
        isComparison = on
        guard let image = self.selectedImage else { return }
        Task { await generatePreview(for: image, refreshHistograms: true) }
    }

    /// Assigns a view to the left or right side (drag & drop) and regenerates just that side.
    func assignComparison(_ mode: PreviewMode, toLeft: Bool) {
        if toLeft { comparisonLeftMode = mode } else { comparisonRightMode = mode }
        guard let image = self.selectedImage else { return }
        Task {
            let img = await renderedCIImage(for: image, mode: mode)
            if toLeft { self.currentLeftCIImage = img } else { self.currentRightCIImage = img }
        }
    }

    /// Renders (if needed) and returns the display CIImage for a view. Shares the existing
    /// preview pipeline & caches via `generatePreview` + `displayPreviewCIImage`.
    private func renderedCIImage(for image: HDRImage, mode: PreviewMode) async -> CIImage? {
        _ = try? await processor.generatePreview(for: image, mode: mode, reportClipping: nil)
        return processor.displayPreviewCIImage(for: image, mode: mode)
    }

    /// Regenerates both comparison sides for the current settings.
    private func refreshComparison(for image: HDRImage) async {
        self.currentLeftCIImage = await renderedCIImage(for: image, mode: comparisonLeftMode)
        self.currentRightCIImage = await renderedCIImage(for: image, mode: comparisonRightMode)
    }

    /// Fetches the SDR-output clipping stats (independent of the shown view) and publishes them.
    private func refreshClippingStats(for image: HDRImage) async {
        let params = processor.previewParams(url: image.url, settings: image.settings)
        if let s = try? await processor.sdrClippingStats(for: params), s.total > 0 {
            self.clippingStats = ClippingStats(clipped: s.clipped, total: s.total)
            self.detailedClippingStats = s.detailed
        } else {
            self.clippingStats = nil
            self.detailedClippingStats = nil
        }
    }

    // UI state
    var isLoadingPreview = false
    var isLoadingNewImage = false
    var isExporting = false
    var exportProgress: Double = 0.0
    var exportCurrentFile: String = ""
    private var exportTask: Task<Void, Never>?

    // Auto tone-mapping (single image + batch)
    var isAutoTuning = false
    var autoTuneProgress: Double = 0.0          // batch only
    var autoTuneCurrentFile: String = ""        // batch only
    var autoTuneNote: String?                   // transient user-facing note (clamps etc.)
    var showAutoTuneConfirmation = false        // batch: some images were hand-tuned
    var autoTuneModifiedCount = 0               // batch: how many of them
    private var autoTuneTask: Task<Void, Never>?
    
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
    
    // Native window controllers
    private var legendWindowController: ClippingLegendWindowController?
    private var tonemapHelpWindowController: TonemapHelpWindowController?
    
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
    
    /// UserDefaults key remembering the last image folder opened (across windows), so the picker
    /// returns there instead of, e.g., a settings-export destination that polluted the shared
    /// "last used" directory of the save panels.
    private static let lastInputFolderKey = "lastInputFolderPath"

    /// Presents a panel to pick the input folder containing HDR PNGs.
    func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select folder containing HDR PNG/TIFF images"

        // Start at the last image folder we opened (this session, else persisted from a prior one),
        // rather than inheriting whatever directory a save panel last used.
        if let path = inputFolderURL?.path ?? UserDefaults.standard.string(forKey: Self.lastInputFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }

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

            let inputExtensions: Set<String> = ["png", "tif", "tiff"]
            let pngFiles = contents.filter { inputExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            guard !pngFiles.isEmpty else {
                self.errorMessage = "No PNG/TIFF files found in selected folder"
                self.showError = true
                return []
            }

            // Create HDRImage objects without triggering thumbnail generation yet.
            self.images = pngFiles.map { HDRImage(url: $0, loadThumbnailImmediately: false) }
            self.inputFolderURL = folderURL
            UserDefaults.standard.set(folderURL.path, forKey: Self.lastInputFolderKey)
            self.previewStates.removeAll() // drop any prior folder's per-image preview view-states
            self.settingsExported = false  // fresh working set (import sets it true afterwards)

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
                        image.isMarked = entry.isMarked ?? false
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

        // Persist the outgoing image's preview view-state before switching away from it.
        if let previous = self.selectedImage {
            previewStates[previous.id] = capturePreviewState()
        }

        // Switch selection (triggers a headroom refresh via `didSet`).
        self.selectedImage = image

        // Reset previous state
        self.previewError = nil
        self.currentPreview = nil
        self.currentLeftCIImage = nil
        self.currentRightCIImage = nil
        self.clippingStats = nil
        self.autoTuneNote = nil // the note describes the previous image's auto-tune

        // Restore the preview view-state if this image was seen before; otherwise present the default
        // for a never-seen image: Single, SDR-tonemapped, clipping mask on, no zoom (divider centered).
        if let saved = previewStates[image.id] {
            applyPreviewState(saved)
        } else {
            applyPreviewState(PreviewViewState(
                isComparison: false,
                previewMode: .sdrTonemapped,
                comparisonLeftMode: comparisonLeftMode,
                comparisonRightMode: comparisonRightMode,
                comparisonSplit: 0.5,
                isZoomed: false,
                zoomAnchorUnit: CGPoint(x: 0.5, y: 0.5)
            ))
            image.settings.showClippedOverlay = true
        }

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

        // Comparison ("double view") path: regenerate both sides + SDR stats; skip the single render.
        if isComparison {
            self.isLoadingPreview = true
            self.previewError = nil
            await refreshComparison(for: image)
            await refreshClippingStats(for: image)
            self.isLoadingPreview = false
            if refreshHistograms { await generateHistograms() }
            return
        }

        // print("   📸 Image: \(image.url.lastPathComponent)")
        // print("   ⚙️ Settings: \(image.settings.method)")
        
        self.isLoadingPreview = true
        self.previewError = nil
        self.currentPreview = nil
        self.currentPreviewCIImage = nil
        self.clippingStats = nil
        self.detailedClippingStats = nil

        let mode = self.previewMode

        do {
            // print("   → Generating preview from processor...")
            let preview = try await processor.generatePreview(for: image, mode: mode) { [weak self] clipped, total, detailedStats in
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
            // The CIImage shown by the Metal display path (now used for all views: it activates EDR
            // for HDR content and enables pixel-peeping zoom uniformly).
            self.currentPreviewCIImage = processor.displayPreviewCIImage(for: image, mode: mode)
            self.isLoadingPreview = false
            // print("   ✅ Preview generated: \(Int(preview.size.width))x\(Int(preview.size.height))")

            // Clipping stats describe the SDR output, so the legend & clipped-pixel count stay
            // available in every view. In SDR mode they arrive via the callback above; in the other
            // views, compute them here (cache-shared with the SDR render).
            if mode != .sdrTonemapped {
                let params = processor.previewParams(url: image.url, settings: image.settings)
                if let s = try? await processor.sdrClippingStats(for: params), s.total > 0 {
                    self.clippingStats = ClippingStats(clipped: s.clipped, total: s.total)
                    self.detailedClippingStats = s.detailed
                }
            }
            
            //            if let s = self.clippingStats {
            //                print("   📊 Clipping: \(s.clipped)/\(s.total) = \(String(format: "%.2f", Double(s.clipped) / Double(s.total) * 100))%")
            //            }
            
        } catch {
            self.isLoadingPreview = false
            self.previewError = error.localizedDescription
            self.currentPreview = nil
            self.currentPreviewCIImage = nil
            self.clippingStats = nil
            // print("   ❌ Preview failed: \(error.localizedDescription)")
        }
        
        // Generate histograms only if requested. They describe the SDR output and HDR input, so
        // they must track tone-mapping changes regardless of which preview view is shown (e.g.
        // moving a Source Headroom slider while viewing the Gain Map still changes the SDR output).
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
        
        let mode = self.previewMode

        Task {
            do {
                let preview = try await processor.generatePreview(for: image, mode: mode) { [weak self] clipped, total, detailedStats in  // ✅ Added detailedStats
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
                self.currentPreviewCIImage = processor.displayPreviewCIImage(for: image, mode: mode)
            } catch {
                // Handle error
            }
        }
    }

    /// Regenerates the preview when the user switches the view mode (segmented picker).
    /// Histograms are not refreshed here: switching the view doesn't change the tone-mapping
    /// parameters, so the current histograms already match the SDR output.
    func handlePreviewModeChange() {
        guard let image = self.selectedImage else { return }
        Task {
            await generatePreview(for: image, refreshHistograms: false)
        }
    }
    
    /// Refreshes the preview using a debounce timer (for auto-refresh).
    /// Histograms are refreshed after the preview completes.
    func debouncedRefreshPreview() {
        // print("\n⏱️ [debouncedRefreshPreview] CALLED")

        // Any settings edit funnels through here (ControlPanel onSettingsChange, reset-to-defaults,
        // auto-tune) → the settings now diverge from any exported/imported profile.
        markSettingsDirty()

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

    /// True once the current settings have been written to (or loaded from) a JSON profile, and not
    /// touched since. Starts false, set true after a successful export/import, reset to false on any
    /// settings change (`markSettingsDirty`). Drives the "export before closing?" prompt: that prompt
    /// only appears when this is false. See [[SessionTerminationGuard]].
    private(set) var settingsExported = false

    /// Marks the in-memory settings as diverged from any exported/imported profile.
    func markSettingsDirty() { settingsExported = false }

    /// Whether closing the session should offer to export: there is at least one non-default image
    /// and those settings have not been exported/imported since the last change.
    func hasUnsavedSettingsToExport() -> Bool {
        !settingsExported && images.contains { $0.settings.isModifiedFromDefaults }
    }

    /// Exports the per-image tone-mapping settings of the loaded folder to a JSON profile.
    /// Only images whose core settings differ from the defaults are included.
    /// `completion` reports whether a file was actually written (false on cancel/failure) — used by
    /// the close/quit guard to decide whether to proceed.
    func exportSettingsProfile(completion: ((Bool) -> Void)? = nil) {
        guard !images.isEmpty else { completion?(false); return }

        let folderURL = inputFolderURL ?? images.first?.url.deletingLastPathComponent()
        let folderPath = folderURL?.path ?? ""
        let folderName = folderURL?.lastPathComponent ?? "images"

        let entries: [ImageSettingsEntry] = images.compactMap { image in
            let dto = image.settings.makeCoreDTO()
            // Persist an entry when the settings differ from defaults OR the image is marked
            // (so a marked-but-default image still round-trips its flag).
            guard dto != nil || image.isMarked else { return nil }
            return ImageSettingsEntry(fileName: image.url.lastPathComponent,
                                      settings: dto ?? CoreSettingsDTO(),
                                      isMarked: image.isMarked ? true : nil)
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
            guard let self else { completion?(false); return }
            guard response == .OK, let url = panel.url else { completion?(false); return }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(profile)
                try data.write(to: url, options: .atomic)
                self.settingsExported = true
                completion?(true)
            } catch {
                self.errorMessage = "Failed to save settings profile: \(error.localizedDescription)"
                self.showError = true
                completion?(false)
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
                    // The in-memory settings now correspond to the just-imported profile on disk.
                    self.settingsExported = true
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
                self.exportTask = Task {
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
                self.exportTask = Task {
                    await self.performExport(images: self.images, outputFolder: url)
                }
            }
        }
    }
    
    /// Cancels an in-progress batch export (finishes the image currently being written, then stops).
    func cancelExport() { exportTask?.cancel() }

    /// Performs export for a list of images.
    private func performExport(images: [HDRImage], outputFolder: URL) async {
        isExporting = true
        exportProgress = 0.0

        var succeeded: [String] = []
        var failed: [(String, String)] = []
        var skipped: [String] = []
        var cancelled = false

        let totalCount = images.count
        guard totalCount > 0 else {
            isExporting = false
            exportResults = ExportResults(total: 0, succeeded: [], failed: [], skipped: [])
            showExportSummary = true
            return
        }

        for (index, image) in images.enumerated() {
            // Stop before starting the next image if the user cancelled.
            if Task.isCancelled { cancelled = true; break }

            exportCurrentFile = image.fileName

            // Gives control to MainActor for one cycle,
            // so that SwiftUI can render the overlay before
            // starting the hard work
            try? await Task.sleep(for: .milliseconds(32))

            // Generate filename with suffix
            let baseName = image.fileName
            let suffix = image.settings.filenameSuffix
            let filename = FilenameHelper.generateFilename(
                baseName: baseName,
                suffix: suffix,
                extension: "heic"
            )

            let outputURL = outputFolder.appendingPathComponent(filename)

            // EXPORT. `exportImage` performs the same load + tone-map the old validation pass did,
            // so we attempt it directly instead of pre-rendering a (discarded) preview. An input
            // that isn't a valid HDR image throws before any file is written → reported as skipped;
            // anything else that goes wrong during encoding is a genuine failure.
            try? FileManager.default.removeItem(at: outputURL)
            do {
                try await processor.exportImage(image, to: outputURL)
                succeeded.append(filename)  // ✅ Use final name
            } catch ProcessingError.cannotReadHDR, ProcessingError.invalidColorSpace(_) {
                skipped.append(image.fileName)
            } catch {
                failed.append((filename, error.localizedDescription))
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
            skipped: skipped,
            cancelled: cancelled
        )
        showExportSummary = true
    }
    
    // MARK: - Auto tone-mapping

    /// Searches the optimal source headroom for one image and writes it into its active method.
    /// Returns a user-facing note (nil when the result needs no caveat).
    private func autoTune(image: HDRImage) async throws -> String? {
        let tolerance = HDRProcessor.autoClipToleranceFraction()
        let targetHeadroom = image.settings.targetHeadroom ?? 1.0
        let result = try await processor.findAutoSourceHeadroom(
            url: image.url,
            targetHeadroom: targetHeadroom,
            tolerance: tolerance
        )
        let outcome = await processor.applyAutoSourceHeadroom(result.sourceHeadroom, to: image.settings, url: image.url)
        if !result.metTolerance {
            return "Tolerance not reachable; kept the measured headroom"
        }
        return outcome.note
    }

    /// "Auto" button: tune the currently selected image.
    func autoTuneSelectedImage() {
        guard let image = selectedImage, isCurrentImageValid, !isExporting, !isAutoTuning else { return }
        isAutoTuning = true
        autoTuneNote = nil
        autoTuneTask = Task {
            defer { isAutoTuning = false }
            do {
                autoTuneNote = try await autoTune(image: image)
                debouncedRefreshPreview()
            } catch is CancellationError {
                // user cancelled: nothing to report
            } catch {
                errorMessage = "Auto tone-mapping failed: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    /// "Auto all" button: tune every loaded image. Asks for confirmation first when some images
    /// were already hand-tuned (the dialog then calls `startAutoTuneAll(includeModified:)`).
    func autoTuneAllImages() {
        guard !images.isEmpty, !isExporting, !isAutoTuning else { return }
        let modified = images.filter { $0.settings.isModifiedFromDefaults }.count
        if modified > 0 {
            autoTuneModifiedCount = modified
            showAutoTuneConfirmation = true
        } else {
            startAutoTuneAll(includeModified: true)
        }
    }

    /// Main-actor accumulator for batch progress/failures, shared with the `autoSearchBatch`
    /// callback (which is main-actor-isolated, so all access stays on one actor).
    private final class AutoBatchAccum: @unchecked Sendable {
        var failures: [String] = []
        var completed = 0
    }

    func startAutoTuneAll(includeModified: Bool) {
        guard !isAutoTuning else { return }
        let targets = includeModified ? images : images.filter { !$0.settings.isModifiedFromDefaults }
        guard !targets.isEmpty else { return }
        isAutoTuning = true
        autoTuneNote = nil
        autoTuneProgress = 0.0

        let tolerance = HDRProcessor.autoClipToleranceFraction()
        let jobs = targets.map { (url: $0.url, targetHeadroom: $0.settings.targetHeadroom ?? Float(1.0)) }
        let total = targets.count
        let concurrency = HDRProcessor.defaultAutoConcurrency()
        let accum = AutoBatchAccum()

        autoTuneTask = Task {
            defer {
                isAutoTuning = false
                autoTuneCurrentFile = ""
            }
            // Each worker uses its own CIContext + histogram (see HDRProcessor.autoSearchBatch), so
            // the images process in parallel instead of serializing on the shared singletons.
            await processor.autoSearchBatch(jobs: jobs, tolerance: tolerance, concurrency: concurrency) { index, _, result in
                let image = targets[index]
                switch result {
                case .success(let r):
                    _ = await self.processor.applyAutoSourceHeadroom(r.sourceHeadroom, to: image.settings, url: image.url)
                case .failure(let error):
                    if !(error is CancellationError) { accum.failures.append(image.fileName) }
                }
                accum.completed += 1
                self.autoTuneProgress = Double(accum.completed) / Double(total)
                self.autoTuneCurrentFile = image.fileName
            }
            if !accum.failures.isEmpty {
                errorMessage = "Auto tone-mapping failed for: \(accum.failures.joined(separator: ", "))"
                showError = true
            }
            // The selected image's settings may have changed under the current preview.
            if let image = selectedImage, targets.contains(where: { $0.url == image.url }) {
                debouncedRefreshPreview()
            }
        }
    }

    func cancelAutoTune() {
        autoTuneTask?.cancel()
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

    // MARK: - Tone-Mapping Help Window

    /// Opens (or re-focuses) the non-modal tone-mapping help panel.
    func showTonemapHelp() {
        if tonemapHelpWindowController == nil {
            tonemapHelpWindowController = TonemapHelpWindowController()
        }
        tonemapHelpWindowController?.show()
    }

}

// MARK: - Export Results

struct ExportResults {
    let total: Int
    let succeeded: [String]
    let failed: [(fileName: String, reason: String)]
    let skipped: [String]
    var cancelled: Bool = false

    var successCount: Int { succeeded.count }
    var failedCount: Int { failed.count }
    var skippedCount: Int { skipped.count }
    /// Images not reached because the batch was cancelled.
    var notProcessedCount: Int { max(0, total - successCount - failedCount - skippedCount) }
}
