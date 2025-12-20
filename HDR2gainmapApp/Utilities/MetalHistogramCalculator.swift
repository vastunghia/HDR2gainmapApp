import Foundation
import Metal
import MetalKit
import CoreImage
import Accelerate  // Optional: used for vImage conversions (experiments)

/// Computes SDR/HDR histograms and peak luminance using Metal compute shaders.
class MetalHistogramCalculator {
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let histogramPipeline: MTLComputePipelineState
    private let histogramPQPipeline: MTLComputePipelineState
    private let maxLuminancePipeline: MTLComputePipelineState  // Nuovo
    
    // Reusable buffers
    private var edgesBuffer: MTLBuffer?
    private var histogramBuffers: [MTLBuffer] = []  // R, G, B, Y
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            // print("❌ Metal not available")
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        // Load the default Metal library (Xcode builds .metal files automatically).
        guard let library = device.makeDefaultLibrary() else {
            // print("❌ Failed to create default Metal library")
            return nil
        }
        
        // print("✅ Metal library loaded from .metal file")
        
        guard let histogramFunction = library.makeFunction(name: "calculateHistogram") else {
            // print("❌ Failed to create 'calculateHistogram' function")
            // print("   Available functions: \(library.functionNames)")
            return nil
        }
        
        // print("✅ Metal 'calculateHistogram' function created")
        
        guard let histogramPQFunction = library.makeFunction(name: "calculateHistogramPQ") else {
            // print("❌ Failed to create 'calculateHistogramPQ' function")
            // print("   Available functions: \(library.functionNames)")
            return nil
        }
        
        // print("✅ Metal 'calculateHistogramPQ' function created")
        
        guard let maxLuminanceFunction = library.makeFunction(name: "calculateMaxLuminance") else {
            // print("❌ Failed to create 'calculateMaxLuminance' function")
            // print("   Available functions: \(library.functionNames)")
            return nil
        }
        
        // print("✅ Metal 'calculateMaxLuminance' function created")
        
        
        do {
            self.histogramPipeline = try device.makeComputePipelineState(function: histogramFunction)
            self.histogramPQPipeline = try device.makeComputePipelineState(function: histogramPQFunction)
            self.maxLuminancePipeline = try device.makeComputePipelineState(function: maxLuminanceFunction)
            // print("✅ Metal compute pipelines created (SDR + HDR + Headroom)")
        } catch {
            // print("❌ Failed to create Metal pipeline: \(error)")
            return nil
        }
        
