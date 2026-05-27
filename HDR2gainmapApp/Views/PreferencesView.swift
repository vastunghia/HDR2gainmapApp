import SwiftUI
import AppKit

struct PreferencesView: View {

    @AppStorage("heicExportQuality")
    private var heicExportQuality: Double = 0.95

    /// Gain map subsample factor: 1 = full resolution, 2 = half (the default, matching Apple's
    /// native HDR captures). A gain map is smooth/low-detail, so halving it shrinks the file
    /// with minimal visual impact.
    @AppStorage("gainMapSubsampleFactor")
    private var gainMapSubsampleFactor: Int = 2

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

                    Divider()

                    // Gain map resolution
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Gain Map Resolution", selection: $gainMapSubsampleFactor) {
                            Text("Half (½×)").tag(2)
                            Text("Full (1×)").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    Text("""
                         The gain map is stored at this fraction of the image resolution. \
                         Half resolution (the default, matching Apple's native HDR captures) \
                         shrinks the file with minimal visual impact; Full keeps every detail.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(14)

                HStack {
                    Spacer()
                    Button("Reset defaults") {
                        heicExportQuality = 0.95
                        gainMapSubsampleFactor = 2
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 640, height: 400)
        .closeOnEscape()
    }
}
