import SwiftUI

/// Shows the current image preview along with loading/error states and a metadata bar.
struct PreviewPane: View {
    let viewModel: MainViewModel

    /// Pixel-peeping zoom level (percent of actual pixels), set in Preferences.
    @AppStorage("pixelPeepZoomLevel") private var zoomLevel: Int = 200

    /// Drag-to-pan state (only while zoomed). `panStartAnchor` is the anchor at drag start;
    /// `didPan` distinguishes a pan from a plain click (which toggles zoom).
    @State private var panStartAnchor: CGPoint? = nil
    @State private var didPan = false
    @State private var isPanning = false
    private let dragThreshold: CGFloat = 3

    var body: some View {
        VStack(spacing: 0) {
            // Preview image area
            ZStack {
                // Background always visible (not covered by overlay)
                Color(nsColor: .textBackgroundColor)
                
                if let preview = viewModel.currentPreview {
                    // Preview is available - with conditional overlay above
                    GeometryReader { geo in
                        previewContent(preview: preview)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .contentShape(Rectangle())
                            .gesture(
                                // Click toward a point to zoom in / click again to reset; while
                                // zoomed, drag to pan.
                                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                    .onChanged { value in
                                        handleDragChanged(value, in: geo.size)
                                    }
                                    .onEnded { value in
                                        handleDragEnded(value, in: geo.size)
                                    }
                            )
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                updateHoverCursor(phase, in: geo.size)
                            }
                    }
                        .overlay(
                            Group {
                                // Spinner while recalculates preview (no new image loading)
                                if viewModel.isLoadingPreview && !viewModel.isLoadingNewImage {
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .allowsHitTesting(true)
                                        .overlay(
                                            ProgressView()
                                                .controlSize(.large)
                                                .scaleEffect(1.2)
                                                .tint(.white)
                                                .transition(.opacity)
                                        )
                                }
                            }
                        )
                        .overlay(
                            Group {
                                // Dark overlay + spinner while loading new image
                                // LIMITED TO IMAGE
                                if viewModel.isLoadingNewImage {
                                    Color.black.opacity(0.5)
                                        .contentShape(Rectangle())
                                        .allowsHitTesting(true)
                                        .overlay(
                                            VStack(spacing: 12) {
                                                ProgressView()
                                                    .controlSize(.large)
                                                    .scaleEffect(1.5)
                                                    .tint(.white)
                                                Text("Loading image...")
                                                    .font(.caption)
                                                    .foregroundStyle(.white)
                                            }
                                        )
                                        .transition(.opacity)
                                }
                            }
                        )
                    
                } else if viewModel.selectedImage != nil {
                    // No preview yet, but an image is selected (initial state).
                    if viewModel.isLoadingPreview || viewModel.isLoadingNewImage {
                        // Spinner while the preview is being generated.
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                                .scaleEffect(1.2)
                                .tint(.secondary)
                            Text("Loading image...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    } else if let error = viewModel.previewError {
                        // The selected image is not a valid HDR PNG.
                        VStack(spacing: 20) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(.orange)
                            
                            VStack(spacing: 8) {
                                Text("Invalid HDR Image")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                
                                Text(error)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 40)
                                
                                Text("This image cannot be processed or exported. Please ensure it's a valid HDR PNG with Display P3 PQ color space.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 40)
                                    .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // No image selected.
                    VStack(spacing: 16) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Select an image to preview")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Metadata bar
            if let selectedImage = viewModel.selectedImage {
                MetadataBar(image: selectedImage, headroomRaw: viewModel.measuredHeadroomRaw)
                    .id(selectedImage.id)
            }
        }
    }

    /// The image surface: the Metal renderer (all views — activates EDR for HDR and supports zoom),
    /// with a SwiftUI `Image` fallback when Metal/CIImage is unavailable.
    @ViewBuilder
    private func previewContent(preview: NSImage) -> some View {
        if EDRMetalImageView.isSupported, let ciImage = viewModel.currentPreviewCIImage {
            EDRMetalImageView(
                ciImage: ciImage,
                isHDR: viewModel.previewMode.isHDR,
                isZoomed: viewModel.isZoomed,
                zoomAnchorUnit: viewModel.zoomAnchorUnit,
                zoomPercent: zoomLevel
            )
        } else {
            Image(nsImage: preview)
                .resizable()
                .allowedDynamicRange(viewModel.previewMode.isHDR ? .high : .standard)
                .aspectRatio(contentMode: .fit)
        }
    }

    /// The aspect-fit rect (in local points) where the image is drawn, or nil if there's no image.
    /// Same min-scale the renderer uses, so gesture and render stay aligned.
    private func imageDisplayRect(in size: CGSize) -> CGRect? {
        guard let ext = viewModel.currentPreviewCIImage?.extent,
              ext.width > 0, ext.height > 0 else { return nil }
        let scale = min(size.width / ext.width, size.height / ext.height)
        let w = ext.width * scale
        let h = ext.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Image size in pixels, or nil if no image.
    private func imageExtentSize() -> CGSize? {
        guard let ext = viewModel.currentPreviewCIImage?.extent, ext.width > 0, ext.height > 0 else { return nil }
        return CGSize(width: ext.width, height: ext.height)
    }

    /// Clamps the zoom anchor (top-left unit) to the range that keeps the magnified image covering
    /// the viewport — mirroring the renderer's translation clamp, so pan tracks the cursor 1:1.
    /// An axis where the image is smaller than the viewport is centered (0.5).
    private func clampedAnchor(_ a: CGPoint, viewSize: CGSize, imgPx: CGSize) -> CGPoint {
        let scalePts = CGFloat(zoomLevel) / 100   // points per image pixel (backing scale cancels out)
        func clamp1D(_ v: CGFloat, viewLen: CGFloat, imgLen: CGFloat) -> CGFloat {
            let scaledLen = imgLen * scalePts
            guard scaledLen > viewLen else { return 0.5 }
            let half = (viewLen / 2) / scaledLen
            return min(max(v, half), 1 - half)
        }
        return CGPoint(x: clamp1D(a.x, viewLen: viewSize.width, imgLen: imgPx.width),
                       y: clamp1D(a.y, viewLen: viewSize.height, imgLen: imgPx.height))
    }

    private func handleDragChanged(_ value: DragGesture.Value, in size: CGSize) {
        let t = value.translation
        if abs(t.width) > dragThreshold || abs(t.height) > dragThreshold { didPan = true }
        guard viewModel.isZoomed, didPan, let imgPx = imageExtentSize() else { return }
        // Closed-hand "grab" cursor while panning (re-set each move to override hover updates).
        isPanning = true
        NSCursor.closedHand.set()
        let start = panStartAnchor ?? viewModel.zoomAnchorUnit
        if panStartAnchor == nil { panStartAnchor = start }
        // Dragging the image by `t` points moves the centered point the opposite way.
        let scalePts = CGFloat(zoomLevel) / 100
        let raw = CGPoint(x: start.x - t.width / (imgPx.width * scalePts),
                          y: start.y - t.height / (imgPx.height * scalePts))
        viewModel.zoomAnchorUnit = clampedAnchor(raw, viewSize: size, imgPx: imgPx)
    }

    private func handleDragEnded(_ value: DragGesture.Value, in size: CGSize) {
        let wasPan = didPan
        panStartAnchor = nil
        didPan = false
        isPanning = false
        // A click (no real movement) toggles zoom; a pan was already applied in onChanged.
        if !wasPan { handleTap(at: value.location, in: size) }
        // Restore the appropriate magnifier cursor for the (possibly changed) zoom state.
        updateHoverCursor(.active(value.location), in: size)
    }

    /// Click handling: a click in the displayed image zooms toward it; a click while zoomed resets.
    /// `point` is in the preview area's local (top-left) points; `size` is that area's size.
    private func handleTap(at point: CGPoint, in size: CGSize) {
        if viewModel.isZoomed {
            viewModel.resetZoom()
            return
        }
        guard let rect = imageDisplayRect(in: size), rect.contains(point),
              let imgPx = imageExtentSize() else { return }  // letterbox → ignore
        let raw = CGPoint(x: (point.x - rect.minX) / rect.width,
                          y: (point.y - rect.minY) / rect.height)
        viewModel.zoom(toUnitPoint: clampedAnchor(raw, viewSize: size, imgPx: imgPx))
    }

    /// Shows a magnifier cursor over the image: "+" when it can zoom in, "−" when already zoomed.
    private func updateHoverCursor(_ phase: HoverPhase, in size: CGSize) {
        // While actively panning, keep the closed-hand cursor (don't let hover override it).
        if isPanning { return }
        switch phase {
        case .active(let location):
            // When zoomed the image fills the area; otherwise restrict to the fit rect.
            let overImage = viewModel.isZoomed || (imageDisplayRect(in: size)?.contains(location) ?? false)
            if overImage {
                (viewModel.isZoomed ? NSCursor.zoomOut : NSCursor.zoomIn).set()
            } else {
                NSCursor.arrow.set()
            }
        case .ended:
            NSCursor.arrow.set()
        }
    }
}

/// Displays lightweight metadata for the selected HDR image.
struct MetadataBar: View {
    let image: HDRImage
    let headroomRaw: Float
    
    @State private var metadata: ImageMetadata?
    @State private var loadError: Bool = false
    
    var body: some View {
        VStack(spacing: 8) {
            Divider()
            
            if let metadata = metadata {
                HStack(spacing: 20) {
                    if metadata.colorSpace != "Unknown" {
                        MetadataItem(
                            icon: "paintpalette",
                            label: "Color Space",
                            value: metadata.colorSpace
                        )
                    }
                    
                    if metadata.transferFunction != "Unknown" {
                        MetadataItem(
                            icon: "waveform.path",
                            label: "Transfer",
                            value: metadata.transferFunction
                        )
                    } else {
                        MetadataItem(
                            icon: "waveform.path",
                            label: "Transfer",
                            value: metadata.transferFunction,
                            valueColor: .red
                        )
                    }
                    
                    if metadata.width > 0 && metadata.height > 0 {
                        MetadataItem(
                            icon: "rectangle.grid.2x2",
                            label: "Resolution",
                            value: metadata.resolutionString
                        )
                    }
                    
                    if metadata.bitDepth > 0 {
                        MetadataItem(
                            icon: "square.stack.3d.up",
                            label: "Bit Depth",
                            value: metadata.bitDepthString
                        )
                    }
                    
                    MetadataItem(
                        icon: "sun.max",
                        label: "Headroom",
                        value: String(format: "%.1f", headroomRaw) + " (" + String(format: "%.1f", log2(headroomRaw)) + " stops)"
                    )

                    if metadata.fileSize > 0 {
                        MetadataItem(
                            icon: "doc",
                            label: "File Size",
                            value: metadata.fileSizeString
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else if loadError {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Metadata not available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else {
                HStack {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Loading metadata...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: image.id) {  // Keyed by image.id so this runs only when the image changes.
            // This task re-runs only when image.id changes, not on every re-render.
            // print("📋 [MetadataBar.task] Loading metadata for: \(image.fileName)")
            
            metadata = await image.loadMetadata()
            
            if metadata == nil {
                loadError = true
                // print("   ❌ [MetadataBar] Metadata load failed")
            } else {
                // print("   ✅ [MetadataBar] Metadata displayed")
            }
        }
    }
}

// MARK: - Implementation notes

/*
 Rationale:
 - Metadata is loaded via a .task keyed by image.id so it runs only when the selected image changes,
 not on every view re-render (e.g., when headroom updates).
 - HDRImage.loadMetadata() is expected to be fast and cache-friendly (read header + cache results by URL).
 */
// MARK: - EDR Headroom Indicator

/// Live readout of the active screen's EDR headroom (current vs. potential), so it's easy to see
/// whether EDR actually activated. There is no KVO for these `NSScreen` properties, so it polls
/// roughly once per second via `TimelineView`. `current` rises above 1.0 once the system grants
/// headroom (e.g. when the EDR Metal surface is on screen showing HDR content).
struct EDRHeadroomIndicator: View {
    /// When false (SDR / gain-map views) the numbers are shown as "n/a": EDR isn't used there.
    let active: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let screen = NSScreen.main
            let current = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
            let potential = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
            HStack(spacing: 6) {
                Image(systemName: "sun.max.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Display Headroom (current / potential):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if active {
                    HStack(spacing: 4) {
                        headroomValue(current)
                        Text("/").font(.caption).foregroundStyle(.secondary)
                        headroomValue(potential)
                    }
                } else {
                    Text("n/a / n/a")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// One headroom value, e.g. "8.0 (3.0 stops)". Red when there's no headroom (1.0 / 0.0 stops),
    /// green when EDR headroom is available.
    private func headroomValue(_ value: CGFloat) -> some View {
        Text(String(format: "%.1f (%.1f stops)", value, log2(max(value, 1.0))))
            .font(.caption)
            .fontWeight(.medium)
            .monospacedDigit()
            .foregroundStyle(value > 1.01 ? Color.green : Color.red)
    }
}

// MARK: - Metadata Item

/// A compact labeled metadata field (icon + label + value).
struct MetadataItem: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary  // Optional override for the value text color.
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(valueColor)  // Use the custom color if provided.
                    .fontWeight(.medium)
            }
        }
    }
}

#Preview {
    PreviewPane(viewModel: MainViewModel())
        .frame(height: 600)
}

// MARK: - Zoom cursors

extension NSCursor {
    /// Magnifier with a "+" — shown when hovering the un-zoomed image (a click zooms in).
    static let zoomIn = NSCursor.magnifier(symbol: "plus.magnifyingglass")
    /// Magnifier with a "−" — shown when hovering the zoomed image (a click resets to fit).
    static let zoomOut = NSCursor.magnifier(symbol: "minus.magnifyingglass")

    /// Builds a magnifying-glass cursor from an SF Symbol, with a white outline so it stays visible
    /// on both bright and dark image areas. The hotspot sits at the lens center so the user aims the
    /// lens at the detail. Falls back to the arrow cursor if the symbol can't be created.
    private static func magnifier(symbol: String) -> NSCursor {
        let pointSize: CGFloat = 18
        func tinted(_ color: NSColor) -> NSImage? {
            let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }
        guard let black = tinted(.black), let white = tinted(.white) else { return .arrow }

        let pad: CGFloat = 2
        let size = NSSize(width: black.size.width + pad * 2, height: black.size.height + pad * 2)
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        let rect = NSRect(x: pad, y: pad, width: black.size.width, height: black.size.height)
        // White outline: draw the white glyph offset in 8 directions, then the black glyph on top.
        let offsets: [CGVector] = [.init(dx: -1, dy: 0), .init(dx: 1, dy: 0),
                                   .init(dx: 0, dy: -1), .init(dx: 0, dy: 1),
                                   .init(dx: -1, dy: -1), .init(dx: 1, dy: 1),
                                   .init(dx: -1, dy: 1), .init(dx: 1, dy: -1)]
        for o in offsets {
            white.draw(in: rect.offsetBy(dx: o.dx, dy: o.dy), from: .zero, operation: .sourceOver, fraction: 1)
        }
        black.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()

        // The lens (circle) sits in the upper-left of the symbol; aim the hotspot there.
        let hotSpot = NSPoint(x: pad + black.size.width * 0.40, y: pad + black.size.height * 0.40)
        return NSCursor(image: canvas, hotSpot: hotSpot)
    }
}
