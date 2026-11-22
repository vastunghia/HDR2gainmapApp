#include <metal_stdlib>
using namespace metal;

// MARK: - Transfer functions

struct HistogramParams {
    uint binCount;
    float referenceWhiteNit;
};

// sRGB EOTF (code value -> linear light)
float srgbEOTF(float code) {
    float c = clamp(code, 0.0f, 1.0f);
    if (c <= 0.04045f) {
        return c / 12.92f;
    } else {
        float base = (c + 0.055f) / 1.055f;
        return pow(base, 2.4f);
    }
}

// Binary search to locate the histogram bin
uint findBin(float value, constant float* edges, uint edgeCount) {
    if (value < edges[0] || value > edges[edgeCount - 1]) {
        return edgeCount;
    }

    uint low = 0;
    uint high = edgeCount - 2;

    while (low <= high) {
        uint mid = (low + high) / 2;
        if (value >= edges[mid] && value < edges[mid + 1]) {
            return mid;
        }
        if (value < edges[mid]) {
            if (mid == 0) break;
            high = mid - 1;
        } else {
            low = mid + 1;
        }
    }

    if (abs(value - edges[edgeCount - 1]) < 1e-6f) {
        return edgeCount - 2;
    }

    return edgeCount;
}

// Bins one pixel's R/G/B/Y — all in u-space (linear, relative to reference white) — into the four
// histograms. Shared by both kernels so they bin identically.
void accumulatePixel(float rU, float gU, float bU, float yU,
                     constant float* edges, uint binCount,
                     device atomic_uint* redHist, device atomic_uint* greenHist,
                     device atomic_uint* blueHist, device atomic_uint* lumaHist) {
    uint edgeCount = binCount + 1;

    uint rBin = findBin(rU, edges, edgeCount);
    if (rBin < binCount) {
        atomic_fetch_add_explicit(&redHist[rBin], 1, memory_order_relaxed);
    }

    uint gBin = findBin(gU, edges, edgeCount);
    if (gBin < binCount) {
        atomic_fetch_add_explicit(&greenHist[gBin], 1, memory_order_relaxed);
    }

    uint bBin = findBin(bU, edges, edgeCount);
    if (bBin < binCount) {
        atomic_fetch_add_explicit(&blueHist[bBin], 1, memory_order_relaxed);
    }

    uint yBin = findBin(yU, edges, edgeCount);
    if (yBin < binCount) {
        atomic_fetch_add_explicit(&lumaHist[yBin], 1, memory_order_relaxed);
    }
}

// SDR histogram kernel: display-referred P3 code values (sRGB transfer), decoded to linear u-space.
kernel void calculateHistogram(
                               texture2d<half, access::read> inputTexture [[texture(0)]],
                               constant float* edges [[buffer(0)]],
                               device atomic_uint* redHist [[buffer(1)]],
                               device atomic_uint* greenHist [[buffer(2)]],
                               device atomic_uint* blueHist [[buffer(3)]],
                               device atomic_uint* lumaHist [[buffer(4)]],
                               constant HistogramParams& params [[buffer(5)]],
                               uint2 gid [[thread_position_in_grid]]
                               ) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }

    half4 pixel = inputTexture.read(gid);

    // sRGB EOTF → linear, where 1.0 is SDR white (= reference white), i.e. already u-space.
    float rU = srgbEOTF(float(pixel.r));
    float gU = srgbEOTF(float(pixel.g));
    float bU = srgbEOTF(float(pixel.b));
    float yU = 0.2126f * rU + 0.7152f * gU + 0.0722f * bU;

    accumulatePixel(rU, gU, bU, yU, edges, params.binCount, redHist, greenHist, blueHist, lumaHist);
}

// HDR histogram kernel: the resident linear image (extended-linear Display P3, float, linear 1.0 =
// reference white) — already u-space. Core Image decoded the file (PQ or HLG, any primaries) into
// this, so no transfer function is applied here.
kernel void calculateHistogramLinear(
                                     texture2d<float, access::read> inputTexture [[texture(0)]],
                                     constant float* edges [[buffer(0)]],
                                     device atomic_uint* redHist [[buffer(1)]],
                                     device atomic_uint* greenHist [[buffer(2)]],
                                     device atomic_uint* blueHist [[buffer(3)]],
                                     device atomic_uint* lumaHist [[buffer(4)]],
                                     constant HistogramParams& params [[buffer(5)]],
                                     uint2 gid [[thread_position_in_grid]]
                                     ) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }

    float4 pixel = inputTexture.read(gid);
    // Display P3 luminance weights (= Constants.displayP3LumaWeights).
    float yU = 0.2290f * pixel.r + 0.6917f * pixel.g + 0.0793f * pixel.b;

    accumulatePixel(pixel.r, pixel.g, pixel.b, yU, edges, params.binCount,
                    redHist, greenHist, blueHist, lumaHist);
}

// Peak Display P3 luminance of the linear image (= the measured headroom, since linear 1.0 is
// reference white). Finite non-negative floats order like their bit patterns, so an atomic max over
// the bits is an exact float max; non-finite and non-positive values are skipped (the CPU twin,
// HDRProcessor.peakLuminance, does the same).
kernel void maxLuminanceLinear(
                               texture2d<float, access::read> inputTexture [[texture(0)]],
                               device atomic_uint* peakBits [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]
                               ) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    float4 pixel = inputTexture.read(gid);
    float y = 0.2290f * pixel.r + 0.6917f * pixel.g + 0.0793f * pixel.b;
    if (isfinite(y) && y > 0.0f) {
        atomic_fetch_max_explicit(peakBits, as_type<uint>(y), memory_order_relaxed);
    }
}

struct LuminanceBinParams {
    uint binCount;
    float scale;   // bins per linear unit: binCount / range
};

// Uniform luminance histogram over [0, range] for the percentile CDF: bin = floor(y × scale),
// negative → first bin, ≥ binCount → last bin (NaN → first). Same as HDRProcessor.luminanceBins.
kernel void luminanceBinsLinear(
                                texture2d<float, access::read> inputTexture [[texture(0)]],
                                device atomic_uint* bins [[buffer(0)]],
                                constant LuminanceBinParams& params [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]
                                ) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    float4 pixel = inputTexture.read(gid);
    float v = (0.2290f * pixel.r + 0.6917f * pixel.g + 0.0793f * pixel.b) * params.scale;
    uint idx = v >= 1.0f ? (v < float(params.binCount) ? uint(v) : params.binCount - 1) : 0;
    atomic_fetch_add_explicit(&bins[idx], 1, memory_order_relaxed);
}
