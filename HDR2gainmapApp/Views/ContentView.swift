import SwiftUI

/// Root view that switches between the initial folder picker and the main working UI,
/// depending on whether any images have been loaded.
struct ContentView: View {
    @State private var viewModel = MainViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        Group {
            if viewModel.images.isEmpty {
                FolderSelectionView(viewModel: viewModel)
            } else {
                MainInterfaceView(viewModel: viewModel)
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $viewModel.showExportSummary) {
            if let results = viewModel.exportResults {
                ExportSummaryView(results: results)
            }
        }
        .onAppear {
            if viewModel.selectedImage != nil {
                viewModel.refreshMeasuredHeadroom()
            }
        }
        // Expose this window's view model to the menu commands (File ▸ Export/Import Settings),
        // so they act on the frontmost window.
        .focusedSceneValue(\.mainViewModel, viewModel)
    }
}

// MARK: - Folder Selection View

/// Landing screen shown before any images are loaded.
struct FolderSelectionView: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 30) {

            // App icon — use asset from bundle;
            // fallback to symbol SF in case asset is not found
            if let nsImage = NSImage(named: "AppIcon") {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: 256, height: 256)
            } else {
                Image(systemName: "photo.stack")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }

            Text("HDR to Gain Map Converter")
                .font(.largeTitle)
                .fontWeight(.bold)

            VStack(spacing: 12) {
                Text("Select a folder containing HDR PNG/TIFF images to get started")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: {
                    viewModel.selectInputFolder()
                }) {
                    Label("Select Input Folder", systemImage: "folder.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }

            VStack(spacing: 12) {
                Text("…or import previously saved settings for a folder of HDR PNG/TIFF images")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: {
                    viewModel.importSettingsProfile()
                }) {
                    Label("Import Settings", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Open a folder from a saved tone-mapping settings profile")
            }
        }
        .padding(60)
        .frame(minWidth: 600, minHeight: 560)
    }
}

// MARK: - Main Interface View

/// Main working area with a three-panel layout:
/// - Left: preview + thumbnail bar
/// - Right: histograms + controls
struct MainInterfaceView: View {
    @Bindable var viewModel: MainViewModel

    // Persistent state for resizable panel width
    @AppStorage("rightPanelWidth") private var rightPanelWidth: Double = 300
    private let minRightPanelWidth: CGFloat = 300
    private let maxRightPanelWidth: CGFloat = 600

    // Comparison help dialog (shown on entering Compare unless dismissed permanently).
    @AppStorage("hideComparisonHelp") private var hideComparisonHelp = false
    @State private var showComparisonHelp = false

    /// A preview-mode chip — identical in both modes. In Single it's tappable (selected highlighted);
    /// in Compare it's draggable onto a half of the preview.
    @ViewBuilder
    private func previewChip(_ mode: PreviewMode) -> some View {
        let isSelected = !viewModel.isComparison && viewModel.previewMode == mode
        let chip = Text(mode.displayName)
            .font(.caption)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15)))
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
            .contentShape(Capsule())

        if viewModel.isComparison {
            chip.draggable(mode.rawValue)
        } else {
            chip.onTapGesture {
                viewModel.previewMode = mode
                viewModel.handlePreviewModeChange()
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left: preview + thumbnail bar.
                VStack(alignment: .leading, spacing: 0) {
                    // Single vs Compare (double view) switch.
                    Text("Select preview mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                    Picker("Mode", selection: Binding(
                        get: { viewModel.isComparison },
                        set: { on in
                            viewModel.setComparison(on)
                            if on && !hideComparisonHelp { showComparisonHelp = true }
                        }
                    )) {
                        Text("Single").tag(false)
                        Text("Compare").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .disabled(!viewModel.isCurrentImageValid)

                    // Preview selector: the same chips in both modes (no layout jump). In Single a
                    // click selects the view; in Compare each chip is dragged onto a half.
                    Text("Available previews")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                    FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(PreviewMode.allCases, id: \.self) { mode in
                            previewChip(mode)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .disabled(!viewModel.isCurrentImageValid)

                    // Display-headroom readout. Always shown so the layout doesn't jump; the numbers
                    // read "n/a" in the non-EDR views (SDR / Gain Map), where EDR isn't used. It's a
                    // display property, not an image one, so it lives here, not in the MetadataBar.
                    EDRHeadroomIndicator(active: viewModel.isComparison
                        ? (viewModel.comparisonLeftMode.isHDR || viewModel.comparisonRightMode.isHDR)
                        : viewModel.previewMode.isHDR)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 6)

                    Divider()

                    // Preview pane (center).
                    PreviewPane(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    // Thumbnail bar (bottom).
                    ThumbnailBar(viewModel: viewModel)
                        .frame(height: 140)
                }
                .sheet(isPresented: $showComparisonHelp) {
                    ComparisonHelpView(dontShowAgain: $hideComparisonHelp)
                }

                // Draggable divider
                DraggableDivider(
                    panelWidth: Binding(
                        get: { CGFloat(rightPanelWidth) },
                        set: { rightPanelWidth = Double($0) }
                    ),
                    minWidth: minRightPanelWidth,
                    maxWidth: maxRightPanelWidth,
                    totalWidth: geometry.size.width
                )

                // Right: histograms + controls.
                VStack(spacing: 0) {
                    HistogramView(viewModel: viewModel, panelWidth: CGFloat(rightPanelWidth))
                    Divider()
                    ControlPanel(viewModel: viewModel, panelWidth: CGFloat(rightPanelWidth))
                }
                .frame(width: CGFloat(rightPanelWidth))
            }
            .overlay {
                // Export progress overlay (on top of everything).
                if viewModel.isExporting {
                    ExportProgressView(
                        progress: viewModel.exportProgress,
                        currentFile: viewModel.exportCurrentFile
                    )
                }
            }
            // ←/→ navigate to the previous/next image (stops at the edges).
            .arrowKeyNavigation(
                onLeft:  { viewModel.advanceSelection(by: -1) },
                onRight: { viewModel.advanceSelection(by: 1) }
            )
            // M marks / unmarks the current image as "ready for export".
            .markKeyShortcut { viewModel.toggleMarkForSelected() }
        }
    }
}

/// A draggable vertical divider that allows resizing the right panel
struct DraggableDivider: View {
    @Binding var panelWidth: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let totalWidth: CGFloat

    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                // Invisible wider hit area for easier grabbing
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
            )
            .cursor(isDragging ? .resizeLeftRight : .resizeLeftRight)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true

                        // Calculate new width based on drag position
                        // Drag to the left = increase right panel width
                        // Drag to the right = decrease right panel width
                        let newWidth = panelWidth - value.translation.width

                        // Clamp between min and max, and ensure left panel has minimum space
                        let minLeftPanelWidth: CGFloat = 400
                        let maxAllowedWidth = min(maxWidth, totalWidth - minLeftPanelWidth)

                        panelWidth = max(minWidth, min(maxAllowedWidth, newWidth))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

// Extension to change cursor on hover
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active:
                cursor.push()
            case .ended:
                NSCursor.pop()
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
