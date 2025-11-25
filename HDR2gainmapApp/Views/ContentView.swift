import SwiftUI

struct ContentView: View {
    @State private var viewModel = MainViewModel()

    var body: some View {
        // Rebinding Observation → abilita $viewModel.* in questa view
        @Bindable var viewModel = viewModel

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
        .onAppear {
            // Se avvii con un’immagine già selezionata, misura subito l’headroom
            if viewModel.selectedImage != nil {
                viewModel.refreshMeasuredHeadroom()
            }
        }
    }
}

// MARK: - Folder Selection View

struct FolderSelectionView: View {
    @Bindable var viewModel: MainViewModel   // ← era `let`, ora osserva i cambi

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
    @Bindable var viewModel: MainViewModel   // ← ok così

    var body: some View {
        HStack(spacing: 0) {
            // Parte sinistra: Preview + Thumbnail bar
            VStack(spacing: 0) {
                PreviewPane(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ThumbnailBar(viewModel: viewModel)
                    .frame(height: 140)
            }

            Divider()

            // Pannello destro: istogrammi + control panel
            VStack(spacing: 0) {
                HistogramPanel(viewModel: viewModel)
                    .frame(height: 140)

                Divider()

                ControlPanel(viewModel: viewModel)
            }
            .frame(width: 300)
        }
        .overlay {
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
