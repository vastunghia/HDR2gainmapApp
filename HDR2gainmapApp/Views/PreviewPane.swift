import SwiftUI

struct PreviewPane: View {
    let viewModel: MainViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Preview image area
            ZStack {
                if let preview = viewModel.currentPreview {
                    // Preview disponibile
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    // Loading overlay: solo spinner, nessun velo
                    if viewModel.isLoadingPreview {
                        // overlay trasparente che blocca l’input
                        Rectangle()
                            .fill(Color.clear)
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
                } else if viewModel.selectedImage != nil {
                    // Nessuna preview ma immagine selezionata (stato iniziale)
                    if viewModel.isLoadingPreview {
                        // Solo spinner mentre genera la preview
                        ProgressView()
                            .controlSize(.large)
                            .scaleEffect(1.2)
                            .tint(.secondary)
                            .transition(.opacity)
                    } else if let error = viewModel.previewError {
                        // Immagine non è HDR valida
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
                        .background(Color(nsColor: .textBackgroundColor))
                    }
                } else {
                    // Nessuna immagine selezionata
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
            .background(Color(nsColor: .textBackgroundColor))
            
            // Metadata bar
            if let selectedImage = viewModel.selectedImage {
//                let _ = print("📊 MetadataBar rendering for: \(selectedImage.fileName) (id: \(selectedImage.id))")
                MetadataBar(image: selectedImage, headroomRaw: viewModel.measuredHeadroomRaw)
                    .id(selectedImage.id)  // Forza refresh quando cambia immagine
            }
        }
    }
}


// MARK: - Metadata Bar

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
                    // Color Space + Transfer Function
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
                    
                    // Resolution
                    if metadata.width > 0 && metadata.height > 0 {
                        MetadataItem(
                            icon: "rectangle.grid.2x2",
                            label: "Resolution",
                            value: metadata.resolutionString
                        )
                    }
                    
                    // Bit Depth
                    if metadata.bitDepth > 0 {
                        MetadataItem(
                            icon: "square.stack.3d.up",
                            label: "Bit Depth",
                            value: metadata.bitDepthString
                        )
                    }
                    
                    // Headroom (raw)
                    MetadataItem(
                        icon: "sun.max",
                        label: "Headroom",
                        value: String(format: "%.3f", headroomRaw)
                    )
                    
                    // File Size
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
                // Errore nel caricamento metadata
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Metadata not available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else {
                // Loading metadata
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
        .task {
            // Carica metadata in background
            metadata = await image.loadMetadata()
            if metadata == nil {
                loadError = true
            }
        }
    }
}

// MARK: - Metadata Item

struct MetadataItem: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary  // ← Aggiungi parametro opzionale
    
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
                    .foregroundStyle(valueColor)  // ← Usa il colore custom
                    .fontWeight(.medium)
            }
        }
    }
}

// MARK: - Image Metadata Model

struct ImageMetadata {
    let colorSpace: String
    let transferFunction: String
    let width: Int
    let height: Int
    let bitDepth: Int
    let fileSize: Int64
    
    var resolutionString: String {
        let mpix = Double(width * height) / 1_000_000.0
        return "\(width) × \(height) (\(String(format: "%.1f", mpix)) Mpix)"
    }
    
    var bitDepthString: String {
        return "\(bitDepth)-bit"
    }
    
    var fileSizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: fileSize)
    }
}

#Preview {
    PreviewPane(viewModel: MainViewModel())
        .frame(height: 600)
}
