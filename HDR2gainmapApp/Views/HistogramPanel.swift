import SwiftUI

struct HistogramPanel: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 8) {
            Text("Luminance Distribution")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)

            HistogramSection(title: "Input HDR", histogram: viewModel.inputHistogram)

            HistogramSection(title: "Output SDR", histogram: viewModel.outputHistogram)

        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// Piccola view placeholder
private struct EmptyHistogramSection: View {
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.3))
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 80)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 1)
            )
        }
    }
}


struct HistogramSection: View {
    let title: String
    let histogram: RGBYHistogramData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HistogramCurveView(histogram: histogram)
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    // bordo esterno come prima
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                )
                .overlay {
                    // linea verticale "SDR boundary" se presente (0..1)
                    if let bx = histogram.sdrBoundaryX {
                        GeometryReader { geo in
                            let x = max(0, min(1, bx)) * geo.size.width
                            Path { p in
                                p.move(to: CGPoint(x: x, y: 0))
                                p.addLine(to: CGPoint(x: x, y: geo.size.height))
                            }
                            .stroke(
                                Color.secondary,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
        }
    }
}

struct HistogramCurveView: View {
    let histogram: RGBYHistogramData

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                Color.black   // sfondo

                // Y (bianco)
                curvePath(values: histogram.y, in: size)
                    .stroke(Color.white, lineWidth: 1.2)

                // R, G, B
                curvePath(values: histogram.r, in: size)
                    .stroke(Color.red, lineWidth: 1)

                curvePath(values: histogram.g, in: size)
                    .stroke(Color.green, lineWidth: 1)

                curvePath(values: histogram.b, in: size)
                    .stroke(Color.blue, lineWidth: 1)

                // Linea verticale limite SDR (headroom=0)
                if let sdrX = histogram.sdrBoundaryX {
                    Path { path in
                        let x = sdrX * size.width
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    .stroke(
                        Color.white.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                }
            }
            .drawingGroup()
        }
        
        if let bx = histogram.sdrBoundaryX {
            GeometryReader { geo in
                let w = geo.size.width
                let xPos = bx * w
                Path { p in
                    p.move(to: CGPoint(x: xPos, y: 0))
                    p.addLine(to: CGPoint(x: xPos, y: geo.size.height))
                }
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4,3]))
                .foregroundStyle(.secondary)
            }
        }

    }

    private func curvePath(values: [CGFloat], in size: CGSize) -> Path {
        var path = Path()
        guard !values.isEmpty else { return path }

        let n = values.count
        let stepX = size.width / CGFloat(max(n - 1, 1))

        for i in 0..<n {
            let x = CGFloat(i) * stepX
            let y = (1 - values[i]) * size.height
            let point = CGPoint(x: x, y: y)

            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
    }
}
