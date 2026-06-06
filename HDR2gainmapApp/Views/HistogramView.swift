import SwiftUI

/// Identifies which histogram is being rendered.
enum HistogramMode {
    case hdrInput
    case sdrOutput
}

/// Sidebar view rendering the HDR input histogram and the generated SDR output histogram.
struct HistogramView: View {
    let viewModel: MainViewModel
    let panelWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Header bar.
            HStack {
                Text("Histograms")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Two panels: HDR input and SDR output.
            VStack(spacing: 0) {
                // HDR input histogram.
                HistogramPanel(
                    title: "HDR Input",
                    viewModel: viewModel
                )

                Divider()

                // SDR output histogram.
                HistogramPanelSDR(
                    title: "Tonemapped SDR",
                    viewModel: viewModel
                )

                Divider()

                // Clipped pixels toggle and stats
                if let selectedImage = viewModel.selectedImage {
                    VStack(alignment: .leading, spacing: 8) {
                        // Toggle
                        Toggle("Show clipped pixels", isOn: Binding(
                            get: { selectedImage.settings.showClippedOverlay },
                            set: { selectedImage.settings.showClippedOverlay = $0 }
                        ))
                        // The clipping overlay applies only to the SDR tone-mapped view.
                        .disabled(!viewModel.isCurrentImageValid || viewModel.previewMode != .sdrTonemapped)
                        .onChange(of: selectedImage.settings.showClippedOverlay) {
                            viewModel.refreshPreviewOnly()
                        }
                        
                        // Legend button
                        Button(action: {
                            viewModel.showLegendWindow.toggle()
                        }) {
                            Label("Show legend & stats", systemImage: "info.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                        .disabled(!viewModel.isCurrentImageValid || viewModel.detailedClippingStats == nil)
                        
                        // Clipping statistics
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
                                .transition(.opacity)
                            } else {
                                HStack(spacing: 6) {
                                    Text("Number of pixels clipped (maxRGB): – (–)")
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .font(.caption)
                                .transition(.opacity)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(nsColor: .windowBackgroundColor))  // Standard background
                }
            }
        }
        .frame(width: panelWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Histogram Panel (HDR Input)

struct HistogramPanel: View {
    let title: String
    let viewModel: MainViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Panel title.
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            
            // Histogram canvas.
            ZStack {
                // Dark background.
                Color(red: 0x11/255.0, green: 0x13/255.0, blue: 0x14/255.0)
                
                if viewModel.selectedImage == nil {
                    Text("No image selected")
                        .font(.caption)
                        .foregroundStyle(.gray)
                } else if viewModel.isLoadingNewImage {
                    // While a new image is being loaded, show a placeholder.
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.gray)
                        Text("Loading...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let histogram = viewModel.hdrHistogram {
                    HistogramCanvasCompact(
                        histogram: histogram,
                        viewModel: viewModel,
                        mode: .hdrInput
                    )
                } else {
                    // Histogram is not available yet (e.g., first load).
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.gray)
                        Text("Loading HDR histogram...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(3, contentMode: .fit)   // drawing area: width = 3 × height
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Histogram Panel (SDR Output)

struct HistogramPanelSDR: View {
    let title: String
    let viewModel: MainViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            
            ZStack {
                Color(red: 0x11/255.0, green: 0x13/255.0, blue: 0x14/255.0)
                
                if viewModel.selectedImage == nil {
                    Text("No image selected")
                        .font(.caption)
                        .foregroundStyle(.gray)
                } else if viewModel.isLoadingNewImage {
                    // While a new image is being loaded, show a placeholder.
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.gray)
                        Text("Loading...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.isLoadingHistograms {
                    // SDR histogram can be rebuilding (it is regenerated as settings change).
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.gray)
                        Text("Updating SDR histogram...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let histogram = viewModel.sdrHistogram {
                    HistogramCanvasCompact(
                        histogram: histogram,
                        viewModel: viewModel,
                        mode: .sdrOutput
                    )
                } else {
                    Text("Histogram unavailable")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(3, contentMode: .fit)   // drawing area: width = 3 × height
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Histogram Canvas (Compact Sidebar Version)

struct HistogramCanvasCompact: View {
    let histogram: HistogramCalculator.HistogramResult
    let viewModel: MainViewModel
    // Controls which histogram-specific markers are shown (e.g., headroom).
    let mode: HistogramMode
    
    private let x_at_ref_white: CGFloat = 0.5
    
    var body: some View {
        
        // Read a token so SwiftUI invalidates/recreates the Canvas when the percentile→headroom lookup becomes available.
        let generation = viewModel.percentileHeadroomCacheGeneration

        // Frozen rendering parameters (previously tuned via debug sliders).
        let smoothing = 5.0          // moving-average window applied at render time
        let yPercentile = 98.0       // robust Y-axis scale reference percentile

        Canvas { context, size in
            // 1) Background colors (SDR teal + HDR maroon)
            let sdrRect = CGRect(x: 0, y: 0, width: size.width * x_at_ref_white, height: size.height)
            let hdrRect = CGRect(x: size.width * x_at_ref_white, y: 0, width: size.width * (1 - x_at_ref_white), height: size.height)
            
            context.fill(
                Path(sdrRect),
                with: .color(Color(red: 0x1d/255.0, green: 0x23/255.0, blue: 0x24/255.0))
            )
            context.fill(
                Path(hdrRect),
                with: .color(Color(red: 0x24/255.0, green: 0x1a/255.0, blue: 0x1b/255.0))
            )
            
            // Smooth the raw counts at render time (window is tunable live).
            let win = Int(smoothing.rounded())
            let red   = HistogramCalculator.movingAverage(histogram.redCounts,   window: win)
            let green = HistogramCalculator.movingAverage(histogram.greenCounts, window: win)
            let blue  = HistogramCalculator.movingAverage(histogram.blueCounts,  window: win)

            // Robust Y-axis: scale against a high percentile of the non-zero counts (not the
            // absolute max), so a single tall spike clips off the top while the body of the
            // histogram fills the upper part of the panel.
            let scaleRef = robustScaleReference(red, green, blue, percentile: yPercentile)
            let scale = size.height * 0.85 / max(scaleRef, 1)

            // 1) Filled areas using Lightroom's exact per-overlap palette (measured in Photoshop).
            //    Painted opaque, smallest subsets first so larger overlaps overpaint them — this
            //    reproduces the palette exactly, independent of the background underneath.
            let redArea   = areaPath(counts: red,   scale: scale, size: size)
            let greenArea = areaPath(counts: green, scale: scale, size: size)
            let blueArea  = areaPath(counts: blue,  scale: scale, size: size)
            // Singles
            paintSubset(context, areas: [redArea],   color: lrRGB(184, 78, 67),  size: size)
            paintSubset(context, areas: [greenArea], color: lrRGB(84, 141, 92),  size: size)
            paintSubset(context, areas: [blueArea],  color: lrRGB(52, 108, 179), size: size)
            // Pairs (the front channel wins; the palette already encodes the z-order outcome).
            paintSubset(context, areas: [redArea, greenArea], color: lrRGB(108, 141, 92), size: size) // R∩G
            paintSubset(context, areas: [greenArea, blueArea], color: lrRGB(82, 152, 109), size: size) // G∩B
            paintSubset(context, areas: [redArea, blueArea],  color: lrRGB(72, 110, 178), size: size) // R∩B
            // Triple
            paintSubset(context, areas: [redArea, greenArea, blueArea], color: lrRGB(204, 204, 204), size: size)

            // 2) Thin outlines on the top edge of each area. Order red → blue → green so the
            //    green outline ends up frontmost (matches Lightroom's z-ordering).
            strokeTopEdge(context: &context, counts: red,   color: lrRGB(216, 74, 54), scale: scale, size: size)
            strokeTopEdge(context: &context, counts: blue,  color: lrRGB(41, 63, 158), scale: scale, size: size)
            strokeTopEdge(context: &context, counts: green, color: lrRGB(88, 195, 77), scale: scale, size: size)

            // Reference vertical markers.
            drawVerticalBars(context: &context, size: size)
            
            // Headroom markers (Direct method only).
            drawHeadroomLines(context: &context, size: size, mode: mode)
            
            // Baseline.
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(baseline, with: .color(.white), lineWidth: 1.5)
        }
        .id(generation)   // forces a redraw when generation changes
        .overlay(alignment: .topLeading) {
            // SDR/HDR labels.
            HStack(spacing: 0) {
                Text("SDR")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
                
                Text("HDR")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            }
            .padding(.top, 4)
        }
    }
    
    // MARK: - Drawing Helpers
    
    /// Y position (clamped to the panel) for a given count.
    private func yFor(_ count: Float, scale: CGFloat, size: CGSize) -> CGFloat {
        let h = CGFloat(count) * scale
        return size.height - min(h, size.height)   // clamp: tall spikes clip at the top
    }

    /// Robust scale reference: a high percentile of the non-zero counts across the RGB channels.
    private func robustScaleReference(_ a: [Float], _ b: [Float], _ c: [Float], percentile: Double) -> CGFloat {
        var vals: [Float] = []
        vals.reserveCapacity(a.count * 3)
        for arr in [a, b, c] {
            for v in arr where v > 0 { vals.append(v) }
        }
        guard !vals.isEmpty else { return 1 }
        vals.sort()
        let p = max(0, min(1, percentile / 100.0))
        let idx = min(vals.count - 1, Int((Double(vals.count - 1) * p).rounded()))
        return CGFloat(vals[idx])
    }

    /// Color from 0–255 RGB components.
    private func lrRGB(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255.0, green: g / 255.0, blue: b / 255.0)
    }

    /// Fills the intersection of the given area paths with an opaque color.
    /// Clipping is applied to a local copy of the context, so it doesn't affect later draws.
    private func paintSubset(_ ctx: GraphicsContext, areas: [Path], color: Color, size: CGSize) {
        var c = ctx
        for a in areas { c.clip(to: a) }
        c.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
    }

    /// Closed area under the curve (curve → down to the baseline), for additive fills.
    private func areaPath(counts: [Float], scale: CGFloat, size: CGSize) -> Path {
        var path = Path()
        guard !counts.isEmpty else { return path }
        path.move(to: CGPoint(x: CGFloat(histogram.xCenters[0]) * size.width, y: size.height))
        for (i, count) in counts.enumerated() {
            let x = CGFloat(histogram.xCenters[i]) * size.width
            path.addLine(to: CGPoint(x: x, y: yFor(count, scale: scale, size: size)))
        }
        path.addLine(to: CGPoint(x: CGFloat(histogram.xCenters[counts.count - 1]) * size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    /// Thin darker stroke along the top edge of a channel area.
    private func strokeTopEdge(context: inout GraphicsContext, counts: [Float], color: Color, scale: CGFloat, size: CGSize, lineWidth: CGFloat = 1.0) {
        var path = Path()
        for (i, count) in counts.enumerated() {
            let x = CGFloat(histogram.xCenters[i]) * size.width
            let y = yFor(count, scale: scale, size: size)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func drawVerticalBars(context: inout GraphicsContext, size: CGSize) {
        let barColor = Color(red: 0xC0/255.0, green: 0xC6/255.0, blue: 0xCC/255.0)
        
        // Constants.referenceHDRwhiteNit, solid line at x = 0.5
        let xref = x_at_ref_white * size.width
        var pathref = Path()
        pathref.move(to: CGPoint(x: xref, y: 0))
        pathref.addLine(to: CGPoint(x: xref, y: size.height))
        context.stroke(pathref, with: .color(barColor.opacity(0.6)), lineWidth: 1.5)
        
        // HDR stops above reference white (dashed).
        let hdrStops = log2(Constants.maxHistogramNit / Constants.referenceHDRwhiteNit)
        let hdrStopsInt = Int(hdrStops.rounded())
        let hdrNits: [Float] = (1...hdrStopsInt).map { k in
            Constants.referenceHDRwhiteNit * powf(2.0, Float(k))
        }
        
        for nit in hdrNits {
            let xPos = nitsToX(nit) * size.width
            var path = Path()
            path.move(to: CGPoint(x: xPos, y: 0))
            path.addLine(to: CGPoint(x: xPos, y: size.height))
            
            context.stroke(
                path,
                with: .color(barColor.opacity(0.4)),
                style: StrokeStyle(lineWidth: 1.0, dash: [6, 6])
            )
        }
    }
    
    private func drawHeadroomLines(context: inout GraphicsContext, size: CGSize, mode: HistogramMode) {
        
        guard let _ = viewModel.selectedImage else { return }
        
        // Draw headroom indicators for all tonemap methods.
        // - Direct: uses the user-controlled Source/Target headroom sliders.
        // - Peak Max / Percentile: Source headroom is derived from the method settings; Target is fixed at 1.0.
        
        switch mode {
        case .hdrInput:
            // HDR input panel: show source headroom only.
            if let sourceNits = getSourceHeadroomNits() {
                drawHeadroomLineWithArrows(
                    context: &context,
                    size: size,
                    nits: sourceNits,
                    color: .purple  // Magenta/Purple
//                    label: "IN"
                )
            }
            
        case .sdrOutput:
            // SDR output panel: show target headroom only.
            if let targetNits = getTargetHeadroomNits() {
                drawHeadroomLineWithArrows(
                    context: &context,
                    size: size,
                    nits: targetNits,
                    color: .purple  // Magenta/Purple
//                    label: "OUT"
                )
            }
        }
    }
    
    // Helper that draws a vertical marker with arrowheads at both ends.
    private func drawHeadroomLineWithArrows(
        context: inout GraphicsContext,
        size: CGSize,
        nits: Float,
        color: Color
//        label: String
    ) {
        let xPos = nitsToX(nits) * size.width
        let triangleSize: CGFloat = 8
        
        // Upper triangle (arrow pointing south ▼)
        var topTriangle = Path()
        topTriangle.move(to: CGPoint(x: xPos, y: triangleSize))  // Head (bottom)
        topTriangle.addLine(to: CGPoint(x: xPos - triangleSize, y: 0))  // Left base (top)
        topTriangle.addLine(to: CGPoint(x: xPos + triangleSize, y: 0))  // Right base (top)
        topTriangle.closeSubpath()
        
        context.fill(topTriangle, with: .color(color.opacity(0.9)))
        
        // Optional: border for higher visibility
        context.stroke(
            topTriangle,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.0)
        )
    }
    
    // MARK: - Headroom Calculation
    
    private func getSourceHeadroomNits() -> Float? {
        guard let image = viewModel.selectedImage else { return nil }
        
        let sourceHeadroom: Float
        
        switch image.settings.sourceHeadroomMethod {  // era .method
        case .peakMax:
            let measured = viewModel.measuredHeadroom
            let r = image.settings.tonemapRatio
            sourceHeadroom = max(1.0, 1.0 + measured - powf(measured, r))
            
        case .percentile:
            sourceHeadroom = viewModel.cachedPercentileSourceHeadroom() ?? viewModel.measuredHeadroom
            
        case .direct:
            sourceHeadroom = image.settings.directSourceHeadroom ?? viewModel.measuredHeadroom
        }
        
        // `sourceHeadroom` is relative (e.g., 2.0 means 2× reference white).
        return sourceHeadroom * Constants.referenceHDRwhiteNit  // Convert to absolute nits.
    }
    
    private func getTargetHeadroomNits() -> Float? {
        guard let image = viewModel.selectedImage else { return nil }
        
        let targetHeadroom = image.settings.targetHeadroom ?? 1.0
        return targetHeadroom * Constants.referenceHDRwhiteNit
    }
    
    // MARK: - Coordinate Transform
    
    private func nitsToX(_ nit: Float) -> CGFloat {
        let hdrStops = log2(Constants.maxHistogramNit / Constants.referenceHDRwhiteNit)  // ~4 stops
        
        if nit <= Constants.referenceHDRwhiteNit {
            // SDR region: 0..Constants.referenceHDRwhiteNit
            let y = nit / Constants.referenceHDRwhiteNit
            let encoded = srgbEncode(y)
            return CGFloat(x_at_ref_white) * CGFloat(encoded)
        } else {
            // HDR region: Constants.referenceHDRwhiteNit..Constants.maxHistogramNit
            let t = max(0, min(1, log2(nit / Constants.referenceHDRwhiteNit) / hdrStops))
            return CGFloat(x_at_ref_white) + CGFloat(1.0 - x_at_ref_white) * CGFloat(t)
        }
    }
    
    private func srgbEncode(_ x: Float) -> Float {
        let a: Float = 0.055
        let val = max(0, min(1, x))
        if val <= 0.0031308 {
            return 12.92 * val
        } else {
            return (1 + a) * pow(val, 1.0 / 2.4) - a
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 0) {
        HistogramView(viewModel: MainViewModel(), panelWidth: 300)
        Divider()
    }
    .frame(height: 800)
}
