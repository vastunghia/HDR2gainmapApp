import SwiftUI

/// Root view that switches between the initial folder picker and the main working UI,
/// depending on whether any images have been loaded.
struct ContentView: View {
    @State private var viewModel = MainViewModel()
    
    var body: some View {
        // Bind Observation to enable `$viewModel.*` bindings in this view.
        @Bindable var viewModel = viewModel
        
        Group {
            if viewModel.images.isEmpty {
                // Initial screen: folder selection.
                FolderSelectionView(viewModel: viewModel)
            } else {
                // Main UI: three-panel layout.
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
            // If the app launches with a preselected image, measure headroom immediately.
            if viewModel.selectedImage != nil {
                viewModel.refreshMeasuredHeadroom()
            }
        }
    }
}

// MARK: - Folder Selection View

/// Landing screen shown before any images are loaded.
struct FolderSelectionView: View {
    @Bindable var viewModel: MainViewModel
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "photo.stack")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            
            Text("HDR to Gain Map Converter")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Select a folder containing HDR PNG images to get started")
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
        }
        .padding(60)
        .frame(minWidth: 600, minHeight: 400)
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
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left: preview + thumbnail bar.
                VStack(spacing: 0) {
                    // Preview pane (center).
                    PreviewPane(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    Divider()
                    
                    // Thumbnail bar (bottom).
                    ThumbnailBar(viewModel: viewModel)
                        .frame(height: 140)
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
