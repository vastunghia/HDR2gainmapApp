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
    
    var body: some View {
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
            
            Divider()
            
            // Right: histograms + controls.
            VStack(spacing: 0) {
                HistogramView(viewModel: viewModel)
                Divider()
                ControlPanel(viewModel: viewModel)
            }
            .frame(width: 300)
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

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
