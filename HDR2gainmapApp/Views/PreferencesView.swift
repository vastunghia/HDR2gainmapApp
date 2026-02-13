import SwiftUI
import AppKit

struct PreferencesView: View {

    @AppStorage("heicExportQuality")
    private var heicExportQuality: Double = 0.97

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferences")
                .font(.title2.weight(.bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export")
                        .font(.headline)

                    // HEIC Quality
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("HEIC Quality")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.2f", heicExportQuality))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(value: $heicExportQuality, in: 0.5...1.0, step: 0.01)

                        HStack {
                            Text("Lower")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("Higher")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text("""
                         Controls the HEIF compression quality. \
                         Higher quality produces larger files with better image fidelity.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(14)

                HStack {
                    Spacer()
                    Button("Reset defaults") {
                        heicExportQuality = 0.97
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 640, height: 280)
        .closeOnEscape()
    }
}
