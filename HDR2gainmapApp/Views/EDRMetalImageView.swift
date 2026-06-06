import SwiftUI
import MetalKit
import CoreImage

/// The single on-screen renderer for the preview pane, for all four views. It draws a `CIImage`
/// into a `CAMetalLayer` (via `MTKView`) so that:
///   1. HDR views (input / final output) reliably activate the display's EDR headroom — SwiftUI's
///      `Image(...).allowedDynamicRange(.high)` uses a tone-mapping `CALayer`, which is *not* an
///      EDR-capable surface and so fails to trigger the system's on-demand EDR activation.
///   2. Zoom ("pixel peeping") is implemented once, as a render-time crop+scale at full resolution
///      (crisp, nearest-neighbor when magnifying), shared by every view.
///
/// `isHDR` selects the layer/output color space (extended-linear Display P3 + EDR for HDR content,
/// plain Display P3 for SDR / gain-map). The letterbox stays transparent so the PreviewPane
/// background shows through.
struct EDRMetalImageView: NSViewRepresentable {
    let ciImage: CIImage?
    let isHDR: Bool
    let isZoomed: Bool
    /// Zoom focal point as a top-left unit coordinate (0…1) within the image.
    let zoomAnchorUnit: CGPoint
    /// Zoom magnification in percent of actual pixels (100 = 1 image px : 1 point).
    let zoomPercent: Int

    /// Whether this Mac has a Metal device (otherwise callers should fall back to SwiftUI `Image`).
    static var isSupported: Bool { MTLCreateSystemDefaultDevice() != nil }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .rgba16Float
        // Render on demand only (no continuous redraw loop).
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.framebufferOnly = false           // CIContext writes into the drawable's texture.
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        // Transparent letterbox: let the PreviewPane background show through.
        view.layer?.isOpaque = false
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.isOpaque = false
        }
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        apply(to: nsView, coordinator: context.coordinator)
        nsView.setNeedsDisplay(nsView.bounds)
    }

    /// Pushes the current SwiftUI state into the view's layer and the coordinator.
    private func apply(to view: MTKView, coordinator: Coordinator) {
        if let metalLayer = view.layer as? CAMetalLayer {
            // EDR only for HDR content; the color space must match the render destination below.
            metalLayer.wantsExtendedDynamicRangeContent = isHDR
            metalLayer.colorspace = isHDR
                ? CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                : CGColorSpace(name: CGColorSpace.displayP3)
        }
        coordinator.image = ciImage
        coordinator.isHDR = isHDR
        coordinator.isZoomed = isZoomed
        coordinator.zoomAnchorUnit = zoomAnchorUnit
        coordinator.zoomPercent = zoomPercent
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private let ciContext: CIContext?
        private let hdrColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        private let sdrColorSpace = CGColorSpace(name: CGColorSpace.displayP3)

        // State pushed from `updateNSView`; changing it does not redraw on its own.
        var image: CIImage?
        var isHDR: Bool = true
        var isZoomed: Bool = false
        var zoomAnchorUnit: CGPoint = CGPoint(x: 0.5, y: 0.5)
        var zoomPercent: Int = 200

        override init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            if let device {
                let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                ciContext = CIContext(mtlDevice: device, options: [
                    .workingColorSpace: cs as Any,
                    .cacheIntermediates: false
                ])
            } else {
                ciContext = nil
            }
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let ciContext,
                  let commandQueue,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            let dst = CGRect(x: 0, y: 0,
                             width: view.drawableSize.width,
                             height: view.drawableSize.height)
            guard dst.width > 0, dst.height > 0 else { return }

            // Transparent background so the whole texture is defined; the clear letterbox lets the
            // PreviewPane's own background show through.
            let background = CIImage(color: .clear).cropped(to: dst)

            let composited: CIImage
            if let image, image.extent.width > 0, image.extent.height > 0 {
                composited = place(image, in: dst, view: view).composited(over: background)
            } else {
                composited = background
            }

            let destination = CIRenderDestination(width: Int(dst.width),
                                                  height: Int(dst.height),
                                                  pixelFormat: view.colorPixelFormat,
                                                  commandBuffer: commandBuffer,
                                                  mtlTextureProvider: { drawable.texture })
            destination.colorSpace = isHDR ? hdrColorSpace : sdrColorSpace
            _ = try? ciContext.startTask(toRender: composited, to: destination)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// Positions `image` inside the drawable rect `dst` (pixels): aspect-fit when not zoomed,
        /// otherwise scaled to the requested actual-pixel level, focused on the anchor and clamped
        /// to the edges.
        private func place(_ image: CIImage, in dst: CGRect, view: MTKView) -> CIImage {
            let ext = image.extent

            if !isZoomed {
                let scale = min(dst.width / ext.width, dst.height / ext.height)
                let tx = (dst.width - ext.width * scale) / 2 - ext.origin.x * scale
                let ty = (dst.height - ext.height * scale) / 2 - ext.origin.y * scale
                return image
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: tx, y: ty))
            }

            // Zoom: percent is in points; the drawable is in pixels (× backing scale).
            let backingScale = view.bounds.width > 0
                ? dst.width / view.bounds.width
                : (view.window?.backingScaleFactor ?? 2)
            let scale = CGFloat(zoomPercent) / 100.0 * backingScale

            // Anchor in image coordinates (CIImage origin is bottom-left; the unit point is top-left).
            let ax = ext.origin.x + zoomAnchorUnit.x * ext.width
            let ay = ext.origin.y + (1 - zoomAnchorUnit.y) * ext.height

            // Translate so the anchor lands at the drawable center, then clamp to cover the edges.
            let tx = clampTranslation(dst.width / 2 - scale * ax,
                                      scaledSize: ext.width * scale, dstSize: dst.width,
                                      origin: ext.origin.x, scale: scale)
            let ty = clampTranslation(dst.height / 2 - scale * ay,
                                      scaledSize: ext.height * scale, dstSize: dst.height,
                                      origin: ext.origin.y, scale: scale)

            // Nearest-neighbor when magnifying so individual pixels stay crisp.
            let src = scale >= 1 ? image.samplingNearest() : image
            return src
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: tx, y: ty))
        }

        /// Keeps the scaled image covering the drawable along one axis (no empty gap), or centers it
        /// when it's smaller than the drawable.
        private func clampTranslation(_ t: CGFloat, scaledSize: CGFloat, dstSize: CGFloat,
                                      origin: CGFloat, scale: CGFloat) -> CGFloat {
            if scaledSize >= dstSize {
                let minT = dstSize - scaledSize - scale * origin
                let maxT = -scale * origin
                return min(max(t, minT), maxT)
            } else {
                return (dstSize - scaledSize) / 2 - scale * origin
            }
        }
    }
}
