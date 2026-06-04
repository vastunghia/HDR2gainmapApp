import SwiftUI

struct ThumbnailBar: View {
    let viewModel: MainViewModel
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 12) {
                    ForEach(viewModel.images) { image in
                        ThumbnailCell(
                            image: image,
                            isSelected: viewModel.selectedImage?.id == image.id,
                            isCached: viewModel.warmImageIDs.contains(image.id)
                        )
                        .id(image.id)
                        .onTapGesture {
                            viewModel.userSelect(image)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // Keep the selected thumbnail visible (e.g. when navigating with arrow keys).
            .onChange(of: viewModel.selectedImage?.id) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Thumbnail Cell

struct ThumbnailCell: View {
    let image: HDRImage
    let isSelected: Bool
    let isCached: Bool

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
            // "In memory" badge: this image will load quickly (no disk read).
            .overlay(alignment: .topTrailing) {
                if isCached {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .padding(4)
                        .transition(.opacity)
                        .help("In memory — loads quickly")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isCached)
            
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
