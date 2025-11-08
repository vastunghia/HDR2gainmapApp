import SwiftUI

struct ContentView: View {
    @State private var viewModel = MainViewModel()
    
    var body: some View {
        Group {
            if viewModel.images.isEmpty {
                // Schermata iniziale: folder selection
                FolderSelectionView(viewModel: viewModel)
            } else {
                // Main interface: 3-panel layout
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
    }
}

// MARK: - Folder Selection View

struct FolderSelectionView: View {
    let viewModel: MainViewModel
    
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

struct MainInterfaceView: View {
    let viewModel: MainViewModel
    
    var body: some View {
        HStack(spacing: 0) {  // ← CAMBIATO: usa HStack invece di VStack con overlay
            // Parte sinistra: Preview + Thumbnail bar
            VStack(spacing: 0) {
                // Preview pane (centro)
                PreviewPane(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Divider()
                
                // Thumbnail bar (basso)
                ThumbnailBar(viewModel: viewModel)
                    .frame(height: 140)
            }
            
            Divider()
            
            // Control panel (destra) - ora affiancato, non sovrapposto
            ControlPanel(viewModel: viewModel)
                .frame(width: 300)
        }
        .overlay {
            // Export progress overlay (questo sì che deve stare sopra tutto)
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
