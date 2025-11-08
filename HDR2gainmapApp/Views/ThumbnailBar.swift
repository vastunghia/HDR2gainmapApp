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
                        Task {
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

    // Contenitore esterno: 120×80 per landscape, 80×120 per portrait
    private func containerSize(for thumbnail: NSImage?) -> CGSize {
        guard let t = thumbnail else { return CGSize(width: 120, height: 80) }
        return (t.size.width >= t.size.height)
        ? CGSize(width: 120, height: 80)  // landscape (o quadrata)
        : CGSize(width: 80,  height: 120) // portrait
    }

    var body: some View {
        // Calcola dimensioni una sola volta
        let thumb = image.thumbnailImage
        let outer = containerSize(for: thumb)

        VStack(spacing: 4) {
            ZStack {
                // Fondo “slot” del contenitore
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.06))

                // Immagine mai croppata: .fit dentro il contenitore
                Group {
                    if let thumbnail = thumb {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .aspectRatio(contentMode: .fit) // <— NO CROP
                            // Non serve calcolare la “seconda cornice”: .fit
                            // la ricava automaticamente (es. 107×80 su 120×80).
                    } else {
                        Color.gray.opacity(0.25)
                            .overlay {
                                ProgressView().scaleEffect(0.7)
                            }
                    }
                }
                .padding(4) // piccolo respiro per non “baciare” i bordi arrotondati
            }
            .frame(width: outer.width, height: outer.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            // Filename: larghezza coerente con il contenitore esterno
            Text(image.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: outer.width)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }
}
