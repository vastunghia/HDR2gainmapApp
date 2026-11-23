#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// Core Image color kernels for the "Reconstruction Error" preview (app target only: the CLI shows no
// previews). `[[stitchable]]` kernels need no special build flags — Core Image links them at runtime;
// HDRProcessor loads them with `CIColorKernel(functionName:fromMetalLibraryData:)` from the app's
// default.metallib.
//
// Inputs are linear Display P3 (the engine's working space), 1.0 = reference white (203 nit):
// `hdr` = the HDR input, `rec` = the HDR rebuilt from SDR base + gain map (the Final Output view).
//
// Metric (`metric`): 0 = worst channel — max over R, G, B of |log2(rec / hdr)|, unsigned, catches
// color shifts as well as brightness errors; 1 = luminance — log2(Y_rec / Y_hdr), signed (negative =
// rebuilt darker). `eps` is added to both sides so near-black noise does not register as error.
//
// The palette is mirrored in Swift for the legend (`ReconstructionErrorMetric.legendColor`); keep the
// two in sync.

namespace {

float errorStops(float3 hdr, float3 rec, float metric, float eps, float3 lumaW) {
    if (metric < 0.5) {
        float3 e = abs(log2((max(rec, 0.0) + eps) / (max(hdr, 0.0) + eps)));
        return max(e.r, max(e.g, e.b));
    }
    float yh = max(dot(hdr, lumaW), 0.0);
    float yr = max(dot(rec, lumaW), 0.0);
    return log2((yr + eps) / (yh + eps));
}

// sRGB-encoded palette colors → linear (the kernel writes linear values).
float3 toLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

}

/// Heatmap over a dimmed grayscale of the SDR base: color = error class, opacity = |error| / fullScale
/// (linear, so sub-JND quantization noise of a few hundredths of a stop stays nearly invisible),
/// fully opaque from fullScale up.
extern "C" float4 reconstructionErrorHeat(coreimage::sample_t hdr, coreimage::sample_t rec,
                                          coreimage::sample_t base, float metric, float fullScale,
                                          float eps, float3 lumaW) [[stitchable]] {
    float e = errorStops(hdr.rgb, rec.rgb, metric, eps, lumaW);
    float t = clamp(abs(e) / fullScale, 0.0, 1.0);

    float3 color;
    if (metric < 0.5) {
        // Sequential: yellow → orange → red.
        float3 yellow = float3(1.0, 0.9, 0.0), orange = float3(1.0, 0.5, 0.0), red = float3(0.9, 0.0, 0.1);
        color = t < 0.5 ? mix(yellow, orange, t * 2.0) : mix(orange, red, (t - 0.5) * 2.0);
    } else {
        // Diverging: blue = rebuilt darker, red = rebuilt brighter.
        color = e < 0.0 ? float3(0.25, 0.55, 1.0) : float3(1.0, 0.25, 0.15);
    }

    float3 background = float3(dot(clamp(base.rgb, 0.0, 1.0), lumaW) * 0.2);
    return float4(mix(background, toLinear(color), t), 1.0);
}

/// Per-pixel |error| (R) and whether it exceeds `threshold` (G), for a CIAreaAverage summary.
extern "C" float4 reconstructionErrorValue(coreimage::sample_t hdr, coreimage::sample_t rec,
                                           float metric, float eps, float3 lumaW,
                                           float threshold) [[stitchable]] {
    float e = abs(errorStops(hdr.rgb, rec.rgb, metric, eps, lumaW));
    return float4(e, e > threshold ? 1.0 : 0.0, 0.0, 1.0);
}
