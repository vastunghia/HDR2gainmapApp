import SwiftUI

struct ExportProgressView: View {
    let progress: Double
    let currentFile: String
    
    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            
            // Progress card
            VStack(spacing: 20) {
                // Icon
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)
                
                // Title
                Text("Exporting Images...")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                // Progress bar
                VStack(spacing: 8) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 300)
                    
                    // Percentage
                    Text("\(Int(progress * 100))%")
                        .font(.headline)
                        .monospacedDigit()
                }
                
                // Current file
                if !currentFile.isEmpty {
                    VStack(spacing: 4) {
                        Text("Current file:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(currentFile)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 280)
                    }
                }
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
            )
            .frame(width: 400)
        }
    }
}

#Preview {
    ExportProgressView(progress: 0.65, currentFile: "example_image_with_very_long_name.heic")
}
