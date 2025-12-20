import SwiftUI

/// Shows the current image preview along with loading/error states and a metadata bar.
struct PreviewPane: View {
    let viewModel: MainViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Preview image area
            ZStack {
                if let preview = viewModel.currentPreview {
                    // Preview is available
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    // Spinner while recomputing the preview due to settings changes (not while loading a new image).
                    if viewModel.isLoadingPreview && !viewModel.isLoadingNewImage {
                        // Transparent overlay that blocks user interaction.
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
                    
                    // Dark overlay + spinner while loading a new image.
                    if viewModel.isLoadingNewImage {
                        Rectangle()
                            .fill(Color.black.opacity(0.5))  // Semi-transparent scrim.
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
                        .background(Color(nsColor: .textBackgroundColor))
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
            .background(Color(nsColor: .textBackgroundColor))
            
            // Metadata bar
            if let selectedImage = viewModel.selectedImage {
                MetadataBar(image: selectedImage, headroomRaw: viewModel.measuredHeadroomRaw)
                    .id(selectedImage.id)  // Forces a refresh when the selected image changes.
            }
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

// MARK: - Image Metadata Model

/// Simple metadata extracted from the image header (no full decode).
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
