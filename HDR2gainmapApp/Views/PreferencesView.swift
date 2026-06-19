import SwiftUI
import AppKit

struct PreferencesView: View {

    @AppStorage("heicExportQuality")
    private var heicExportQuality: Double = 0.95

    /// Gain map subsample factor: 1 = full resolution (the default), 2 = half. A gain map is
    /// smooth/low-detail, so halving it shrinks the file; but at half resolution the highlight
    /// detail it carries softens visibly, so full is the default for maximum fidelity.
    @AppStorage("gainMapSubsampleFactor")
    private var gainMapSubsampleFactor: Int = 1

    /// Emit a 3-channel (RGB) ISO 21496-1 gain map instead of the default luma (monochrome) one.
    /// The gain map is computed per-channel and assembled by hand (Core Image only produces luma
    /// on macOS 15).
    @AppStorage("gainMapRGB")
    private var gainMapRGB: Bool = true

    /// Pixel-peeping zoom level (percent of actual pixels): 100 = 1 image px : 1 point.
    @AppStorage("pixelPeepZoomLevel")
    private var pixelPeepZoomLevel: Int = 200

    /// Auto tone-mapping clip tolerance: percent of pixels allowed to be clipped in any single channel.
    @AppStorage("autoClipTolerancePercent")
    private var autoClipTolerancePercent: Double = 1.0

