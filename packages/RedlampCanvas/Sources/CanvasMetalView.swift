import AppKit
import CoreImage
import IOSurface
import Metal
import QuartzCore
import RedlampEngineAPI
import Synchronization

/// The photo on screen. The main thread only publishes what to draw (the frame's texture and
/// where it goes); a dedicated render thread presents it, paced by `CAMetalDisplayLink`, so
/// waiting for a drawable never blocks input handling.
public final class CanvasMetalView: NSView {
    /// Neutral surround, linear. Matches Lightroom's default dark grey (#1f1f1f).
    public static let defaultSurround = 0.0137

    let controller: CanvasController
    var clickAction: CanvasView.ClickAction = .zoom
    var interactive = true
    var onSample: (CGPoint) -> Void = { _ in }
    var surround = CanvasMetalView.defaultSurround {
        didSet {
            if surround != oldValue {
                setNeedsRedraw()
            }
        }
    }

    private let metalLayer: CAMetalLayer
    private let device: (any MTLDevice)?
    private let renderer: CanvasRenderer?
    private var texture: (any MTLTexture)?
    /// The part of the photo `texture` shows.
    private var region = ImageRect.full
    /// With a region frame, the whole photo at low resolution, drawn underneath.
    private var overview: (any MTLTexture)?
    /// Textures for the engine's few recycled surfaces, made once each.
    private var textures: [IOSurfaceID: any MTLTexture] = [:]
    private var dragOrigin: CGPoint?
    private var didDrag = false
    var wheelZoom = WheelZoom()

    init(controller: CanvasController) {
        self.controller = controller
        let device = MTLCreateSystemDefaultDevice()
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = false
        layer.framebufferOnly = true
        layer.isOpaque = true
        self.device = device
        metalLayer = layer
        renderer = device.flatMap { CanvasRenderer(device: $0, layer: layer) }
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        renderer?.shutdown()
    }

    override public func makeBackingLayer() -> CALayer {
        metalLayer
    }

    override public var isOpaque: Bool {
        true
    }

    override public var isFlipped: Bool {
        true
    }

    func display(_ frame: RenderedFrame?) {
        defer { setNeedsRedraw() }
        guard let frame else {
            texture = nil
            overview = nil
            return
        }
        texture = makeTexture(frame.surface, size: frame.size)
        region = frame.region
        overview = frame.overview.flatMap { makeTexture($0, size: frame.overviewSize) }
    }

    private func makeTexture(_ surface: IOSurfaceRef, size: PixelSize) -> (any MTLTexture)? {
        guard let device else { return nil }
        let id = IOSurfaceGetID(surface)
        if let cached = textures[id], cached.width == size.width, cached.height == size.height {
            return cached
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false,
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        if textures.count >= 8 {
            textures.removeAll()
        }
        textures[id] = texture
        return texture
    }

    private struct PlacedLayer {
        let texture: any MTLTexture
        let rect: CGRect
        let isOverview: Bool
    }

    /// Where the current frame's layers go, in view points: the overview (if any) under the
    /// rendered region.
    private func layers() -> [PlacedLayer] {
        guard let texture, bounds.width > 0, bounds.height > 0 else { return [] }
        let image = controller.imageRect(in: bounds.size)
        let part = CGRect(
            x: image.minX + region.x * image.width,
            y: image.minY + region.y * image.height,
            width: region.width * image.width,
            height: region.height * image.height,
        )
        return (overview.map { [PlacedLayer(texture: $0, rect: image, isOverview: true)] } ?? [])
            + [PlacedLayer(texture: texture, rect: part, isOverview: false)]
    }

    /// Publishes the current textures, geometry and surround to the render thread.
    func setNeedsRedraw() {
        guard let renderer else { return }
        let nearest = controller.pixelScale >= 2
        let layers = layers().map { layer in
            CanvasRenderer.Layer(
                texture: layer.texture,
                rect: SIMD4<Float>(
                    Float(layer.rect.minX / bounds.width * 2 - 1),
                    Float(1 - layer.rect.minY / bounds.height * 2),
                    Float(layer.rect.maxX / bounds.width * 2 - 1),
                    Float(1 - layer.rect.maxY / bounds.height * 2),
                ),
                nearest: nearest && !layer.isOverview,
            )
        }
        renderer.publish(CanvasRenderer.Scene(
            layers: layers,
            clearColor: MTLClearColor(red: surround, green: surround, blue: surround, alpha: 1),
        ))
    }

    /// The view's current contents (surround + image) as an sRGB image, for snapshots.
    public func snapshotImage() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let pixelBounds = CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale)
        guard pixelBounds.width > 0,
              let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let surround = CIColor(red: surround, green: surround, blue: surround, alpha: 1, colorSpace: linearP3) ?? .black
        var composite = CIImage(color: surround).cropped(to: pixelBounds)
        for layer in layers() {
            guard let image = CIImage(mtlTexture: layer.texture, options: [.colorSpace: linearP3]) else { continue }
            let rect = layer.rect
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
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        controller.updateView(size: bounds.size, backingScale: scale)
        setNeedsRedraw()
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

    /// A non-interactive canvas (the Navigator) leaves clicks to the SwiftUI views over it.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : nil
    }

