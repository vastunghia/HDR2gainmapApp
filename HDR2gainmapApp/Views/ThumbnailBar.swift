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
    
    var body: some View {
        VStack(spacing: 4) {
            // Thumbnail image
            Group {
                if let thumbnail = image.thumbnailImage {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.3)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                }
            }
            .frame(width: 120, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            
            // Filename
            Text(image.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 120)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }
}

#Preview {
    ThumbnailBar(viewModel: MainViewModel())
        .frame(height: 140)
}