        // print("✅ Metal histogram calculator initialized")
    }
    
    /// Computes an SDR histogram using Metal (typically much faster than the CPU implementation).
    func calculateHistogramFromSDR(
        ciImage: CIImage,
        context: CIContext,
        smoothWindow: Int = 11
    ) -> HistogramCalculator.HistogramResult? {
        
        // let startTime = CFAbsoluteTimeGetCurrent()
        
        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        
        guard width > 0, height > 0 else {
            // print("❌ Invalid image dimensions")
            return nil
        }
        
        // 1) Prepare bin edges (same as HistogramCalculator)
        let edgesU = Self.calculateBinEdges(
            binsSdr: 256,
            uMax: Constants.maxHistogramNit / Constants.referenceHDRwhiteNit
        )
        let binCount = edgesU.count - 1
        
        // 2) Create/update the edges buffer (reused across calls)
        if edgesBuffer == nil || edgesBuffer!.length != edgesU.count * MemoryLayout<Float>.size {
            edgesBuffer = device.makeBuffer(
                bytes: edgesU,
                length: edgesU.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
        } else {
            // Riusa buffer esistente
            memcpy(edgesBuffer!.contents(), edgesU, edgesU.count * MemoryLayout<Float>.size)
        }
        
        // 3) Create histogram buffers (atomic_uint for thread-safety)
        // Ogni buffer: binCount × 4 bytes (atomic_uint)
        let histBufferSize = binCount * MemoryLayout<UInt32>.size
        
        if histogramBuffers.count != 4 {
            histogramBuffers = (0..<4).map { _ in
                device.makeBuffer(length: histBufferSize, options: .storageModeShared)!
            }
        }
        
        // Reset to zero
        for buffer in histogramBuffers {
            memset(buffer.contents(), 0, histBufferSize)
        }
        
        // 4) Render the image into a Metal texture
        guard let texture = renderToMetalTexture(ciImage: ciImage, context: context) else {
            // print("❌ Failed to create Metal texture")
            return nil
        }
        
        // 5) Run the histogram compute shader
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            // print("❌ Failed to create command buffer")
            return nil
        }
        
        computeEncoder.setComputePipelineState(histogramPipeline)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(edgesBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(histogramBuffers[0], offset: 0, index: 1)  // R
        computeEncoder.setBuffer(histogramBuffers[1], offset: 0, index: 2)  // G
        computeEncoder.setBuffer(histogramBuffers[2], offset: 0, index: 3)  // B
        computeEncoder.setBuffer(histogramBuffers[3], offset: 0, index: 4)  // Y
        
        var params = HistogramParams(
            binCount: UInt32(binCount),
            referenceWhiteNit: Constants.referenceHDRwhiteNit
        )
        computeEncoder.setBytes(&params, length: MemoryLayout<HistogramParams>.size, index: 5)
        
        // Dispatch threads (1 thread per pixel)
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // 6) Read back results from the buffers
        var redHist = [UInt32](repeating: 0, count: binCount)
        var greenHist = [UInt32](repeating: 0, count: binCount)
        var blueHist = [UInt32](repeating: 0, count: binCount)
        var lumaHist = [UInt32](repeating: 0, count: binCount)
        
        memcpy(&redHist, histogramBuffers[0].contents(), histBufferSize)
        memcpy(&greenHist, histogramBuffers[1].contents(), histBufferSize)
        memcpy(&blueHist, histogramBuffers[2].contents(), histBufferSize)
        memcpy(&lumaHist, histogramBuffers[3].contents(), histBufferSize)
        
        // 7) Convert to Float and apply smoothing (CPU is fine here; it is fast).
        let redSmooth = Self.movingAverage(redHist.map { Float($0) }, window: smoothWindow)
        let greenSmooth = Self.movingAverage(greenHist.map { Float($0) }, window: smoothWindow)
        let blueSmooth = Self.movingAverage(blueHist.map { Float($0) }, window: smoothWindow)
        let lumaSmooth = Self.movingAverage(lumaHist.map { Float($0) }, window: smoothWindow)
        
        // 8) Compute bin centers and X positions
        var centersU = [Float]()
        var centersNit = [Float]()
        
        for i in 0..<binCount {
            let centerU = (edgesU[i] + edgesU[i + 1]) / 2.0
            centersU.append(centerU)
            centersNit.append(centerU * Constants.referenceHDRwhiteNit)
        }
        
        let xCenters = Self.nitsToX(centersNit, white: Constants.referenceHDRwhiteNit)
        
        // let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        // print("✅ Metal SDR histogram calculated in \(String(format: "%.3f", elapsed))s")
        // print("   Bins: \(binCount), Resolution: \(width)×\(height)")
        
        return HistogramCalculator.HistogramResult(
            xCenters: xCenters,
            centersNit: centersNit,
            redCounts: redSmooth,
            greenCounts: greenSmooth,
            blueCounts: blueSmooth,
            lumaCounts: lumaSmooth
        )
    }
    
    /// Computes an HDR histogram using Metal from 16-bit PQ samples.
    func calculateHistogramFromHDR(
        fromBytes bytes: [UInt8],
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        componentsPerPixel: Int,
        isBigEndian: Bool,
        smoothWindow: Int = 11
    ) -> HistogramCalculator.HistogramResult? {
        
        // print("   🔍 [calculateHistogramFromHDR] Starting...")
        
        guard bitsPerComponent == 16 else {
            // print("❌ Metal HDR histogram requires 16-bit input")
            return nil
        }
        
        // let startTime = CFAbsoluteTimeGetCurrent()
        
        // 1) Create the texture Metal da raw bytes
        guard let texture = createTextureFromRawBytes(
            bytes: bytes,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            componentsPerPixel: componentsPerPixel,
            isBigEndian: isBigEndian
        ) else {
            // print("❌ Failed to create Metal texture from raw bytes")
            return nil
        }
        
        // 2) Prepare bin edges
        let edgesU = Self.calculateBinEdges(
            binsSdr: 256,
            uMax: Constants.maxHistogramNit / Constants.referenceHDRwhiteNit
        )
        let binCount = edgesU.count - 1
        
        // 3) Create/update the edges buffer
        if edgesBuffer == nil || edgesBuffer!.length != edgesU.count * MemoryLayout<Float>.size {
            edgesBuffer = device.makeBuffer(
                bytes: edgesU,
                length: edgesU.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
        } else {
            memcpy(edgesBuffer!.contents(), edgesU, edgesU.count * MemoryLayout<Float>.size)
        }
        
        // 4) Create histogram buffers
        let histBufferSize = binCount * MemoryLayout<UInt32>.size
        
        if histogramBuffers.count != 4 {
            histogramBuffers = (0..<4).map { _ in
                device.makeBuffer(length: histBufferSize, options: .storageModeShared)!
            }
        }
        
        // Reset to zero
        for buffer in histogramBuffers {
            memset(buffer.contents(), 0, histBufferSize)
        }
        
        // 5) Run the PQ compute shader
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            // print("❌ Failed to create command buffer")
            return nil
        }
        
        computeEncoder.setComputePipelineState(histogramPQPipeline)  // Use the PQ-aware pipeline.
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(edgesBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(histogramBuffers[0], offset: 0, index: 1)
        computeEncoder.setBuffer(histogramBuffers[1], offset: 0, index: 2)
        computeEncoder.setBuffer(histogramBuffers[2], offset: 0, index: 3)
        computeEncoder.setBuffer(histogramBuffers[3], offset: 0, index: 4)
        
        var params = HistogramParams(
            binCount: UInt32(binCount),
            referenceWhiteNit: Constants.referenceHDRwhiteNit
        )
        computeEncoder.setBytes(&params, length: MemoryLayout<HistogramParams>.size, index: 5)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // 6) Read back results
        var redHist = [UInt32](repeating: 0, count: binCount)
        var greenHist = [UInt32](repeating: 0, count: binCount)
        var blueHist = [UInt32](repeating: 0, count: binCount)
        var lumaHist = [UInt32](repeating: 0, count: binCount)
        
        memcpy(&redHist, histogramBuffers[0].contents(), histBufferSize)
        memcpy(&greenHist, histogramBuffers[1].contents(), histBufferSize)
        memcpy(&blueHist, histogramBuffers[2].contents(), histBufferSize)
        memcpy(&lumaHist, histogramBuffers[3].contents(), histBufferSize)
        
        // 7) Smoothing
        let redSmooth = Self.movingAverage(redHist.map { Float($0) }, window: smoothWindow)
        let greenSmooth = Self.movingAverage(greenHist.map { Float($0) }, window: smoothWindow)
        let blueSmooth = Self.movingAverage(blueHist.map { Float($0) }, window: smoothWindow)
        let lumaSmooth = Self.movingAverage(lumaHist.map { Float($0) }, window: smoothWindow)
        
        // 8) Bin centers
        var centersU = [Float]()
        var centersNit = [Float]()
        
        for i in 0..<binCount {
            let centerU = (edgesU[i] + edgesU[i + 1]) / 2.0
            centersU.append(centerU)
            centersNit.append(centerU * Constants.referenceHDRwhiteNit)
        }
        
        let xCenters = Self.nitsToX(centersNit, white: Constants.referenceHDRwhiteNit)
        
        // let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        // print("✅ Metal HDR histogram calculated in \(String(format: "%.3f", elapsed))s")
        // print("   Bins: \(binCount), Resolution: \(width)×\(height)")
        
        return HistogramCalculator.HistogramResult(
            xCenters: xCenters,
            centersNit: centersNit,
            redCounts: redSmooth,
            greenCounts: greenSmooth,
            blueCounts: blueSmooth,
            lumaCounts: lumaSmooth
        )
    }
    
    // Create a Metal texture from raw 16-bit samples (optimized).
    private func createTextureFromRawBytes(
        bytes: [UInt8],
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        componentsPerPixel: Int,
        isBigEndian: Bool
    ) -> MTLTexture? {
        
        // Validation
        guard width > 0 && height > 0 else {
            // print("❌ Invalid dimensions: width=\(width), height=\(height)")
            return nil
        }
        
        guard bitsPerComponent == 16 else {
            // print("❌ Invalid bitsPerComponent: \(bitsPerComponent) (expected 16)")
            return nil
        }
        
        // : Metal requires RGBA (4 components), while the HDR input is RGB (3).
        // We convert RGB → RGBA by appending an alpha channel (65535).
        
        let pixelCount = width * height
        var rgbaBytes = [UInt8]()
        rgbaBytes.reserveCapacity(pixelCount * 4 * 2)  // 4 componenti × 2 bytes
        
        let bytesPerPixel = componentsPerPixel * 2  // 16-bit = 2 bytes per component
        
        // print("🔍 Converting RGB → RGBA...")
        // print("   Input: \(componentsPerPixel) components, Output: 4 components (RGBA)")
        
        for pixelIdx in 0..<pixelCount {
            let srcOffset = pixelIdx * bytesPerPixel
            
            // Leggi R, G, B (16-bit each)
            let r0 = bytes[srcOffset + 0]
            let r1 = bytes[srcOffset + 1]
            let g0 = bytes[srcOffset + 2]
            let g1 = bytes[srcOffset + 3]
            let b0 = bytes[srcOffset + 4]
            let b1 = bytes[srcOffset + 5]
            
            // Scrivi R, G, B, A
            if isBigEndian {
                // Swap bytes for big-endian input.
                rgbaBytes.append(r1)
                rgbaBytes.append(r0)
                rgbaBytes.append(g1)
                rgbaBytes.append(g0)
                rgbaBytes.append(b1)
                rgbaBytes.append(b0)
                rgbaBytes.append(0xFF)  // Alpha = 65535 (big-endian)
                rgbaBytes.append(0xFF)
            } else {
                // Little-endian (native).
                rgbaBytes.append(r0)
                rgbaBytes.append(r1)
                rgbaBytes.append(g0)
                rgbaBytes.append(g1)
                rgbaBytes.append(b0)
                rgbaBytes.append(b1)
                rgbaBytes.append(0xFF)  // Alpha = 65535 (little-endian)
                rgbaBytes.append(0xFF)
            }
        }
        
        // print("✅ Conversion complete: \(rgbaBytes.count) bytes")
        
        // Create an RGBA texture
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Uint,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            // print("❌ Failed to create Metal texture")
            return nil
        }
        
        // bytesPerRow is now correct (4 components).
        let bytesPerRow = width * 4 * 2  // RGBA × 16-bit
        
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: rgbaBytes,
            bytesPerRow: bytesPerRow
        )
        
        // print("✅ Texture uploaded successfully")
        return texture
    }
    
    
    
    
    // MARK: - Render CIImage to a Metal texture
    
    private func renderToMetalTexture(ciImage: CIImage, context: CIContext) -> MTLTexture? {
        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]  // Required for CIContext rendering.
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }
        
        // Render the CIImage into the Metal texture using CIContext.
        context.render(ciImage,
                       to: texture,
                       commandBuffer: nil,
                       bounds: ciImage.extent,
                       colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        
        return texture
    }
    
    // MARK: - Helpers (mirrors HistogramCalculator for consistency).
    
    private static func calculateBinEdges(
        binsSdr: Int = 256,
        uMax: Float = Constants.maxHistogramNit / Constants.referenceHDRwhiteNit,
        nMin: Int = 64,
        nMax: Int = 4096
    ) -> [Float] {
        
        let yEdges = stride(from: 0.0, through: 1.0, by: 1.0 / Float(binsSdr))
            .map { Float($0) }
        let uSdr = srgbDecode(yEdges)
        
        var uSdrCorrected = uSdr
        uSdrCorrected[uSdrCorrected.count - 1] = 1.0
        
        let wS = uSdrCorrected[uSdrCorrected.count - 1] - uSdrCorrected[uSdrCorrected.count - 2]
        
        let L = log2(uMax)
        let denom = log2(1.0 + wS)
        let nStar = denom > 0 ? Int(round(L / denom)) : nMin
        let N = max(nMin, min(nMax, nStar))
        
        let hdrEdges = stride(from: 0.0, through: Double(log2(uMax)), by: Double(log2(uMax)) / Double(N))
            .map { Float(pow(2.0, $0)) }
        
        return uSdrCorrected + hdrEdges.dropFirst()
    }
    
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
    
    private static func nitsToX(_ nits: [Float], white: Float = Constants.referenceHDRwhiteNit) -> [Float] {
        let X_AT_REF_WHITE: Float = 0.5
        
        return nits.map { n in
            if n <= white {
                let y = n / white
                let encoded = srgbEncode([y])[0]
                return X_AT_REF_WHITE * encoded
            } else {
                let t = max(0, min(1, log2(n / white) / Constants.displayedHeadroomInStops))
                return X_AT_REF_WHITE + (1.0 - X_AT_REF_WHITE) * t
            }
        }
    }
    
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
    
    /// Computes peak luminance (headroom) using Metal (typically much faster than the CPU implementation).
    func calculatePeakLuminance(
        fromBytes bytes: [UInt8],
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        componentsPerPixel: Int,
        isBigEndian: Bool
    ) -> Float? {
        
        // print("   🔍 [calculatePeakLuminance] Starting...")
        // print("      Resolution: \(width)×\(height)")
        // print("      Bytes: \(bytes.count)")
        // print("      Components: \(componentsPerPixel)")
        
        guard bitsPerComponent == 16 else {
            // print("   ❌ Metal headroom calculation requires 16-bit input")
            return nil
        }
        
        // Validation: Ensure the input buffer is large enough.
        let expectedBytes = width * height * 4 * 2  // RGBA 16-bit
        guard bytes.count >= expectedBytes else {
            // print("   ❌ Not enough bytes: \(bytes.count) < \(expectedBytes)")
            return nil
        }
        
//        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Create the texture
        guard let texture = createTextureFromRawBytes(
            bytes: bytes,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            componentsPerPixel: componentsPerPixel,
            isBigEndian: isBigEndian
        ) else {
            // print("   ❌ Failed to create Metal texture for peak calculation")
            return nil
        }
        
        // 2) Crea buffer per atomic max (1 uint)
        guard let maxBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else {
            // print("❌ Failed to create max buffer")
            return nil
        }
        
        // Reset to zero
        memset(maxBuffer.contents(), 0, MemoryLayout<UInt32>.size)
        
        // 3) Esegui compute shader
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            // print("❌ Failed to create command buffer")
            return nil
        }
        
        computeEncoder.setComputePipelineState(maxLuminancePipeline)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(maxBuffer, offset: 0, index: 0)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // 4) Read back the result
        let maxMilliNitsPtr = maxBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let maxMilliNits = maxMilliNitsPtr[0]
        let maxNits = Float(maxMilliNits) / 1000.0
        
        // let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        // print("✅ Metal peak luminance calculated in \(String(format: "%.3f", elapsed))s")
        // print("   Peak: \(String(format: "%.1f", maxNits)) nit, Resolution: \(width)×\(height)")
        
        // print("   📊 Peak luminance result:")
        // print("      Max milli-nits (raw): \(maxMilliNits)")
        // print("      Max nits: \(maxNits)")
        
        // Validation
        if maxNits < 100 {
            // print("   ⚠️ WARNING: Peak is very low (\(maxNits) nit)")
            // print("      This might indicate black/corrupt image")
        }
        
        if maxNits == 0 {
            // print("   ❌ ERROR: Peak is 0! Image data might be all black")
            return nil
        }
        
        // let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        // print("   ✅ Metal peak luminance calculated in \(String(format: "%.3f", elapsed))s")
        // print("      Peak: \(String(format: "%.1f", maxNits)) nit, Resolution: \(width)×\(height)")
        
        return maxNits
    }
}

// MARK: - Supporting Types

private struct HistogramParams {
    let binCount: UInt32
    let referenceWhiteNit: Float
}
