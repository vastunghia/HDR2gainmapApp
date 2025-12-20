import SwiftUI

/// Formats a percentage ensuring at least two non-zero significant digits (up to 6 decimals).
/// Examples: 23      -> "23%"; 2.3 -> "2.3%"; 0.45 -> "0.45%"; 0.0042 -> "0.0042%".
func formatPercentTwoSig(_ pct: Double) -> String {
    guard pct.isFinite, pct > 0 else { return "0%" }
    for decimals in 0...6 {
        let s = String(format: "%.\(decimals)f", pct)
        let nonZero = s.filter { $0 >= "1" && $0 <= "9" }.count
        if nonZero >= 2 { return s + "%" }
    }
    return String(format: "%.6f%%", pct)
}

struct ControlPanel: View {
    @Bindable var viewModel: MainViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Settings header
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.horizontal)
                    .padding(.top)
                
                Divider()
                
                if let selectedImage = viewModel.selectedImage {
                    // Clipped overlay
                    OverlaySection(
                        settings: Binding(
                            get: { selectedImage.settings },
                            set: { selectedImage.settings = $0 }
                        ),
                        viewModel: viewModel
                    )
                    
                    Divider()
                    
                    // Preview refresh controls
                    PreviewUpdatesSection(viewModel: viewModel)
                    
                    Divider()
                    
                    // Tone-mapping method and parameters
                    TonemapMethodSection(
                        settings: Binding(
                            get: { selectedImage.settings },
                            set: { selectedImage.settings = $0 }
                        ),
                        viewModel: viewModel,
                        onSettingsChange: {
                            if viewModel.autoRefreshPreview {
                                viewModel.debouncedRefreshPreview()
                            }
                        }
                    )
                    
                    Divider()
                    
                    // Export actions
                    ExportSection(viewModel: viewModel)
                } else {
                    // No image selected
                    VStack(spacing: 12) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Select an image to adjust settings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                
                Spacer()
            }
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Preview Updates Section

struct PreviewUpdatesSection: View {
    let viewModel: MainViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Preview Updates", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            
            Toggle("Auto-refresh preview", isOn: Binding(
                get: { viewModel.autoRefreshPreview },
                set: { viewModel.autoRefreshPreview = $0 }
            ))
            .toggleStyle(.switch)
            .disabled(!viewModel.isCurrentImageValid)
            
            Button(action: {
                viewModel.refreshPreview()
            }) {
                Label("Refresh Preview", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(
                !viewModel.isCurrentImageValid
                || viewModel.isLoadingPreview
                || viewModel.autoRefreshPreview
            )
            
            Text(viewModel.autoRefreshPreview
                 ? "Preview updates automatically when settings change"
                 : "Use Refresh button to update preview manually")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
}

// MARK: - Overlay Section

struct OverlaySection: View {
    @Binding var settings: ProcessingSettings
    let viewModel: MainViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Clipped Pixels Overlay", systemImage: "paintbrush.pointed")
                .font(.headline)
            
            Toggle("Show clipped pixels", isOn: $settings.showClippedOverlay)
                .disabled(!viewModel.isCurrentImageValid)
                .onChange(of: settings.showClippedOverlay) {
                    // Refreshes only the visual overlay (no histogram recomputation).
                    viewModel.refreshPreviewOnly()
                }
        }
        .padding(.horizontal)
    }
}

// MARK: - Preview Refresh Flow Notes

/*
 1) Toggling the clipped overlay:
 → refreshPreviewOnly()
 → generatePreview(refreshHistograms: false)
 → Updates the preview overlay only (histograms unchanged)
 
 2) Switching the tone-mapping method (e.g., peakMax → percentile):
 → refreshPreview()
 → generatePreview(refreshHistograms: true)
 → HDR histogram: cache hit if the source image didn't change
 → SDR histogram: recomputed because parameters changed
 
 3) Tweaking tone-mapping parameters (sliders):
 → debouncedRefreshPreview()
 → generatePreview(refreshHistograms: true) after the debounce delay
 → HDR histogram: cache hit if the source image didn't change
 → SDR histogram: recomputed because parameters changed
 
 4) Selecting a new image:
 → selectImage()
 → generatePreview(refreshHistograms: true)
 → Both histograms are computed (then cached for subsequent previews)
 */

// MARK: - Tonemap Method Section

struct TonemapMethodSection: View {
    @Binding var settings: ProcessingSettings
    let viewModel: MainViewModel
    let onSettingsChange: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tonemap Method", systemImage: "slider.horizontal.3")
                .font(.headline)
            
            Picker("Method", selection: $settings.method) {
                ForEach(ProcessingSettings.TonemapMethod.allCases, id: \.self) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.isCurrentImageValid)
            .onChange(of: settings.method) {
                if viewModel.autoRefreshPreview {
                    viewModel.refreshPreview() // Immediate (no debounce)
                }
            }
            
