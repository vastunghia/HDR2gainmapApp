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

    /// Pixel-peeping zoom level (percent of actual pixels): 100 = 1 image px : 1 point.
    @AppStorage("pixelPeepZoomLevel")
    private var pixelPeepZoomLevel: Int = 200

    /// Auto tone-mapping clip tolerance: percent of pixels allowed to be clipped in any single channel.
    @AppStorage("autoClipTolerancePercent")
    private var autoClipTolerancePercent: Double = 1.0

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

                    Divider()

                    // Pixel-peeping zoom level
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Zoom Level", selection: $pixelPeepZoomLevel) {
                            Text("100%").tag(100)
                            Text("200%").tag(200)
                            Text("400%").tag(400)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    Text("""
                         How far the preview zooms when you click it ("pixel peeping"). \
                         100% shows actual pixels (1 image pixel per point); 200% / 400% magnify \
                         further. Click the image to zoom toward that spot, click again to reset.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Divider()

                    // Auto tone-mapping clip tolerance
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Auto Clip Tolerance", selection: $autoClipTolerancePercent) {
                            Text("0.25%").tag(0.25)
                            Text("0.5%").tag(0.5)
                            Text("1%").tag(1.0)
                            Text("2%").tag(2.0)
                            Text("4%").tag(4.0)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    Text("""
                         When using Auto tone mapping, the source headroom is lowered (brightening \
                         the SDR base) until at most this fraction of pixels is clipped in any \
                         single channel of the SDR output.
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
                        pixelPeepZoomLevel = 200
                        autoClipTolerancePercent = 1.0
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 640, height: 620)
        .closeOnEscape()
    }
}
