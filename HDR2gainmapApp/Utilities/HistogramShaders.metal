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

// PQ EOTF (ST 2084) (code value -> linear light)
float pqEOTF(float code) {
    const float m1 = 2610.0f / 16384.0f;
    const float m2 = 2523.0f / 32.0f;
    const float c1 = 3424.0f / 4096.0f;
    const float c2 = 2413.0f / 128.0f;
    const float c3 = 2392.0f / 128.0f;
    
    float v = clamp(code, 0.0f, 1.0f);
    float vp = pow(v, 1.0f / m2);
    float num = max(vp - c1, 0.0f);
    float den = c2 - c3 * vp;
    return pow(num / den, 1.0f / m1);
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

// SDR histogram kernel
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
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    half4 pixel = inputTexture.read(gid);
    float rCode = float(pixel.r);
    float gCode = float(pixel.g);
    float bCode = float(pixel.b);
    
    float rLin = srgbEOTF(rCode);
    float gLin = srgbEOTF(gCode);
    float bLin = srgbEOTF(bCode);
    
    float refWhite = params.referenceWhiteNit;
    float rNits = rLin * refWhite;
    float gNits = gLin * refWhite;
    float bNits = bLin * refWhite;
    
    float yLin = 0.2126f * rLin + 0.7152f * gLin + 0.0722f * bLin;
    float yNits = yLin * refWhite;
    
    float rU = rNits / refWhite;
    float gU = gNits / refWhite;
    float bU = bNits / refWhite;
    float yU = yNits / refWhite;
    
    uint edgeCount = params.binCount + 1;
    
    uint rBin = findBin(rU, edges, edgeCount);
    if (rBin < params.binCount) {
        atomic_fetch_add_explicit(&redHist[rBin], 1, memory_order_relaxed);
    }
    
    uint gBin = findBin(gU, edges, edgeCount);
    if (gBin < params.binCount) {
        atomic_fetch_add_explicit(&greenHist[gBin], 1, memory_order_relaxed);
    }
    
    uint bBin = findBin(bU, edges, edgeCount);
    if (bBin < params.binCount) {
        atomic_fetch_add_explicit(&blueHist[bBin], 1, memory_order_relaxed);
    }
    
    uint yBin = findBin(yU, edges, edgeCount);
    if (yBin < params.binCount) {
        atomic_fetch_add_explicit(&lumaHist[yBin], 1, memory_order_relaxed);
    }
}

// HDR histogram kernel (PQ input)
// HDR path: convert 16-bit integer samples to float on the GPU
kernel void calculateHistogramPQ(
                                 texture2d<ushort, access::read> inputTexture [[texture(0)]],  // ushort input (16-bit), not half
                                 constant float* edges [[buffer(0)]],
                                 device atomic_uint* redHist [[buffer(1)]],
                                 device atomic_uint* greenHist [[buffer(2)]],
                                 device atomic_uint* blueHist [[buffer(3)]],
                                 device atomic_uint* lumaHist [[buffer(4)]],
                                 constant HistogramParams& params [[buffer(5)]],
                                 uint2 gid [[thread_position_in_grid]]
                                 ) {
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    // Read 16-bit samples [0..65535] and normalize to [0..1]
    ushort4 pixel = inputTexture.read(gid);
    float rCode = float(pixel.r) / 65535.0f;
    float gCode = float(pixel.g) / 65535.0f;
    float bCode = float(pixel.b) / 65535.0f;
    
    // PQ EOTF -> linear light (relative), where 1.0 == 10,000 nits
    float rLin = pqEOTF(rCode);
    float gLin = pqEOTF(gCode);
    float bLin = pqEOTF(bCode);
    
    // Convert to u-space (Y / WHITE)
    float scale = 10000.0f / params.referenceWhiteNit;
    float rU = rLin * scale;
    float gU = gLin * scale;
    float bU = bLin * scale;
    
    // Linear luma
    float yLin = 0.2126f * rLin + 0.7152f * gLin + 0.0722f * bLin;
    float yU = yLin * scale;
    
    // Map to histogram bin
    uint edgeCount = params.binCount + 1;
    
    uint rBin = findBin(rU, edges, edgeCount);
    if (rBin < params.binCount) {
        atomic_fetch_add_explicit(&redHist[rBin], 1, memory_order_relaxed);
    }
    
    uint gBin = findBin(gU, edges, edgeCount);
    if (gBin < params.binCount) {
        atomic_fetch_add_explicit(&greenHist[gBin], 1, memory_order_relaxed);
    }
    
    uint bBin = findBin(bU, edges, edgeCount);
    if (bBin < params.binCount) {
        atomic_fetch_add_explicit(&blueHist[bBin], 1, memory_order_relaxed);
    }
    
    uint yBin = findBin(yU, edges, edgeCount);
    if (yBin < params.binCount) {
        atomic_fetch_add_explicit(&lumaHist[yBin], 1, memory_order_relaxed);
    }
}

// Kernel to compute headroom (max luminance)
// Max-luminance kernel with 16-bit input
kernel void calculateMaxLuminance(
                                  texture2d<ushort, access::read> inputTexture [[texture(0)]],  // ushort input (16-bit)
                                  device atomic_uint* maxNitsAtomic [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]
                                  ) {
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    // Read 16-bit samples and normalize
    ushort4 pixel = inputTexture.read(gid);
    float rCode = float(pixel.r) / 65535.0f;
    float gCode = float(pixel.g) / 65535.0f;
    float bCode = float(pixel.b) / 65535.0f;
    
    // PQ EOTF -> linear light (relative), where 1.0 == 10,000 nits
    float rLin = pqEOTF(rCode);
    float gLin = pqEOTF(gCode);
    float bLin = pqEOTF(bCode);
    
    // Linear luma (Rec.709 coefficients)
    float yLin = 0.2126f * rLin + 0.7152f * gLin + 0.0722f * bLin;
    
    // Convert to absolute nits (1.0 linear == 10,000 nits)
    float yNits = yLin * 10000.0f;
    
    // Convert to milli-nits (to preserve precision for atomic uint)
    uint yMilliNits = uint(yNits * 1000.0f);
    
    // Atomic max (thread-safe)
    atomic_fetch_max_explicit(&maxNitsAtomic[0], yMilliNits, memory_order_relaxed);
}
