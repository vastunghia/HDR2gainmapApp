import SwiftUI

struct ExportSummaryView: View {
    let results: ExportResults
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: results.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(results.failedCount == 0 ? .green : .orange)
                
                Text("Export Complete")
                    .font(.title)
                    .fontWeight(.bold)
            }
            .padding(.top, 30)
            .padding(.bottom, 20)
            
            Divider()
            
            // Summary stats
            VStack(spacing: 16) {
                StatRow(label: "Total", value: "\(results.total)", color: .primary)
                StatRow(label: "Succeeded", value: "\(results.successCount)", color: .green)
                if results.skippedCount > 0 {
                    StatRow(label: "Skipped", value: "\(results.skippedCount)", color: .orange)
                }
                if results.failedCount > 0 {
                    StatRow(label: "Failed", value: "\(results.failedCount)", color: .red)
                }
            }
            .padding(.vertical, 20)
            
            // Skipped files list
            if !results.skipped.isEmpty {
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Skipped Files (Invalid HDR):")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(results.skipped, id: \.self) { fileName in
                                HStack {
                                    Image(systemName: "forward.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                    Text(fileName)
                                        .font(.subheadline)
                                }
                                .padding(.vertical, 4)
                                
                                if fileName != results.skipped.last {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color.orange.opacity(0.05))
            }
            
            // Failed files list
            if !results.failed.isEmpty {
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Failed Files:")
                        .font(.headline)
                        .foregroundStyle(.red)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(results.failed, id: \.fileName) { failure in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(failure.fileName)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(failure.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                
                                if failure.fileName != results.failed.last?.fileName {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color.red.opacity(0.05))
            }
            
            // Succeeded files list (only if few)
            if !results.succeeded.isEmpty && results.successCount <= 5 {
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Succeeded Files:")
                        .font(.headline)
                        .foregroundStyle(.green)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(results.succeeded, id: \.self) { fileName in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                                Text(fileName)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color.green.opacity(0.05))
            }
            
            Divider()
            
            // Close button
            Button(action: {
                dismiss()
            }) {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Stat Row

struct StatRow: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
    }
}

#Preview {
    ExportSummaryView(results: ExportResults(
        total: 10,
        succeeded: ["image1.png", "image2.png", "image3.png"],
        failed: [
            ("image4.png", "Invalid colorspace"),
            ("image5.png", "Gain map extraction failed")
        ],
        skipped: ["image6.png", "image7.png"]
    ))
}
