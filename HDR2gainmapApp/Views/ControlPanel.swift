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
    let panelWidth: CGFloat
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Settings header (consistent with Histograms header)
                HStack(spacing: 8) {
                    Text("Settings")
                        .font(.headline)

                    Button {
                        viewModel.showTonemapHelp()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("What do these tone-mapping controls do?")

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                
                Divider()
                
                if let selectedImage = viewModel.selectedImage {
                    // Tone-mapping controls
                    TonemapControlsSection(
                        settings: Binding(
                            get: { selectedImage.settings },
                            set: { selectedImage.settings = $0 }
                        ),
                        viewModel: viewModel,
                        onSettingsChange: {
                            // Auto-refresh is always enabled
                            viewModel.debouncedRefreshPreview()
                        }
                    )
                    .padding(.top, 24)
                    
                    Divider()
                        .padding(.top, 24)

                    // "Mark as ready" hint (the M key toggles the green thumbnail flag).
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                        Text("Press M to mark / unmark current image")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                    // Export header (consistent style)
                    HStack {
                        Text("Export")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    
                    Divider()
                    
                    // Export actions
                    ExportSection(viewModel: viewModel)
                        .padding(.top, 12)
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
        .frame(width: panelWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Tonemap Controls Section

struct TonemapControlsSection: View {
    @Binding var settings: ProcessingSettings
    @Bindable var viewModel: MainViewModel
    let onSettingsChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // SOURCE HEADROOM SECTION
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Source Headroom")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Spacer()

                    if viewModel.isAutoTuning {
                        if viewModel.autoTuneCurrentFile.isEmpty {
                            // Single-image tune: indeterminate spinner.
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            // Batch tune: determinate bar.
                            ProgressView(value: viewModel.autoTuneProgress)
                                .controlSize(.small)
                                .frame(width: 60)
                        }
                        Button("Cancel") {
                            viewModel.cancelAutoTune()
                        }
                        .controlSize(.small)
                    } else {
                        Button("Auto") {
                            viewModel.autoTuneSelectedImage()
                        }
                        .controlSize(.small)
                        .disabled(!viewModel.isCurrentImageValid || viewModel.isExporting)
                        .help("Find the lowest source headroom keeping per-channel clipping within the tolerance set in Preferences")

                        Button("Auto all") {
                            viewModel.autoTuneAllImages()
                        }
                        .controlSize(.small)
                        .disabled(viewModel.images.count <= 1 || viewModel.isExporting)
                        .help("Apply the Auto search to every loaded image (each image's own method and target headroom)")
                    }
                }
                .confirmationDialog(
                    "\(viewModel.autoTuneModifiedCount) image(s) already have hand-tuned settings",
                    isPresented: $viewModel.showAutoTuneConfirmation
                ) {
                    Button("Re-tune all images") {
                        viewModel.startAutoTuneAll(includeModified: true)
                    }
                    Button("Skip hand-tuned images") {
                        viewModel.startAutoTuneAll(includeModified: false)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Auto will overwrite their source-headroom parameter.")
                }

                if viewModel.isAutoTuning && !viewModel.autoTuneCurrentFile.isEmpty {
                    Text("Auto-tuning \(viewModel.autoTuneCurrentFile)…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Method picker
                Picker("Method", selection: $settings.sourceHeadroomMethod) {
                    ForEach(ProcessingSettings.SourceHeadroomMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.isCurrentImageValid || viewModel.isAutoTuning)
                .onChange(of: settings.sourceHeadroomMethod) {
                    onSettingsChange()
                }

                // Parameters based on selected method
                switch settings.sourceHeadroomMethod {
                case .peakMax:
                    PeakMaxControls(
                        settings: $settings,
                        onSettingsChange: onSettingsChange,
                        isDisabled: !viewModel.isCurrentImageValid || viewModel.isAutoTuning
                    )
                case .percentile:
                    PercentileControls(
                        settings: $settings,
                        onSettingsChange: onSettingsChange,
                        isDisabled: !viewModel.isCurrentImageValid || viewModel.isAutoTuning
                    )
                case .direct:
                    DirectSourceHeadroomControls(
                        settings: $settings,
                        measuredHeadroom: viewModel.measuredHeadroom,
                        onSettingsChange: onSettingsChange,
                        isDisabled: !viewModel.isCurrentImageValid || viewModel.isAutoTuning
                    )
                }

                if let note = viewModel.autoTuneNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            // TARGET HEADROOM SECTION
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Target Headroom")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Text("(Advanced)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                
                // Checkbox to enable target headroom adjustment.
                // The reset-to-1.0 lives in the binding setter (not an `.onChange`) so it
                // fires only on a real user toggle — an `.onChange(of:)` would also fire when
                // `settings` rebinds to another image on selection change, writing 1.0 into
                // the newly selected image.
                Toggle("Adjust also Target headroom", isOn: Binding(
                    get: { settings.adjustTargetHeadroom },
                    set: { newValue in
                        settings.adjustTargetHeadroom = newValue
                        if !newValue {
                            settings.targetHeadroom = 1.0
                        }
                        onSettingsChange()
                    }
                ))
                .disabled(!viewModel.isCurrentImageValid)
                
                // Target headroom slider (enabled only when checkbox is checked)
                TargetHeadroomControls(
                    settings: $settings,
                    measuredHeadroom: viewModel.measuredHeadroom,
                    onSettingsChange: onSettingsChange,
                    isDisabled: !viewModel.isCurrentImageValid || !settings.adjustTargetHeadroom
                )
            }
            
            Divider()
            
            // Reset button
            HStack {
                Button("Reset to defaults") {
                    settings.resetDefaults(measuredHeadroom: max(1.0, viewModel.measuredHeadroom))
                    onSettingsChange()
                }
                .disabled(!viewModel.isCurrentImageValid)
                
                Spacer()
                
                // Optional: Show current method's default value as hint
                Text(defaultHintText())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)
    }
    
    // Add this helper function inside TonemapControlsSection:
    private func defaultHintText() -> String {
        switch settings.sourceHeadroomMethod {
        case .peakMax:
            // tonemapRatio = 0.2 → displayed as 0.8 (reversed)
            let displayedDefault = 1.0 - ProcessingSettings.defaultTonemapRatio
            return "Default: \(String(format: "%.1f", displayedDefault))"
        case .percentile:
            return "Default: \(String(format: "%.3f%%", ProcessingSettings.defaultPercentile * 100))"
        case .direct:
            return "Default: measured headroom"
        }
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
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", Double(displayedTonemapRatio)))
                    .font(.caption)
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
                    .font(.caption)
                Spacer()
                Text(String(format: "%.3f%%", settings.percentile * 100))
                    .font(.caption)
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

// MARK: - Direct Source Headroom Controls

struct DirectSourceHeadroomControls: View {
    @Binding var settings: ProcessingSettings
    let measuredHeadroom: Float
    let onSettingsChange: () -> Void
    let isDisabled: Bool
    
    private var maxLimit: Float {
        let real = max(1.0, measuredHeadroom)
        return real * 2.0
    }
    private func fmt(_ v: Float) -> String { String(format: "%.3f", v) }
    
    // Binding that maps optional to sensible default
    private var sourceBinding: Binding<Float> {
        Binding(
            get: { settings.directSourceHeadroom ?? max(1.0, measuredHeadroom) },
            set: { settings.directSourceHeadroom = $0; onSettingsChange() }
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Value")
                    .font(.caption)
                Spacer()
                Text(fmt(sourceBinding.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            Slider(value: sourceBinding, in: 0.1...maxLimit)
                .disabled(isDisabled)
            
            Text("Direct control of source headroom parameter")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Target Headroom Controls

struct TargetHeadroomControls: View {
    @Binding var settings: ProcessingSettings
    let measuredHeadroom: Float
    let onSettingsChange: () -> Void
    let isDisabled: Bool
    
    private var maxLimit: Float {
        let real = max(1.0, measuredHeadroom)
        return real * 2.0
    }
    private func fmt(_ v: Float) -> String { String(format: "%.3f", v) }
    
    // Binding that maps optional to default 1.0
    private var targetBinding: Binding<Float> {
        Binding(
            get: { settings.targetHeadroom ?? 1.0 },
            set: { settings.targetHeadroom = $0; onSettingsChange() }
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Value")
                    .font(.caption)
                Spacer()
                Text(fmt(targetBinding.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            Slider(value: targetBinding, in: 0.1...maxLimit)
                .disabled(isDisabled)
            
            Text("Normally set to 1.0 for SDR output")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Export Section

struct ExportSection: View {
    let viewModel: MainViewModel
    @State private var showAppliedFeedback = false
    @State private var appliedCount = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // FILENAME SUFFIX
            VStack(alignment: .leading, spacing: 6) {
                Text("Filename Suffix (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if let selectedImage = viewModel.selectedImage {
                    HStack(spacing: 8) {
                        TextField("e.g., \"processed\" or \"_v2\"", text: Binding(
                            get: { selectedImage.settings.filenameSuffix },
                            set: { selectedImage.settings.filenameSuffix = $0; viewModel.markSettingsDirty() }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        
                        Button(action: {
                            applySuffixToAllImages(selectedImage.settings.filenameSuffix)
                            appliedCount = viewModel.images.count
                            
                            // Mostra feedback
                            withAnimation {
                                showAppliedFeedback = true
                            }
                            
                            // Nascondi dopo 2.5 secondi
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                withAnimation {
                                    showAppliedFeedback = false
                                }
                            }
                        }) {
                            Text("Apply to all")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(viewModel.images.count <= 1)
                        .help("Apply this suffix to all \(viewModel.images.count) loaded images")
                    }
                    
                    // VISUAL FEEDBACK
                    if showAppliedFeedback {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text("Applied to all \(appliedCount) images")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.green.opacity(0.1))
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("e.g., \"processed\" or \"_v2\"", text: .constant(""))
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .disabled(true)
                        
                        Button("Apply to all") {}
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(true)
                    }
                }
            }
            
            Divider()
                .padding(.vertical, 4)
            
            // Bottoni export (invariati)
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

            Divider()
                .padding(.vertical, 4)

            // Settings profile: save / restore per-image tone-mapping settings for the folder.
            HStack(spacing: 8) {
                Button(action: {
                    viewModel.exportSettingsProfile()
                }) {
                    Label("Export Settings", systemImage: "slider.horizontal.below.square.and.square.filled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(viewModel.images.isEmpty || viewModel.isExporting)
                .help("Save the tone-mapping settings of this folder to a JSON profile")

                Button(action: {
                    viewModel.importSettingsProfile()
                }) {
                    Label("Import Settings", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(viewModel.isExporting)
                .help("Load a previously saved tone-mapping settings profile")
            }
        }
        .padding(.horizontal)
    }
    
    private func applySuffixToAllImages(_ suffix: String) {
        for image in viewModel.images {
            image.settings.filenameSuffix = suffix
        }
        viewModel.markSettingsDirty()
    }
}

#Preview {
    ControlPanel(viewModel: MainViewModel(), panelWidth: 300)
        .frame(height: 800)
}