            // Parameters for the selected method
            switch settings.method {
            case .peakMax:
                PeakMaxControls(
                    settings: $settings,
                    onSettingsChange: onSettingsChange,
                    isDisabled: !viewModel.isCurrentImageValid
                )
            case .percentile:
                PercentileControls(
                    settings: $settings,
                    onSettingsChange: onSettingsChange,
                    isDisabled: !viewModel.isCurrentImageValid
                )
            case .direct:
                DirectControls(
                    settings: $settings,
                    measuredHeadroom: viewModel.measuredHeadroom,
                    onSettingsChange: onSettingsChange, // Slider changes are debounced
                    onImmediateChange: {
                        if viewModel.autoRefreshPreview {
                            viewModel.refreshPreview()   // Reset is immediate
                        }
                    },
                    isDisabled: !viewModel.isCurrentImageValid
                )
            }
            
            Group {
                if viewModel.isCurrentImageValid, let stats = viewModel.clippingStats, stats.total > 0 {
                    let pct = (Double(stats.clipped) / Double(stats.total)) * 100.0
                    HStack(spacing: 6) {
                        Text("Number of pixels clipped (maxRGB):")
                            .foregroundStyle(.secondary)
                        Text("\(stats.clipped.formatted()) (\(formatPercentTwoSig(pct)))")
                            .fontWeight(.medium)
                            .monospacedDigit()
                        Spacer()
                    }
                    .font(.caption)
                    .padding(.top, 6)
                    .transition(.opacity)
                } else {
                    HStack(spacing: 6) {
                        Text("Number of pixels clipped (maxRGB): – (–)")
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .font(.caption)
                    .padding(.top, 6)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Peak Max Controls

struct PeakMaxControls: View {
    @Binding var settings: ProcessingSettings
    let onSettingsChange: () -> Void
    let isDisabled: Bool
    
    
    private let tonemapRatioRange: ClosedRange<Float> = 0.0...1.0

    /// The Peak Max slider is intentionally reversed: moving the thumb to the right decreases the
    /// underlying `settings.tonemapRatio` that feeds the tone-mapping curve.
    private var tonemapRatioSliderBinding: Binding<Float> {
        Binding(
            get: {
                tonemapRatioRange.lowerBound + tonemapRatioRange.upperBound - settings.tonemapRatio
            },
            set: { newUIValue in
                settings.tonemapRatio = tonemapRatioRange.lowerBound + tonemapRatioRange.upperBound - newUIValue
                onSettingsChange()
            }
        )
    }

    /// Display the UI-facing value so the number grows as the thumb moves to the right.
    private var displayedTonemapRatio: Float {
        tonemapRatioRange.lowerBound + tonemapRatioRange.upperBound - settings.tonemapRatio
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tonemap Ratio")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", Double(displayedTonemapRatio)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            Slider(value: tonemapRatioSliderBinding, in: tonemapRatioRange)
                .disabled(isDisabled)
                            
            Text("Controls the softening curve applied to peak brightness")
                .font(.caption2)
                .foregroundStyle(.secondary)
            
        }
        .padding(.vertical, 4)
    }
}


// MARK: - Percentile Controls

struct PercentileControls: View {
    @Binding var settings: ProcessingSettings
    let onSettingsChange: () -> Void
    let isDisabled: Bool
    
    // Curve parameters
    private let beta: Double = 1.0/3.0
    private let k: Double = 3.0
    
    private let minP: Double = 0.95
    private let maxP: Double = 0.99999
    
    // Tick marks: fixed slider positions with their corresponding percentiles.
    private let tickMarks: [(sliderPos: Double, label: String)] = [
        (0.0, "95%"),
        (0.2, "99.6%"),
        (0.4, "99.9%"),
        (0.6, "99.98%"),
        (0.8, "99.997%"),
        (1.0, "99.999%")
    ]
    
    // Percentile → slider position (inverse mapping)
    private var sliderPosition: Double {
        let percentileDouble = Double(settings.percentile)
        
        // Use a tolerance to absorb Float conversion noise.
        let tolerance = 1e-6
        
        // Handle the endpoints explicitly for better precision.
        if percentileDouble <= minP + tolerance {
            return 0.0
        }
        if percentileDouble >= maxP - tolerance {
            return 1.0
        }
        
        let range = maxP - minP
        let normalized = (percentileDouble - minP) / range
        
        // s = {1 - [1 - normalized]^(1/k)}^(1/β)
        let inner = 1.0 - normalized
        let powered = pow(inner, 1.0 / k)
        let subtracted = 1.0 - powered
        let result = pow(subtracted, 1.0 / beta)
        
        // Clamp to ensure rounding noise doesn't prevent reaching the endpoints.
        if !result.isFinite || result.isNaN {
            return 0.0
        }
        return min(max(result, 0.0), 1.0)
    }
    
    // Slider position → percentile (forward mapping)
    private func setPercentileFromSlider(_ s: Double) {
        // Handle the endpoints explicitly to avoid Float precision issues.
        if s <= 0.0 {
            settings.percentile = Float(minP)
            return
        }
        
        if s >= 1.0 {
            settings.percentile = Float(maxP)
            return
        }
        
        let range = maxP - minP
        
        // P = minP + (maxP - minP) * (1 - (1 - s^β)^k)
        let sBeta = pow(s, beta)
        let inner = 1.0 - sBeta
        let powered = pow(inner, k)
        let normalized = 1.0 - powered
        let percentile = minP + range * normalized
        
        // Clamp to avoid out-of-range values.
        settings.percentile = Float(min(max(percentile, minP), maxP))
        
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Percentile")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.3f%%", settings.percentile * 100))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            // Slider
            Slider(
                value: Binding(
                    get: { sliderPosition },
                    set: {
                        setPercentileFromSlider($0)
                        onSettingsChange()
                    }
                ),
                in: 0.0...1.0
            )
            .disabled(isDisabled)
            
            // Tick marks below the slider
            ZStack(alignment: .topLeading) {
                GeometryReader { geometry in
                    ForEach(Array(tickMarks.enumerated()), id: \.offset) { _, tick in
                        // SwiftUI's Slider has an internal padding of ~10pt per side.
                        // Compensate to align ticks with the effective track.
                        let sliderPadding: CGFloat = 10.0
                        let effectiveWidth = geometry.size.width - (sliderPadding * 2)
                        let xPosition = sliderPadding + (effectiveWidth * tick.sliderPos)
                        
                        VStack(spacing: 2) {
                            // Tick mark line
                            Rectangle()
                                .fill(Color.secondary.opacity(0.4))
                                .frame(width: 1, height: 6)
                            
                            // Label below the line
                            Text(tick.label)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                        .frame(width: 0, height: 0, alignment: .top) // Anchor point
                        .offset(x: xPosition, y: 0) // Offset from the anchor point
                    }
                }
            }
            .frame(height: 24) // Height for tick line + label
            
            Text("Uses histogram-based peak detection for robust headroom calculation")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Direct Controls

struct DirectControls: View {
    @Binding var settings: ProcessingSettings
    let measuredHeadroom: Float
    let onSettingsChange: () -> Void
    let onImmediateChange: () -> Void
    let isDisabled: Bool
    
    private var maxLimit: Float {
        let real = max(1.0, measuredHeadroom)
        return real * 2.0
    }
    private func fmt(_ v: Float) -> String { String(format: "%.3f", v) }
    
    // Bindings that map optionals to sensible defaults
    private var sourceBinding: Binding<Float> {
        Binding(
            get: { settings.directSourceHeadroom ?? max(1.0, measuredHeadroom) },
            set: { settings.directSourceHeadroom = $0; onSettingsChange() }
        )
    }
    private var targetBinding: Binding<Float> {
        Binding(
            get: { settings.directTargetHeadroom ?? 1.0 },
            set: { settings.directTargetHeadroom = $0; onSettingsChange() }
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Slider: input source headroom
            HStack {
                Text("Input source headroom")
                    .font(.subheadline)
                Spacer()
                Text(fmt(sourceBinding.wrappedValue))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: sourceBinding, in: 0...maxLimit)
                .disabled(isDisabled)
            
            // Slider: target headroom
            HStack {
                Text("Target headroom")
                    .font(.subheadline)
                Spacer()
                Text(fmt(targetBinding.wrappedValue))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: targetBinding, in: 0...maxLimit)
                .disabled(isDisabled)
            
            HStack(spacing: 12) {
                Button("Reset defaults") {
                    settings.resetDirectDefaults(measuredHeadroom: max(1.0, measuredHeadroom))
                    onImmediateChange() // Immediate (no debounce)
                }
                .disabled(isDisabled)
                
                Spacer()
                Text("Maps directly to CIToneMapHeadroom parameters.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Export Section

struct ExportSection: View {
    let viewModel: MainViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Export", systemImage: "square.and.arrow.down")
                .font(.headline)
            
            Button(action: {
                viewModel.exportCurrentImage()
            }) {
                Label("Export Current Image", systemImage: "doc.badge.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!viewModel.isCurrentImageValid || viewModel.isExporting)
            
            Button(action: {
                viewModel.exportAllImages()
            }) {
                Label("Export All Images (\(viewModel.images.count))", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.images.isEmpty || viewModel.isExporting)
            
            Text("Exports HEIC with embedded gain map and Maker Apple metadata")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
}

#Preview {
    ControlPanel(viewModel: MainViewModel())
        .frame(height: 800)
}
