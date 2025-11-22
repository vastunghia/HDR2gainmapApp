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
                // Header
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.horizontal)
                    .padding(.top)
                
                Divider()
                
                if let selectedImage = viewModel.selectedImage {
                    // 1. Clipped Overlay Section (PRIMA)
                    OverlaySection(
                        settings: Binding(
                            get: { selectedImage.settings },
                            set: { selectedImage.settings = $0 }
                        ),
                        viewModel: viewModel
                    )
                    
                    Divider()
                    
                    // 2. Preview Updates Section (SECONDA - include auto-refresh + refresh button)
                    PreviewUpdatesSection(viewModel: viewModel)
                    
                    Divider()
                    
                    // 3. Tonemap Method (TERZA)
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
                    
                    // 4. Export Buttons (QUARTA)
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

// MARK: - Preview Updates Section (Unified)

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
//    let onSettingsChange: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Clipped Pixels Overlay", systemImage: "paintbrush.pointed")
                .font(.headline)
            
            Toggle("Show clipped pixels", isOn: $settings.showClippedOverlay)
                .disabled(!viewModel.isCurrentImageValid)
                .onChange(of: settings.showClippedOverlay) {     // ← zero-parameter closure
                    // NIENTE debouncedRefresh qui: andiamo diretti
                    viewModel.refreshPreview()
                }
            
//            VStack(alignment: .leading, spacing: 8) {
//                Text("Overlay Color")
//                    .font(.caption)
//                    .foregroundStyle(settings.showClippedOverlay && viewModel.isCurrentImageValid ? .secondary : .tertiary)
//                
//                Picker("Color", selection: $settings.overlayColor) {
//                    Text("Magenta").tag("magenta")
//                    Text("Red").tag("red")
//                    Text("Violet").tag("violet")
//                }
//                .pickerStyle(.segmented)
//                .disabled(!settings.showClippedOverlay || !viewModel.isCurrentImageValid)  // ← MODIFICA
//                .onChange(of: settings.overlayColor) {
//                    onSettingsChange()
//                }
//            }
        }
        .padding(.horizontal)
    }
}

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
                    viewModel.refreshPreview() // ← immediato, niente debounce
                }
            }
            
            // Parameters based on selected method
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
                    onSettingsChange: onSettingsChange, // slider → debounce
                    onImmediateChange: {
                        if viewModel.autoRefreshPreview {
                            viewModel.refreshPreview()   // reset → immediato
                        }
                    },
                    isDisabled: !viewModel.isCurrentImageValid
                )
            }
            
            // Clipping stats line (aggiungo “(maxRGB)” per chiarezza)
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tonemap Ratio")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", settings.tonemapRatio))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            Slider(value: $settings.tonemapRatio, in: 0.0...1.0, step: 0.01)
                .disabled(isDisabled)  // ← AGGIUNGI
                .onChange(of: settings.tonemapRatio) {
                    onSettingsChange()
                }
            
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
    
    // Parametri della curva
    private let beta: Double = 1.0/3.0
    private let k: Double = 3.0
    
    private let minP: Double = 0.95
    private let maxP: Double = 0.99999
    
    // Tick marks: posizioni slider fisse con i rispettivi percentili calcolati
    private let tickMarks: [(sliderPos: Double, label: String)] = [
        (0.0, "95%"),
        (0.2, "99.6%"),
        (0.4, "99.9%"),
        (0.6, "99.98%"),
        (0.8, "99.997%"),
        (1.0, "99.999%")
    ]
    
    // Debug state
//    @State private var debugTask: Task<Void, Never>?
    
    // Conversione da percentile a slider position (funzione inversa)
    private var sliderPosition: Double {
        let percentileDouble = Double(settings.percentile)
        
        // Usa tolleranza per gestire imprecisioni della conversione Float
        let tolerance = 1e-6
        
        // Gestisci esplicitamente gli estremi per precisione
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
        
        // Clamp per evitare che errori di arrotondamento impediscano di raggiungere gli estremi
        if !result.isFinite || result.isNaN {
            return 0.0
        }
        return min(max(result, 0.0), 1.0)
    }
    
    // Conversione da slider position a percentile (funzione diretta)
    private func setPercentileFromSlider(_ s: Double) {
        // Gestisci esplicitamente gli estremi per evitare problemi di precisione Float
        if s <= 0.0 {
            settings.percentile = Float(minP)
//            scheduleDebugLog(originalS: s, clampedS: 0.0, percentile: minP)
            return
        }
        
        if s >= 1.0 {
            settings.percentile = Float(maxP)
//            scheduleDebugLog(originalS: s, clampedS: 1.0, percentile: maxP)
            return
        }
        
        let range = maxP - minP
        
        // P = minP + (maxP - minP) * (1 - (1 - s^β)^k)
        let sBeta = pow(s, beta)
        let inner = 1.0 - sBeta
        let powered = pow(inner, k)
        let normalized = 1.0 - powered
        let percentile = minP + range * normalized
        
        // Clamp result per evitare valori fuori range
        settings.percentile = Float(min(max(percentile, minP), maxP))
        
        // Debug logging con delay
//        scheduleDebugLog(originalS: s, clampedS: s, percentile: percentile)
    }
    
