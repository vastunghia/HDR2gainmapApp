import SwiftUI

struct ThumbnailBar: View {
    let viewModel: MainViewModel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: 12) {
                ForEach(viewModel.images) { image in
                    ThumbnailCell(
                        image: image,
                        isSelected: viewModel.selectedImage?.id == image.id
                    )
                    .onTapGesture {
                        // Force an immediate state update on the MainActor.
                        Task { @MainActor in
                            viewModel.isLoadingNewImage = true
                            viewModel.hdrHistogram = nil
                            viewModel.sdrHistogram = nil
                            
                            // Give SwiftUI a chance to render the loading state before heavy work starts.
                            try? await Task.sleep(for: .milliseconds(1))
                            
                            // Now load the selected image (preview + histograms).
                            await viewModel.selectImage(image)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Thumbnail Cell

struct ThumbnailCell: View {
    let image: HDRImage
    let isSelected: Bool
    
    // Outer container: 120×80 for landscape/square, 80×120 for portrait.
    private func containerSize(for thumbnail: NSImage?) -> CGSize {
        guard let t = thumbnail else { return CGSize(width: 120, height: 80) }
        return (t.size.width >= t.size.height)
        ? CGSize(width: 120, height: 80)  // landscape (or square)
        : CGSize(width: 80,  height: 120) // portrait
    }
    
    var body: some View {
        // Compute sizes once.
        let thumb = image.thumbnailImage
        let outer = containerSize(for: thumb)
        
        VStack(spacing: 4) {
            ZStack {
                // Container "slot" background.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.06))
                
                // Never crop: use .fit within the container.
                Group {
                    if let thumbnail = thumb {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .aspectRatio(contentMode: .fit) // <— NO CROP
                        // No need for a second "inner frame": .fit derives it automatically.
                    } else {
                        Color.gray.opacity(0.25)
                            .overlay {
                                ProgressView().scaleEffect(0.7)
                            }
                    }
                }
                .padding(4) // A bit of breathing room from the rounded corners.
            }
            .frame(width: outer.width, height: outer.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            
            // Filename: keep the label width aligned with the outer container.
            Text(image.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: outer.width)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }
}
