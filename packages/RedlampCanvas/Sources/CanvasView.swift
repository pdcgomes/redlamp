import AppKit
import IOSurface
import MetalKit
import RedlampEngineAPI
import SwiftUI

/// Displays engine frames. The frame's IOSurface is sampled directly — no pixel copies.
public struct CanvasView: NSViewRepresentable {
    public enum ClickAction {
        case zoom
        case sample
        case none
    }

    let frame: RenderedFrame?
    let controller: CanvasController
    let revision: Int
    let clickAction: ClickAction
    let interactive: Bool
    /// Linear grey level around the photo (Lightroom's Lights Out dims it to black).
    let surround: Double
    let onSample: (CGPoint) -> Void

    public init(
        frame: RenderedFrame?,
        controller: CanvasController,
        clickAction: ClickAction = .zoom,
        interactive: Bool = true,
        surround: Double = CanvasMetalView.defaultSurround,
        onSample: @escaping (CGPoint) -> Void = { _ in },
    ) {
        self.surround = surround
        self.frame = frame
        self.controller = controller
        revision = controller.revision
        self.clickAction = clickAction
        self.interactive = interactive
        self.onSample = onSample
    }

    public func makeNSView(context _: Context) -> CanvasMetalView {
        CanvasMetalView(controller: controller)
    }

    public func updateNSView(_ view: CanvasMetalView, context _: Context) {
        view.clickAction = clickAction
        view.interactive = interactive
        view.clearColor = MTLClearColor(red: surround, green: surround, blue: surround, alpha: 1)
        view.onSample = onSample
        view.display(frame)
        view.needsDisplay = true
    }
}

public final class CanvasMetalView: MTKView {
    /// Neutral surround, linear. Matches Lightroom's default dark grey (#1f1f1f).
    public static let defaultSurround = 0.0137
    static let surround = MTLClearColor(red: defaultSurround, green: defaultSurround, blue: defaultSurround, alpha: 1)

    let controller: CanvasController
    var clickAction: CanvasView.ClickAction = .zoom
    var interactive = true
    var onSample: (CGPoint) -> Void = { _ in }

    private let queue: (any MTLCommandQueue)?
    private let pipeline: (any MTLRenderPipelineState)?
    private var texture: (any MTLTexture)?
    private var surfaceID: IOSurfaceID = 0
    private var dragOrigin: CGPoint?
    private var didDrag = false

    init(controller: CanvasController) {
        self.controller = controller
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        pipeline = device.flatMap(Self.makePipeline)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .rgba16Float
        clearColor = Self.surround
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        autoResizeDrawable = true
        if let layer = layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            layer.wantsExtendedDynamicRangeContent = false
        }
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func makePipeline(device: any MTLDevice) -> (any MTLRenderPipelineState)? {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: CanvasMetalView.self))
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "rl_canvas_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "rl_canvas_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func display(_ frame: RenderedFrame?) {
        guard let frame, let device else {
            if frame == nil {
                texture = nil
            }
            return
        }
        let id = IOSurfaceGetID(frame.surface)
        guard id != surfaceID || texture == nil else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: frame.size.width, height: frame.size.height, mipmapped: false,
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        texture = device.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0)
        surfaceID = id
    }

    /// The view's current contents (surround + image) as an sRGB image, for snapshots.
    public func snapshotImage() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let pixelBounds = CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale)
        guard pixelBounds.width > 0,
              let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let surround = CIColor(red: 0.0137, green: 0.0137, blue: 0.0137, alpha: 1, colorSpace: linearP3) ?? .black
        var composite = CIImage(color: surround).cropped(to: pixelBounds)
        if let texture, let image = CIImage(mtlTexture: texture, options: [.colorSpace: linearP3]) {
            let rect = controller.imageRect(in: bounds.size)
            let target = CGRect(
                x: rect.minX * scale,
                y: (bounds.height - rect.maxY) * scale,
                width: rect.width * scale,
                height: rect.height * scale,
            )
            let flipped = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(
                x: 0,
                y: -image.extent.height,
            ))
            let placed = flipped.transformed(by: CGAffineTransform(
                a: target.width / image.extent.width, b: 0, c: 0, d: target.height / image.extent.height,
                tx: target.minX, ty: target.minY,
            ))
            composite = placed.composited(over: composite).cropped(to: pixelBounds)
        }
        return CIContext().createCGImage(composite, from: pixelBounds, format: .RGBA8, colorSpace: sRGB)
    }

    // MARK: - Layout

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncGeometry()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncGeometry()
    }

    private func syncGeometry() {
        controller.updateView(size: bounds.size, backingScale: window?.backingScaleFactor ?? 2)
    }

    override public var isFlipped: Bool {
        true
    }

    // MARK: - Drawing

    override public func draw(_: NSRect) {
        guard let pipeline, let queue,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        if let texture, bounds.width > 0 {
            let rect = controller.imageRect(in: bounds.size)
            var ndc = SIMD4<Float>(
                Float(rect.minX / bounds.width * 2 - 1),
                Float(1 - rect.minY / bounds.height * 2),
                Float(rect.maxX / bounds.width * 2 - 1),
                Float(1 - rect.maxY / bounds.height * 2),
            )
            var nearest: UInt32 = controller.pixelScale >= 2 ? 1 : 0
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&ndc, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&nearest, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    // MARK: - Events

    override public func resetCursorRects() {
        guard interactive else { return }
        switch clickAction {
        case .sample: addCursorRect(bounds, cursor: .crosshair)
        case .zoom: addCursorRect(bounds, cursor: controller.isZoomedIn ? .openHand : .arrow)
        case .none: break
        }
    }

    override public func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        dragOrigin = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override public func mouseDragged(with event: NSEvent) {
        guard interactive, let origin = dragOrigin, controller.isZoomedIn else { return }
        let location = convert(event.locationInWindow, from: nil)
        if !didDrag, hypot(location.x - origin.x, location.y - origin.y) < 3 {
            return
        }
        if !didDrag {
            NSCursor.closedHand.set()
        }
        didDrag = true
        controller.pan(byPoints: CGSize(width: location.x - origin.x, height: location.y - origin.y))
        dragOrigin = location
    }

    override public func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            window?.invalidateCursorRects(for: self)
        }
        guard interactive, !didDrag else { return }
        let location = convert(event.locationInWindow, from: nil)
        switch clickAction {
        case .zoom:
            controller.toggleZoom(at: location)
        case .sample:
            if let point = controller.imagePoint(for: location) {
                onSample(point)
            }
        case .none:
            break
        }
    }

    override public func scrollWheel(with event: NSEvent) {
        guard interactive, controller.isZoomedIn else { return }
        controller.pan(byPoints: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }

    override public func magnify(with event: NSEvent) {
        guard interactive else { return }
        controller.magnify(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }
}
