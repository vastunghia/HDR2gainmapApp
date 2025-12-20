import Foundation
import CoreImage

/// Computes HDR and SDR histograms using a two-segment X axis.
/// SDR (≤ reference white) follows an sRGB-shaped curve; HDR (> reference white) maps logarithmically in stops.
class HistogramCalculator {
    
    // MARK: - Layout Constants (from the reference Python implementation)
    
    static let X_AT_REF_WHITE: Float = 0.5          // position of Constants.referenceHDRwhiteNit on x-axis
    
    // MARK: - Transfer Functions
    
    /// ST-2084 (PQ) EOTF: code → linear relative luminance [0..1] where 1 = 10k nit
    private static func pqEOTF(_ v: [Float]) -> [Float] {
        let m1: Float = 2610.0 / 16384.0
        let m2: Float = 2523.0 / 32.0
        let c1: Float = 3424.0 / 4096.0
        let c2: Float = 2413.0 / 128.0
        let c3: Float = 2392.0 / 128.0
        
        return v.map { val in
            let v = max(0, min(1, val))
            let vp = pow(v, 1.0 / m2)
            let num = max(vp - c1, 0)
            let den = c2 - c3 * vp
            return pow(num / den, 1.0 / m1)
        }
    }
    
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
    
    /// Symmetric moving average (odd window)
    private static func movingAverage(_ y: [Float], window: Int = 11) -> [Float] {
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
    
    /// Histogram output (reference type for NSCache compatibility).
    class HistogramResult {
        let xCenters: [Float]        // X positions [0..1] of bin centers
        let centersNit: [Float]      // Nit values corresponding to bin centers
        let redCounts: [Float]       // Smoothed counts for R
        let greenCounts: [Float]     // Smoothed counts for G
        let blueCounts: [Float]      // Smoothed counts for B
        let lumaCounts: [Float]      // Smoothed counts for luma (Y)
        
        init(xCenters: [Float], centersNit: [Float], redCounts: [Float], greenCounts: [Float], blueCounts: [Float], lumaCounts: [Float]) {
            self.xCenters = xCenters
            self.centersNit = centersNit
            self.redCounts = redCounts
            self.greenCounts = greenCounts
            self.blueCounts = blueCounts
            self.lumaCounts = lumaCounts
        }
    }
    
    /// Computes an HDR histogram from 16-bit PQ pixel bytes.
    static func calculateHistogram(
        fromBytes bytes: [UInt8],
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        componentsPerPixel: Int,
        isBigEndian: Bool,
        smoothWindow: Int = 11
    ) -> HistogramResult? {
        
        guard bitsPerComponent == 16 else {
            // print("❌ Histogram requires 16-bit input")
            return nil
        }
        
        // let startTime = CFAbsoluteTimeGetCurrent()
        
        // 1) Compute bin edges
        let edgesU = calculateBinEdges(binsSdr: 256, uMax: Constants.maxHistogramNit / Constants.referenceHDRwhiteNit)
        let binCount = edgesU.count - 1
        
        // 2) Initialize counters
        var redHist = [Int](repeating: 0, count: binCount)
        var greenHist = [Int](repeating: 0, count: binCount)
        var blueHist = [Int](repeating: 0, count: binCount)
        var lumaHist = [Int](repeating: 0, count: binCount)
        
        // 3) Process pixels
        let bytesPerRow = width * componentsPerPixel * 2  // 16-bit = 2 bytes
        let pixelStride = componentsPerPixel * 2
        
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            
            for x in 0..<width {
                let pixelStart = rowStart + x * pixelStride
                
                // Read 16-bit PQ code values [0..65535]
                let r16: UInt16
                let g16: UInt16
                let b16: UInt16
                
                if isBigEndian {
                    r16 = (UInt16(bytes[pixelStart + 0]) << 8) | UInt16(bytes[pixelStart + 1])
                    g16 = (UInt16(bytes[pixelStart + 2]) << 8) | UInt16(bytes[pixelStart + 3])
                    b16 = (UInt16(bytes[pixelStart + 4]) << 8) | UInt16(bytes[pixelStart + 5])
                } else {
                    r16 = UInt16(bytes[pixelStart + 0]) | (UInt16(bytes[pixelStart + 1]) << 8)
                    g16 = UInt16(bytes[pixelStart + 2]) | (UInt16(bytes[pixelStart + 3]) << 8)
                    b16 = UInt16(bytes[pixelStart + 4]) | (UInt16(bytes[pixelStart + 5]) << 8)
                }
                
                // Normalize to [0..1]
                let rCode = Float(r16) / 65535.0
                let gCode = Float(g16) / 65535.0
                let bCode = Float(b16) / 65535.0
                
                // PQ EOTF → linear [0..1] where 1 = 10k nit
                let rLin = pqEOTF([rCode])[0]
                let gLin = pqEOTF([gCode])[0]
                let bLin = pqEOTF([bCode])[0]
                
                // Convert to u-space (relative to reference white)
                let scale = 10000.0 / Constants.referenceHDRwhiteNit  // = 100
                let rU = rLin * scale
                let gU = gLin * scale
                let bU = bLin * scale
                
                // Linear luma
                let yLin = 0.2126 * rLin + 0.7152 * gLin + 0.0722 * bLin
                let yU = yLin * scale
                
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
        
        // 4) Convert counts to Float and apply smoothing
        let redSmooth = movingAverage(redHist.map { Float($0) }, window: smoothWindow)
        let greenSmooth = movingAverage(greenHist.map { Float($0) }, window: smoothWindow)
        let blueSmooth = movingAverage(blueHist.map { Float($0) }, window: smoothWindow)
        let lumaSmooth = movingAverage(lumaHist.map { Float($0) }, window: smoothWindow)
        
        // 5) Compute bin centers in u-space and nits
        var centersU = [Float]()
        var centersNit = [Float]()
        
        for i in 0..<binCount {
            let centerU = (edgesU[i] + edgesU[i + 1]) / 2.0
            centersU.append(centerU)
            centersNit.append(centerU * Constants.referenceHDRwhiteNit)
        }
        
        // 6) Map centers to X positions in [0..1]
        let xCenters = nitsToX(centersNit, white: Constants.referenceHDRwhiteNit)
        
        //        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        // print("✅ Histogram calculated in \(String(format: "%.3f", elapsed))s")
        // print("   Bins: \(binCount), Range: 0..\(Constants.maxHistogramNit) nit")
        
        return HistogramResult(
            xCenters: xCenters,
            centersNit: centersNit,
            redCounts: redSmooth,
            greenCounts: greenSmooth,
            blueCounts: blueSmooth,
            lumaCounts: lumaSmooth,
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
        let redSmooth = movingAverage(redHist.map { Float($0) }, window: smoothWindow)
        let greenSmooth = movingAverage(greenHist.map { Float($0) }, window: smoothWindow)
        let blueSmooth = movingAverage(blueHist.map { Float($0) }, window: smoothWindow)
        let lumaSmooth = movingAverage(lumaHist.map { Float($0) }, window: smoothWindow)
        
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
            centersNit: centersNit,
            redCounts: redSmooth,
            greenCounts: greenSmooth,
            blueCounts: blueSmooth,
            lumaCounts: lumaSmooth
        )
    }
    
}