    override public func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        stopWheelZoom()
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

    override public func magnify(with event: NSEvent) {
        guard interactive else { return }
        stopWheelZoom()
        controller.magnify(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }
}

/// Presents canvas scenes on its own thread. The display link runs only while there is
/// something new to show, and pauses itself once the latest scene is on screen.
final class CanvasRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    struct Layer: @unchecked Sendable {
        var texture: any MTLTexture
        /// The quad in NDC: left, top, right, bottom.
        var rect: SIMD4<Float>
        var nearest: Bool
    }

    struct Scene: @unchecked Sendable {
        /// Drawn in order, later layers on top.
        var layers: [Layer]
        var clearColor: MTLClearColor
    }

    private struct Shared {
        /// The scene not yet presented, if any.
        var pending: Scene?
        var wakeScheduled = false
        var stopped = false
    }

    private let shared = Mutex(Shared())
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let link: CAMetalDisplayLink
    /// Set once by the render thread before `init` returns.
    private var runLoop: CFRunLoop?

    init?(device: any MTLDevice, layer: CAMetalLayer) {
        guard let queue = device.makeCommandQueue(), let pipeline = Self.makePipeline(device: device)
        else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        link = CAMetalDisplayLink(metalLayer: layer)
        super.init()
        link.delegate = self
        link.preferredFrameLatency = 1
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.isPaused = true

        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            // Keeps the run loop alive while the display link is paused.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            link.add(to: .current, forMode: .default)
            started.signal()
            while !shared.withLock({ $0.stopped }) {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
            link.invalidate()
        }
        thread.name = "Redlamp canvas"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    func publish(_ scene: Scene) {
        let wake = shared.withLock { shared in
            shared.pending = scene
            defer { shared.wakeScheduled = true }
            return !shared.wakeScheduled
        }
        guard wake, let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            shared.withLock { $0.wakeScheduled = false }
            link.isPaused = false
        }
        CFRunLoopWakeUp(runLoop)
    }

    func shutdown() {
        shared.withLock { $0.stopped = true }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let scene = shared.withLock { shared in
            defer { shared.pending = nil }
            return shared.pending
        }
        guard let scene else {
            link.isPaused = true
            return
        }
        draw(scene, to: update.drawable)
    }

    private func draw(_ scene: Scene, to drawable: any CAMetalDrawable) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = scene.clearColor
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encoder.setRenderPipelineState(pipeline)
        for layer in scene.layers {
            var rect = layer.rect
            var nearest: UInt32 = layer.nearest ? 1 : 0
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(layer.texture, index: 0)
            encoder.setFragmentBytes(&nearest, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private static func makePipeline(device: any MTLDevice) -> (any MTLRenderPipelineState)? {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: CanvasRenderer.self))
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "rl_canvas_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "rl_canvas_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
