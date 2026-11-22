import Foundation
import Metal
import MetalKit
import CoreImage
import Accelerate  // Optional: used for vImage conversions (experiments)

/// Computes the SDR histogram and the HDR-input measurements (histogram, peak luminance, percentile
/// luminance buckets) using Metal compute shaders.
/// Not actor-isolated: its public compute methods are serialized with an internal `NSLock`,
/// so a single instance can be shared safely across the main actor and background tasks.
nonisolated final class MetalHistogramCalculator: @unchecked Sendable {
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let histogramPipeline: MTLComputePipelineState        // SDR: display-referred P3
    private let histogramLinearPipeline: MTLComputePipelineState  // HDR: extended-linear P3
    private let maxLuminancePipeline: MTLComputePipelineState     // HDR: peak luminance
    private let luminanceBinsPipeline: MTLComputePipelineState    // HDR: percentile buckets
    
    // Reusable buffers
    private var edgesBuffer: MTLBuffer?
    private var histogramBuffers: [MTLBuffer] = []  // R, G, B, Y

    // Serializes GPU work and the reusable buffers above so the calculator can be safely
    // shared across threads (e.g. background prefetch + main-thread histogram generation).
    private let lock = NSLock()
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              // The default Metal library (Xcode builds HistogramShaders.metal automatically).
              let library = device.makeDefaultLibrary(),
              let histogramFunction = library.makeFunction(name: "calculateHistogram"),
              let histogramLinearFunction = library.makeFunction(name: "calculateHistogramLinear"),
              let maxLuminanceFunction = library.makeFunction(name: "maxLuminanceLinear"),
              let luminanceBinsFunction = library.makeFunction(name: "luminanceBinsLinear") else {
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        do {
            self.histogramPipeline = try device.makeComputePipelineState(function: histogramFunction)
            self.histogramLinearPipeline = try device.makeComputePipelineState(function: histogramLinearFunction)
            self.maxLuminancePipeline = try device.makeComputePipelineState(function: maxLuminanceFunction)
            self.luminanceBinsPipeline = try device.makeComputePipelineState(function: luminanceBinsFunction)
        } catch {
            return nil
        }
    }
    
    /// Computes an SDR histogram using Metal (typically much faster than the CPU implementation).
    func calculateHistogramFromSDR(
        ciImage: CIImage,
        context: CIContext,
        smoothWindow: Int = 11
    ) -> HistogramCalculator.HistogramResult? {
        lock.lock()
        defer { lock.unlock() }

        guard Int(ciImage.extent.width) > 0, Int(ciImage.extent.height) > 0,
              let texture = renderToMetalTexture(ciImage: ciImage, context: context) else {
            return nil
        }
        return runHistogram(pipeline: histogramPipeline, texture: texture)
    }

    /// Results of `measureLinear` (the CPU fallback in `HDRProcessor` produces the same).
    struct LinearMeasurements: Sendable {
        let peakLuminance: Float          // max Display-P3 luminance, 1.0 = reference white; finite, ≥ 0
        let histogram: HistogramCalculator.HistogramResult
        let luminanceBins: [Int]          // uniform luminance histogram over [0, luminanceRange]
        let luminanceRange: Float
    }

    /// Measures the linear HDR image on the GPU from ONE render of it: the HDR-input histogram, the
    /// peak luminance, then a `luminanceBinCount`-bucket luminance histogram over
    /// [0, `luminanceRange(peak)`] (for the percentile CDF). Only these small results come back to
    /// the CPU. `ciImage` must be extended-linear (1.0 = reference white); it is rendered into a
    /// half-float texture in `colorSpace` (≈ 0.05 % precision — finer than any of the bins).
    func measureLinear(
        ciImage: CIImage,
        context: CIContext,
        colorSpace: CGColorSpace,
        luminanceBinCount: Int,
        luminanceRange: (_ peak: Float) -> Float
    ) -> LinearMeasurements? {
        lock.lock()
        defer { lock.unlock() }

        let width = Int(ciImage.extent.width), height = Int(ciImage.extent.height)
        guard width > 0, height > 0, luminanceBinCount > 0 else { return nil }

        // 1) The one render. Waiting on the task guarantees the texture is fully written before our
        //    kernels (on our own command queue) read it.
        let tRender = Prof.tic()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = colorSpace
        do {
            _ = try context.startTask(toRender: ciImage, from: ciImage.extent,
                                      to: destination, at: .zero).waitUntilCompleted()
        } catch {
            return nil
        }
        Prof.toc("metal.linearRender [\(width)×\(height)]", tRender)

        // 2) HDR histogram, 3) peak, 4) percentile buckets over [0, range(peak)].
        guard let histogram = runHistogram(pipeline: histogramLinearPipeline, texture: texture),
              let peak = runPeakLuminance(texture: texture) else {
            return nil
        }
        let range = luminanceRange(peak)
        guard range > 0, range.isFinite,
              let bins = runLuminanceBins(texture: texture, binCount: luminanceBinCount, range: range) else {
            return nil
        }
        return LinearMeasurements(peakLuminance: peak, histogram: histogram,
                                  luminanceBins: bins, luminanceRange: range)
    }

    /// Peak luminance over the texture (`maxLuminanceLinear`). The caller must hold `lock`.
    private func runPeakLuminance(texture: MTLTexture) -> Float? {
        guard let peakBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        memset(peakBuffer.contents(), 0, MemoryLayout<UInt32>.size)  // bit pattern of 0.0
        encoder.setComputePipelineState(maxLuminancePipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(peakBuffer, offset: 0, index: 0)
        dispatchPerPixel(encoder, over: texture)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // The kernel max-reduces the float's bit pattern (exact for finite values ≥ 0).
        return Float(bitPattern: peakBuffer.contents().load(as: UInt32.self))
    }

    /// Uniform luminance buckets over [0, range] (`luminanceBinsLinear`). The caller must hold `lock`.
    private func runLuminanceBins(texture: MTLTexture, binCount: Int, range: Float) -> [Int]? {
        let size = binCount * MemoryLayout<UInt32>.size
        guard let binsBuffer = device.makeBuffer(length: size, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        memset(binsBuffer.contents(), 0, size)
        var params = LuminanceBinParams(binCount: UInt32(binCount), scale: Float(binCount) / range)
        encoder.setComputePipelineState(luminanceBinsPipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(binsBuffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<LuminanceBinParams>.size, index: 1)
        dispatchPerPixel(encoder, over: texture)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let counts = binsBuffer.contents().assumingMemoryBound(to: UInt32.self)
        return (0..<binCount).map { Int(counts[$0]) }
    }

    /// One thread per pixel of `texture`, in 16×16 threadgroups.
    private func dispatchPerPixel(_ encoder: MTLComputeCommandEncoder, over texture: MTLTexture) {
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
    }

    /// Shared dispatch for both histogram kernels (same bin edges, buffers and output layout).
    /// The caller must hold `lock`.
    private func runHistogram(pipeline: MTLComputePipelineState,
                              texture: MTLTexture) -> HistogramCalculator.HistogramResult? {
        // 1) Bin edges (same as HistogramCalculator), reused across calls.
        let edgesU = Self.calculateBinEdges(
            binsSdr: 256,
            uMax: Constants.maxHistogramNit / Constants.referenceHDRwhiteNit
        )
        let binCount = edgesU.count - 1
        let edgesSize = edgesU.count * MemoryLayout<Float>.size
        if edgesBuffer == nil || edgesBuffer!.length != edgesSize {
            edgesBuffer = device.makeBuffer(bytes: edgesU, length: edgesSize, options: .storageModeShared)
        } else {
            memcpy(edgesBuffer!.contents(), edgesU, edgesSize)
        }

        // 2) Histogram buffers (atomic_uint per bin), zeroed.
        let histBufferSize = binCount * MemoryLayout<UInt32>.size
        if histogramBuffers.count != 4 || histogramBuffers[0].length != histBufferSize {
            histogramBuffers = (0..<4).compactMap { _ in
                device.makeBuffer(length: histBufferSize, options: .storageModeShared)
            }
            guard histogramBuffers.count == 4 else { return nil }
        }
        for buffer in histogramBuffers {
            memset(buffer.contents(), 0, histBufferSize)
        }

        // 3) Dispatch (1 thread per pixel).
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        computeEncoder.setComputePipelineState(pipeline)
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

        dispatchPerPixel(computeEncoder, over: texture)
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 4) Read back RAW counts (smoothing is applied at render time so it can be tuned live).
        func counts(_ buffer: MTLBuffer) -> [Float] {
            let ptr = buffer.contents().assumingMemoryBound(to: UInt32.self)
            return (0..<binCount).map { Float(ptr[$0]) }
        }

        // 5) Bin centers → X positions.
        var centersNit = [Float]()
        centersNit.reserveCapacity(binCount)
        for i in 0..<binCount {
            centersNit.append((edgesU[i] + edgesU[i + 1]) / 2.0 * Constants.referenceHDRwhiteNit)
        }
        let xCenters = Self.nitsToX(centersNit, white: Constants.referenceHDRwhiteNit)

        return HistogramCalculator.HistogramResult(
            xCenters: xCenters,
            redCounts: counts(histogramBuffers[0]),
            greenCounts: counts(histogramBuffers[1]),
            blueCounts: counts(histogramBuffers[2]),
            lumaCounts: counts(histogramBuffers[3])
        )
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
}

// MARK: - Supporting Types

private struct HistogramParams {
    let binCount: UInt32
    let referenceWhiteNit: Float
}

/// Mirrors `LuminanceBinParams` in HistogramShaders.metal.
private struct LuminanceBinParams {
    let binCount: UInt32
    let scale: Float   // bins per linear unit: binCount / range
}