    /// The five discrete Auto Clip Tolerance stops, low→high. The slider snaps to these; the
    /// centre value (index 2 = 1%) is the default.
    private let autoClipValues: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]

    /// When enabled, the app checks GitHub Releases for a newer version at launch (at most once a day).
    @AppStorage("automaticUpdateCheck")
    private var automaticUpdateCheck: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.title2.weight(.bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export")
                        .font(.headline)

                    // HEIC Quality
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("HEIC Quality")
                                .settingLabel()
                            Spacer()
                            Text(String(format: "%.2f", heicExportQuality))
                                .settingLabel()
                                .monospacedDigit()
                        }

                        // Continuous (no `step`) so the track stays clean — a stepped slider draws
                        // dense tick marks that make the gray native track read as faint/disabled.
                        Slider(value: $heicExportQuality, in: 0.5...1.0)
                            .controlSize(.large)

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
                    .settingCard()

                    Text("""
                         Controls the HEIF compression quality. \
                         Higher quality produces larger files with better image fidelity.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Divider()

                    // Gain map resolution
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Gain Map Resolution")
                            .settingLabel()
                        Picker("Gain Map Resolution", selection: $gainMapSubsampleFactor) {
                            Text("Half (½×)").tag(2)
                            Text("Full (1×)").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }

                    Text("""
                         The gain map is stored at this fraction of the image resolution. \
                         Full (the default) keeps every detail; Half shrinks the file but softens \
                         highlight detail, where the gain map does most of its work.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    // Kept in the layout (just transparent) when not applicable, so toggling the
                    // warning doesn't shift the rest of the window up or down.
                    Label("""
                          At half resolution, fine detail in the bright highlights of the \
                          reconstructed HDR (SDR + gain map) can be lost. Use Full if you \
                          want to preserve it.
                          """, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .opacity(gainMapSubsampleFactor != 1 ? 1 : 0)
                        .accessibilityHidden(gainMapSubsampleFactor == 1)

                    Divider()

                    // RGB gain map
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Export RGB gain map", isOn: $gainMapRGB)
                            .settingLabel()
                    }

                    Text("""
                         Stores a 3-channel (RGB) gain map instead of the default luma (monochrome) \
                         one, giving per-channel HDR reconstruction. Computed by the app and \
                         assembled as an ISO 21496-1 gain map.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    // Kept in the layout (just transparent) when not applicable, so toggling the
                    // warning doesn't shift the rest of the window up or down.
                    Label("""
                          A monochrome gain map scales all channels equally, so colors in the \
                          bright highlights of the reconstructed HDR can drift. An RGB gain map \
                          reconstructs each channel separately, keeping highlight colors truer.
                          """, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .opacity(!gainMapRGB ? 1 : 0)
                        .accessibilityHidden(gainMapRGB)
                }
                .padding(14)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("General Settings")
                        .font(.headline)

                    // Pixel-peeping zoom level
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Zoom Level")
                            .settingLabel()
                        Picker("Zoom Level", selection: $pixelPeepZoomLevel) {
                            Text("100%").tag(100)
                            Text("200%").tag(200)
                            Text("400%").tag(400)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
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
                        HStack {
                            Text("Auto Tone-Mapping")
                                .settingLabel()
                            Spacer()
                            Text(String(format: "%g%%", autoClipTolerancePercent))
                                .settingLabel()
                                .monospacedDigit()
                        }

                        // `step: 1` keeps the slider snapping to the five discrete tolerance stops.
                        Slider(
                            value: Binding(
                                get: { Double(autoClipValues.firstIndex(of: autoClipTolerancePercent) ?? 2) },
                                set: { autoClipTolerancePercent = autoClipValues[Int($0.rounded())] }
                            ),
                            in: 0...Double(autoClipValues.count - 1),
                            step: 1
                        )
                        .controlSize(.large)

                        HStack(alignment: .top) {
                            Text("Darker, less clipped, blown SDR /\nMore detailed HDR")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Text("Brighter, more clipped, blown SDR /\nLess detailed HDR")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .settingCard()

                    Text("""
                         When using Auto tone mapping, the source headroom is lowered (brightening \
                         the SDR base) until at most this fraction of pixels is clipped in any \
                         single channel of the SDR output.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text("""
                         If you go for a clipped SDR, you may find that a way to reconstruct detail \
                         in the highlights more accurately is to export RGB (and possibly \
                         full-resolution) gain maps — see the two settings above.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Updates")
                        .font(.headline)

                    Toggle("Check for updates automatically", isOn: $automaticUpdateCheck)
                        .settingLabel()

                    Text("""
                         When enabled, the app checks GitHub for a newer release at launch \
                         (at most once a day) and notifies you only if one is available.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(14)

                HStack {
                    Spacer()
                    Button("Check Now") {
                        UpdateChecker.checkManually()
                    }
                    .buttonStyle(.bordered)
                }
            }

            // A single global reset for every preference, regardless of section.
            HStack {
                Spacer()
                Button("Reset defaults") {
                    heicExportQuality = 0.95
                    gainMapSubsampleFactor = 1
                    gainMapRGB = true
                    pixelPeepZoomLevel = 200
                    autoClipTolerancePercent = 1.0
                    automaticUpdateCheck = true
                }
                .buttonStyle(.bordered)
            }

            }
            .padding(24)
        }
        // Fixed-width content; the window itself is sized/locked by `enableWindowResize` (width 660,
        // opens at 1120, vertically resizable down to 400) together with the scene's
        // `.windowResizability(.contentMinSize)`. The ScrollView absorbs overflow when shrunk.
        .frame(width: 660)
        .enableWindowResize(width: 660, minHeight: 400, initialHeight: 1120)
        .closeOnEscape()
    }
}

private extension View {
    /// Uniform styling for a control's title label across all Preferences sections (HEIC Quality,
    /// Gain Map Resolution, Export RGB gain map, Zoom Level, Auto Tone-Mapping, Check for updates…), so
    /// sliders, segmented pickers and toggles all read consistently.
    func settingLabel() -> some View {
        font(.subheadline).foregroundStyle(.secondary)
    }

    /// A subtle inset "card" around a slider control cluster (title + slider + end captions). macOS
    /// native sliders are thin gray tracks with no colored fill, so they can read as faint/disabled;
    /// this faint filled rounded background makes the control area stand out from the GroupBox.
    func settingCard() -> some View {
        padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
    }
}