//    private func scheduleDebugLog(originalS: Double, clampedS: Double, percentile: Double) {
//        // Cancella il task precedente
//        debugTask?.cancel()
//        
//        // Crea nuovo task con delay di 1 secondo
//        debugTask = Task { @MainActor in
//            try? await Task.sleep(for: .seconds(1))
//            
//            guard !Task.isCancelled else { return }
//            
//            // Ricalcola la posizione corrente per vedere il round-trip
//            let currentSliderPos = sliderPosition
//            
//            print("=== PERCENTILE SLIDER DEBUG ===")
//            print("Input from slider:")
//            print("  - Original s: \(originalS)")
//            print("  - Clamped s: \(clampedS)")
//            print("  - s == 1.0? \(originalS == 1.0)")
//            print("")
//            print("Conversion to percentile:")
//            print("  - Calculated percentile: \(percentile)")
//            print("  - Min percentile (minP): \(minP)")
//            print("  - Max percentile (maxP): \(maxP)")
//            print("  - Clamped to range: \(min(max(percentile, minP), maxP))")
//            print("  - Stored as Float: \(settings.percentile)")
//            print("")
//            print("Round-trip back to slider:")
//            print("  - Current sliderPosition: \(currentSliderPos)")
//            print("  - Difference from input: \(abs(currentSliderPos - originalS))")
//            print("  - Is at max (1.0)? \(currentSliderPos == 1.0)")
//            print("")
//            print("Percentile details:")
//            print("  - Display value: \(String(format: "%.5f%%", settings.percentile * 100))")
//            print("  - Raw Float: \(settings.percentile)")
//            print("  - As Double: \(Double(settings.percentile))")
//            print("  - Distance from maxP: \(maxP - Double(settings.percentile))")
//            print("===============================\n")
//        }
//    }
    
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

            // Tick marks sotto lo slider
            ZStack(alignment: .topLeading) {
                GeometryReader { geometry in
                    ForEach(Array(tickMarks.enumerated()), id: \.offset) { _, tick in
                        // Lo slider ha un padding interno di circa 10pt per lato
                        // Compensiamo per allineare i tick con la track effettiva dello slider
                        let sliderPadding: CGFloat = 10.0
                        let effectiveWidth = geometry.size.width - (sliderPadding * 2)
                        let xPosition = sliderPadding + (effectiveWidth * tick.sliderPos)
                        
                        VStack(spacing: 2) {
                            // Linea tick mark
                            Rectangle()
                                .fill(Color.secondary.opacity(0.4))
                                .frame(width: 1, height: 6)
                            
                            // Label sotto la linea
                            Text(tick.label)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                        .frame(width: 0, height: 0, alignment: .top) // Punto di ancoraggio
                        .offset(x: xPosition, y: 0) // Sposta dal punto di ancoraggio
                    }
                }
            }
            .frame(height: 24) // Altezza sufficiente per linea + label
            
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
    
    // Binding che mappa gli opzionali su default sensati
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
//            // Info riga
//            Text("Measured source headroom: \(fmt(max(1.0, measuredHeadroom)))  •  Max allowed: \(fmt(maxLimit))")
//                .font(.caption)
//                .foregroundStyle(.secondary)
//            
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
            Slider(value: sourceBinding, in: 0...maxLimit)/*, step: 0.001)*/
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
            Slider(value: targetBinding, in: 0...maxLimit)/*, step: 0.001)*/
                .disabled(isDisabled)
            
            HStack(spacing: 12) {
                Button("Reset defaults") {
                    settings.resetDirectDefaults(measuredHeadroom: max(1.0, measuredHeadroom))
                    onImmediateChange() // ← immediato, niente debounce
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
