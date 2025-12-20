import SwiftUI

/// Identifies which histogram is being rendered.
enum HistogramMode {
    case hdrInput
    case sdrOutput
}

/// Sidebar view rendering the HDR input histogram and the generated SDR output histogram.
struct HistogramView: View {
    let viewModel: MainViewModel
    
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
                .frame(height: 180)
                
                Divider()
                
                // SDR output histogram.
                HistogramPanelSDR(
                    title: "SDR Output",
                    viewModel: viewModel
                )
                .frame(height: 180)
            }
        }
        .frame(width: 300)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            
            // Find the maximum bin count for normalization.
            let maxCount = max(
                histogram.redCounts.max() ?? 1,
                histogram.greenCounts.max() ?? 1,
                histogram.blueCounts.max() ?? 1,
                histogram.lumaCounts.max() ?? 1
            )
            
            let scale = size.height * 0.85 / CGFloat(maxCount)
            
            // Draw RGB channels.
            drawCurve(context: &context, counts: histogram.redCounts, color: .red, scale: scale, size: size)
            drawCurve(context: &context, counts: histogram.greenCounts, color: .green, scale: scale, size: size)
            drawCurve(context: &context, counts: histogram.blueCounts, color: .blue, scale: scale, size: size)
            
            // Draw luminance (Y) on top with a thicker stroke.
            drawCurve(context: &context, counts: histogram.lumaCounts, color: .white, scale: scale, size: size, lineWidth: 1.8)
            
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
    
    private func drawCurve(
        context: inout GraphicsContext,
        counts: [Float],
        color: Color,
        scale: CGFloat,
        size: CGSize,
        lineWidth: CGFloat = 1.2
    ) {
        var path = Path()
        
        for (i, count) in counts.enumerated() {
            let x = CGFloat(histogram.xCenters[i]) * size.width
            let y = size.height - CGFloat(count) * scale
            
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        
        context.stroke(
            path,
            with: .color(color.opacity(0.95)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
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
                    color: .purple,  // Magenta/Purple
                    label: "IN"
                )
            }
            
        case .sdrOutput:
            // SDR output panel: show target headroom only.
            if let targetNits = getTargetHeadroomNits() {
                drawHeadroomLineWithArrows(
                    context: &context,
                    size: size,
                    nits: targetNits,
                    color: .purple,  // Magenta/Purple
                    label: "OUT"
                )
            }
        }
    }
    
    // Helper that draws a vertical marker with arrowheads at both ends.
    private func drawHeadroomLineWithArrows(
        context: inout GraphicsContext,
        size: CGSize,
        nits: Float,
        color: Color,
        label: String
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
        
        switch image.settings.method {
        case .peakMax:
            // Keep the UI indicator in sync with the value actually fed into `CIToneMapHeadroom`
            // for the Peak Max method (see HDRProcessor.generatePreview()).
            let measured = viewModel.measuredHeadroom
            let r = image.settings.tonemapRatio
            sourceHeadroom = max(1.0, 1.0 + measured - powf(measured, r))
            
        case .percentile:
            // Percentile: the source headroom is derived from image content.
            // Use the cached lookup (if ready) so the indicator can update in real time while dragging the slider.
            sourceHeadroom = viewModel.cachedPercentileSourceHeadroom() ?? viewModel.measuredHeadroom
            
        case .direct:
            sourceHeadroom = image.settings.directSourceHeadroom ?? viewModel.measuredHeadroom
        }
        
        // `sourceHeadroom` is relative (e.g., 2.0 means 2× reference white).
        return sourceHeadroom * Constants.referenceHDRwhiteNit  // Convert to absolute nits.
    }
    
    private func getTargetHeadroomNits() -> Float? {
        guard let image = viewModel.selectedImage else { return nil }
        
        let targetHeadroom: Float
        
        switch image.settings.method {
        case .peakMax, .percentile:
            // For these methods, the target is always reference white.
            return Constants.referenceHDRwhiteNit
            
        case .direct:
            targetHeadroom = image.settings.directTargetHeadroom ?? 1.0
        }
        
        // `targetHeadroom` is relative; convert to absolute nits.
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
        HistogramView(viewModel: MainViewModel())
        Divider()
    }
    .frame(height: 800)
}
