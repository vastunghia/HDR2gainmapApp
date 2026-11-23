import SwiftUI

/// Controls shown with the Reconstruction Error view, in the row under the view chips: the metric
/// picker, a color legend that matches the heatmap kernel, and the summary numbers.
struct ReconstructionErrorControls: View {
    /// Written here, read by the engine (`ReconstructionErrorMetric.current`); `ContentView` re-renders
    /// the previews when it changes.
    @AppStorage(ReconstructionErrorMetric.defaultsKey)
    private var metricRaw = ReconstructionErrorMetric.worstChannel.rawValue

    let stats: ReconstructionErrorStats?

    private var metric: ReconstructionErrorMetric { ReconstructionErrorMetric(rawValue: metricRaw) ?? .worstChannel }

    var body: some View {
        HStack(spacing: 10) {
            Picker("Metric", selection: $metricRaw) {
                ForEach(ReconstructionErrorMetric.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .help("Worst Channel: the largest error among R, G and B, so color shifts show too. "
                  + "Luminance: the brightness error only, blue where the rebuilt HDR is darker than the "
                  + "input, red where it is brighter.")

            legend

            summary
                .frame(minWidth: 190, alignment: .leading)
        }
        .help("Difference between the HDR input and the HDR rebuilt from SDR base + gain map, i.e. "
              + "what the exported file shows on an HDR display. Errors under about 2 nit are ignored.")
    }

    // MARK: Legend

    private var legend: some View {
        let full = ReconstructionErrorMetric.fullScaleStops
        return VStack(alignment: .leading, spacing: 1) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(stops: legendStops, startPoint: .leading, endPoint: .trailing))
                .frame(width: 96, height: 7)
            HStack(spacing: 0) {
                if metric == .luminance {
                    Text("−\(stopsLabel(full))")
                    Spacer(minLength: 0)
                    Text("0")
                    Spacer(minLength: 0)
                    Text("+\(stopsLabel(full))")
                } else {
                    Text("0")
                    Spacer(minLength: 0)
                    Text("≥ \(stopsLabel(full)) stop")
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .frame(width: 96)
        }
    }

    /// Samples of the kernel's palette across the legend (−1…1 for luminance, 0…1 otherwise).
    private var legendStops: [Gradient.Stop] {
        let n = 16
        return (0...n).map { i in
            let x = Double(i) / Double(n)
            let s = metric == .luminance ? x * 2 - 1 : x
            return Gradient.Stop(color: Self.heatColor(s, metric: metric), location: x)
        }
    }

    /// Swift twin of `reconstructionErrorHeat` in `Utilities/PreviewKernels.metal` (keep in sync): the
    /// palette color at normalized error `s` (|s| ≤ 1), blended over a mid-gray background with
    /// opacity |s|, as the heatmap draws it over a mid-gray image.
    static func heatColor(_ s: Double, metric: ReconstructionErrorMetric) -> Color {
        let t = min(abs(s), 1)
        let c: (Double, Double, Double)
        if metric == .luminance {
            c = s < 0 ? (0.25, 0.55, 1.0) : (1.0, 0.25, 0.15)
        } else {
            let yellow = (1.0, 0.9, 0.0), orange = (1.0, 0.5, 0.0), red = (0.9, 0.0, 0.1)
            func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ f: Double) -> (Double, Double, Double) {
                (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
            }
            c = t < 0.5 ? mix(yellow, orange, t * 2) : mix(orange, red, (t - 0.5) * 2)
        }
        func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func toGamma(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        let background = 0.5 * 0.2   // mid-gray SDR (linear 0.5) dimmed like the kernel
        let a = t
        func blend(_ v: Double) -> Double { toGamma(background + (toLinear(v) - background) * a) }
        return Color(.displayP3, red: blend(c.0), green: blend(c.1), blue: blend(c.2))
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        if let stats {
            let mean = metric == .luminance ? "Mean |error|" : "Mean error"
            Text("\(mean) \(String(format: "%.3f", stats.meanStops)) stop · "
                 + "\(percent(stats.fractionAboveThreshold)) of pixels > "
                 + "\(stopsLabel(ReconstructionErrorMetric.thresholdStops)) stop")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Measuring…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ f: Double) -> String {
        let p = f * 100
        return p > 0 && p < 0.01 ? "< 0.01%" : String(format: p < 10 ? "%.2f%%" : "%.1f%%", p)
    }

    /// 0.5 → "½", 0.25 → "¼", otherwise a decimal.
    private func stopsLabel(_ v: Float) -> String {
        switch v {
        case 0.5: return "½"
        case 0.25: return "¼"
        default: return String(format: "%g", v)
        }
    }
}
