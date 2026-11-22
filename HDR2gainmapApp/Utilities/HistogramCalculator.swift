import Foundation
import CoreImage

/// Computes HDR and SDR histograms using a two-segment X axis.
/// SDR (≤ reference white) follows an sRGB-shaped curve; HDR (> reference white) maps logarithmically in stops.
/// `nonisolated` (pure CPU compute on raw bytes) so it can run on the off-main histogram path
/// without hopping back to the main actor — see [[concurrency-model]].
nonisolated class HistogramCalculator {
    
    // MARK: - Layout Constants (from the reference Python implementation)
    
    static let X_AT_REF_WHITE: Float = 0.5          // position of Constants.referenceHDRwhiteNit on x-axis
    
    // MARK: - Transfer Functions
    
    /// sRGB encode (linear → sRGB code, OETF)
    private static func srgbEncode(_ x: [Float]) -> [Float] {
        let a: Float = 0.055
        return x.map { val in
            let x = max(0, min(1, val))
            if x <= 0.0031308 {
                return 12.92 * x
            } else {
                return (1 + a) * pow(x, 1.0 / 2.4) - a
            }
        }
    }
    
    /// sRGB decode (sRGB code → linear, inverse OETF)
    private static func srgbDecode(_ y: [Float]) -> [Float] {
        let a: Float = 0.055
        return y.map { val in
            let y = max(0, min(1, val))
            if y <= 0.04045 {
                return y / 12.92
            } else {
                return pow((y + a) / (1 + a), 2.4)
            }
        }
    }
    
    // MARK: - Mapping: absolute nits → x in [0..1]
    
    /// Maps absolute luminance (nits) to an X position in [0, 1] on the split axis.
    private static func nitsToX(_ nits: [Float], white: Float = Constants.referenceHDRwhiteNit) -> [Float] {
        return nits.map { n in
            if n <= white {
                // SDR: 0..white nit (sRGB-shaped) → [0, X_AT_REF_WHITE]
                let y = n / white
                let encoded = srgbEncode([y])[0]
                return X_AT_REF_WHITE * encoded
            } else {
                // HDR: white..HDR_MAX_NITS (log2) → [X_AT_REF_WHITE, 1]
                let t = max(0, min(1, log2(n / white) / Constants.displayedHeadroomInStops))
                return X_AT_REF_WHITE + (1.0 - X_AT_REF_WHITE) * t
            }
        }
    }
    
    // MARK: - Bin Edges Calculation
    
    /// Computes bin edges with a matched hinge (last SDR bin width ≈ first HDR bin width).
    private static func calculateBinEdges(
        binsSdr: Int = 256,
        uMax: Float = Constants.maxHistogramNit / Constants.referenceHDRwhiteNit,
        nMin: Int = 64,
        nMax: Int = 4096
    ) -> [Float] {
        
        // 1) SDR edges in u (Y/WHITE) space [0..1]
        let yEdges = stride(from: 0.0, through: 1.0, by: 1.0 / Float(binsSdr))
            .map { Float($0) }
        let uSdr = srgbDecode(yEdges)
        
        // Ensure the last value is exactly 1.0
        var uSdrCorrected = uSdr
        uSdrCorrected[uSdrCorrected.count - 1] = 1.0
        
        // 2) Compute the width of the last SDR bin
        let wS = uSdrCorrected[uSdrCorrected.count - 1] - uSdrCorrected[uSdrCorrected.count - 2]
        
        // 3) Choose the number of HDR bins so the first HDR bin width ≈ wS
        let L = log2(uMax)
        let denom = log2(1.0 + wS)
        let nStar = denom > 0 ? Int(round(L / denom)) : nMin
        let N = max(nMin, min(nMax, nStar))
        
        // 4) HDR edges [1..uMax] (logarithmic)
        let hdrEdges = stride(from: 0.0, through: Double(log2(uMax)), by: Double(log2(uMax)) / Double(N))
            .map { Float(pow(2.0, $0)) }
        
        // 5) Concatenate while avoiding the duplicate 1.0 edge
        return uSdrCorrected + hdrEdges.dropFirst()
    }
    
    // MARK: - Moving Average
    
    /// Symmetric moving average (odd window). Exposed so the renderer can smooth at draw time.
    static func movingAverage(_ y: [Float], window: Int = 11) -> [Float] {
        var win = max(1, window)
        if win % 2 == 0 { win += 1 }
        if win == 1 { return y }
        
        let halfWin = win / 2
        var result = [Float](repeating: 0, count: y.count)
        
        for i in 0..<y.count {
            let start = max(0, i - halfWin)
            let end = min(y.count - 1, i + halfWin)
            let sum = y[start...end].reduce(0, +)
            let count = Float(end - start + 1)
            result[i] = sum / count
        }
        
        return result
    }
    
    // MARK: - Histogram Calculation
    
    /// Histogram output (reference type for NSCache compatibility). Immutable, so safe to build
    /// off the main actor and share across threads/caches.
    nonisolated final class HistogramResult: Sendable {
        let xCenters: [Float]        // X positions [0..1] of bin centers
        // let centersNit: [Float]      // Nit values corresponding to bin centers
        let redCounts: [Float]       // Smoothed counts for R
        let greenCounts: [Float]     // Smoothed counts for G
        let blueCounts: [Float]      // Smoothed counts for B
        let lumaCounts: [Float]      // Smoothed counts for luma (Y)
        
        init(xCenters: [Float], redCounts: [Float], greenCounts: [Float], blueCounts: [Float], lumaCounts: [Float]) {
            self.xCenters = xCenters
            self.redCounts = redCounts
            self.greenCounts = greenCounts
            self.blueCounts = blueCounts
            self.lumaCounts = lumaCounts
        }
    }
    
    /// Computes the HDR histogram from the resident linear image: extended-linear Display P3,
    /// RGBA Float32, linear 1.0 = SDR reference white — already the histogram's u-space, so PQ and
    /// HLG inputs are handled alike. CPU fallback of the Metal `calculateHistogramLinear` kernel.
    /// `rowStride` is in floats.
    static func calculateHistogramFromLinear(
        pixels: UnsafePointer<Float>,
        width: Int,
        height: Int,
        rowStride: Int
    ) -> HistogramResult? {
        guard width > 0, height > 0, rowStride >= width * 4 else { return nil }

        let edgesU = calculateBinEdges(binsSdr: 256, uMax: Constants.maxHistogramNit / Constants.referenceHDRwhiteNit)
        let binCount = edgesU.count - 1

        var redHist = [Int](repeating: 0, count: binCount)
        var greenHist = [Int](repeating: 0, count: binCount)
        var blueHist = [Int](repeating: 0, count: binCount)
        var lumaHist = [Int](repeating: 0, count: binCount)

        let (wr, wg, wb) = Constants.displayP3LumaWeights
        for y in 0..<height {
            let row = pixels + y * rowStride
            for x in 0..<width {
                let p = row + x * 4
                let rU = p[0], gU = p[1], bU = p[2]
                let yU = wr * rU + wg * gU + wb * bU
                if let bin = findBin(value: rU, edges: edgesU) { redHist[bin] += 1 }
                if let bin = findBin(value: gU, edges: edgesU) { greenHist[bin] += 1 }
                if let bin = findBin(value: bU, edges: edgesU) { blueHist[bin] += 1 }
                if let bin = findBin(value: yU, edges: edgesU) { lumaHist[bin] += 1 }
            }
        }

        // RAW counts; smoothing is applied at render time so it can be tuned live.
        var centersNit = [Float]()
        centersNit.reserveCapacity(binCount)
        for i in 0..<binCount {
            centersNit.append((edgesU[i] + edgesU[i + 1]) / 2.0 * Constants.referenceHDRwhiteNit)
        }
        return HistogramResult(
            xCenters: nitsToX(centersNit, white: Constants.referenceHDRwhiteNit),
            redCounts: redHist.map { Float($0) },
            greenCounts: greenHist.map { Float($0) },
            blueCounts: blueHist.map { Float($0) },
            lumaCounts: lumaHist.map { Float($0) }
        )
    }
    
    /// Finds the bin index for a given value using precomputed edges.
    private static func findBin(value: Float, edges: [Float]) -> Int? {
        guard value >= edges.first! && value <= edges.last! else {
            return nil
        }
        
        // Binary search
        var low = 0
        var high = edges.count - 2  // last valid bin index
        
        while low <= high {
            let mid = (low + high) / 2
            if value >= edges[mid] && value < edges[mid + 1] {
                return mid
            } else if value < edges[mid] {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        
        // Edge case: value is exactly equal to the last edge
        if abs(value - edges.last!) < 1e-6 {
            return edges.count - 2
        }
        
        return nil
    }
    
    // MARK: - SDR Histogram
    
    /// Computes a histogram for the tone-mapped SDR output.
    /// Converts sRGB code values to nits so it can reuse the same axis as the HDR histogram.
    static func calculateHistogramFromSDR(
        ciImage: CIImage,
        context: CIContext,
        smoothWindow: Int = 11
    ) -> HistogramResult? {
        
        // let startTime = CFAbsoluteTimeGetCurrent()
        
        // 1) Render the SDR image into a bitmap buffer
        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        
        guard width > 0, height > 0 else {
            // print("❌ Invalid image dimensions")
            return nil
        }
        
        // Render a RGB float32
        var buffer = [Float](repeating: 0, count: width * height * 4)
        context.render(
            ciImage,
            toBitmap: &buffer,
            rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: ciImage.extent,
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
        )
        
        // 2) Compute bin edges (same as HDR)
        let edgesU = calculateBinEdges(
            binsSdr: 256,
            uMax: Constants.maxHistogramNit / Constants.referenceHDRwhiteNit
        )
        let binCount = edgesU.count - 1
        
        // 3) Initialize counters
        var redHist = [Int](repeating: 0, count: binCount)
        var greenHist = [Int](repeating: 0, count: binCount)
        var blueHist = [Int](repeating: 0, count: binCount)
        var lumaHist = [Int](repeating: 0, count: binCount)
        
        // 4) Process pixels: sRGB code → linear → nits → u-space
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                
                // Code values [0..1] in sRGB space
                let rCode = buffer[idx + 0]
                let gCode = buffer[idx + 1]
                let bCode = buffer[idx + 2]
                
                // sRGB EOTF → linear [0..1]
                func srgbEOTF(_ code: Float) -> Float {
                    let c = max(0, min(1, code))
                    if c <= 0.04045 {
                        return c / 12.92
                    } else {
                        return pow((c + 0.055) / 1.055, 2.4)
                    }
                }
                
                let rLin = srgbEOTF(rCode)
                let gLin = srgbEOTF(gCode)
                let bLin = srgbEOTF(bCode)
                
                // Linear → absolute nits
                // In SDR, 1.0 linear corresponds to reference white (e.g., 203 nits in this project).
                let rNits = rLin * Constants.referenceHDRwhiteNit
                let gNits = gLin * Constants.referenceHDRwhiteNit
                let bNits = bLin * Constants.referenceHDRwhiteNit
                
                // Linear luma
                let yLin = 0.2126 * rLin + 0.7152 * gLin + 0.0722 * bLin
                let yNits = yLin * Constants.referenceHDRwhiteNit
                
                // Convert nits → u-space (relative to reference white)
                let rU = rNits / Constants.referenceHDRwhiteNit
                let gU = gNits / Constants.referenceHDRwhiteNit
                let bU = bNits / Constants.referenceHDRwhiteNit
                let yU = yNits / Constants.referenceHDRwhiteNit
                
                // Find the bin for each channel
                if let rBin = findBin(value: rU, edges: edgesU) {
                    redHist[rBin] += 1
                }
                if let gBin = findBin(value: gU, edges: edgesU) {
                    greenHist[gBin] += 1
                }
                if let bBin = findBin(value: bU, edges: edgesU) {
                    blueHist[bBin] += 1
                }
                if let yBin = findBin(value: yU, edges: edgesU) {
                    lumaHist[yBin] += 1
                }
            }
        }
        
        // 5) Converti conteggi a Float e applica smoothing
        // Store RAW counts; smoothing is applied at render time so it can be tuned live.
        let redSmooth = redHist.map { Float($0) }
        let greenSmooth = greenHist.map { Float($0) }
        let blueSmooth = blueHist.map { Float($0) }
        let lumaSmooth = lumaHist.map { Float($0) }
        
        // 6) Calcola bin centers in u-space e nit
        var centersU = [Float]()
        var centersNit = [Float]()
        
        for i in 0..<binCount {
            let centerU = (edgesU[i] + edgesU[i + 1]) / 2.0
            centersU.append(centerU)
            centersNit.append(centerU * Constants.referenceHDRwhiteNit)
        }
        
        // 7) Mappa centers a posizioni X [0..1]
        let xCenters = nitsToX(centersNit, white: Constants.referenceHDRwhiteNit)
        
        //        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        // print("✅ SDR histogram calculated in \(String(format: "%.3f", elapsed))s")
        // print("   Bins: \(binCount), Range: 0..\(Constants.maxHistogramNit) nit")
        
        return HistogramResult(
            xCenters: xCenters,
            redCounts: redSmooth,
            greenCounts: greenSmooth,
            blueCounts: blueSmooth,
            lumaCounts: lumaSmooth
        )
    }
    
}
