import AppKit
import CoreImage
import IOSurface
import Metal
import QuartzCore
import RedlampEngineAPI

/// The photo on screen. The main thread only publishes what to draw (the frame's texture and
/// where it goes); a dedicated render thread presents it, paced by `CAMetalDisplayLink`, so
/// waiting for a drawable never blocks input handling.
public final class CanvasMetalView: NSView {
    /// Neutral surround, linear. Matches Lightroom's default dark grey (#1f1f1f).
    public static let defaultSurround = 0.0137
    /// The colour-assessment surround (ISO 12646): middle grey, L* 50.
    public static let assessmentSurround = 0.184
    /// The colour-assessment view's white frame, as a fraction of the photo's shorter side.
    public static let assessmentFrame = 0.04

    let controller: CanvasController
    var clickAction: CanvasView.ClickAction = .zoom {
        didSet {
            if clickAction != oldValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    var interactive = true {
        didSet { updateCoveredEventMonitor() }
    }

    /// Scrolling and pinching over views drawn on the canvas reach it too (CoveredEvents).
    var forwardsCoveredEvents = false {
        didSet { updateCoveredEventMonitor() }
    }

    var coveredEventMonitor: Any?
    var onSample: (CGPoint) -> Void = { _ in }
    /// ⌘-scroll over the canvas, in notches (positive away from you), with Shift held or not.
    /// Returns whether it took the event; otherwise it zooms or pans as plain scrolling does.
    var onCommandScroll: ((Double, Bool) -> Bool)?
    var surround = CanvasMetalView.defaultSurround {
        didSet {
            if surround != oldValue {
                setNeedsRedraw()
            }
        }
    }

    /// A white frame around the photo, as a fraction of its shorter side (0 for none).
    var whiteFrame = 0.0 {
        didSet {
            if whiteFrame != oldValue {
                setNeedsRedraw()
            }
        }
    }

    private lazy var white: (any MTLTexture)? = {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false,
        )
        descriptor.usage = .shaderRead
        guard let texture = device?.makeTexture(descriptor: descriptor) else { return nil }
        var one = [Float16](repeating: 1, count: 4)
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &one, bytesPerRow: 8)
        return texture
    }()

    private let metalLayer: CAMetalLayer
    private let device: (any MTLDevice)?
    private let renderer: CanvasRenderer?
    private var texture: (any MTLTexture)?
    /// The part of the photo `texture` shows.
    private var region = ImageRect.full
    /// With a region frame, the whole photo at low resolution, drawn underneath.
    private var overview: (any MTLTexture)?
    /// The frame's comparison ("before") render and its overview, laid out by the
    /// controller's `comparison`.
    private var comparison: (any MTLTexture)?
    private var comparisonOverview: (any MTLTexture)?
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
        setAccessibilityIdentifier("canvas")
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
            comparison = nil
            comparisonOverview = nil
            return
        }
        texture = makeTexture(frame.surface, size: frame.size)
        region = frame.region
        overview = frame.overview.flatMap { makeTexture($0, size: frame.overviewSize) }
        comparison = frame.comparison.flatMap { makeTexture($0, size: frame.size) }
        comparisonOverview = frame.comparisonOverview.flatMap { makeTexture($0, size: frame.overviewSize) }
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
        if textures.count >= 16 {
            textures.removeAll()
        }
        textures[id] = texture
        return texture
    }

    /// The current textures, geometry and surround, for a drawable `scale` pixels per point.
    private func scene(scale: Double) -> CanvasRenderer.Scene {
        let nearest = controller.pixelScale >= 2
        var placed = layers()
        if whiteFrame > 0, !placed.isEmpty, let white {
            let image = controller.imageRect(in: bounds.size)
            let border = max(6, whiteFrame * min(image.width, image.height))
            placed.insert(
                PlacedLayer(texture: white, rect: image.insetBy(dx: -border, dy: -border), isOverview: true),
                at: 0,
            )
        }
        let layers = placed.map { layer in
            CanvasRenderer.Layer(
                texture: layer.texture,
                rect: SIMD4<Float>(
                    Float(layer.rect.minX / bounds.width * 2 - 1),
                    Float(1 - layer.rect.minY / bounds.height * 2),
                    Float(layer.rect.maxX / bounds.width * 2 - 1),
                    Float(1 - layer.rect.maxY / bounds.height * 2),
                ),
                nearest: nearest && !layer.isOverview,
                clip: SIMD4<Float>(Float(layer.clip.x / scale), Float(layer.clip.y / scale), Float(layer.clip.z), 0),
            )
        }
        return CanvasRenderer.Scene(
            layers: layers,
            clearColor: MTLClearColor(red: surround, green: surround, blue: surround, alpha: 1),
        )
    }

    /// Publishes the current textures, geometry and surround to the render thread.
    func setNeedsRedraw() {
        guard let renderer else { return }
        renderer.publish(scene(scale: metalLayer.contentsScale))
    }

    /// The view's current contents (surround + image) as an sRGB image, for snapshots.
    public func snapshotImage() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0, let device, let renderer,
              let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false,
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor) else { return nil }
        renderer.render(scene(scale: scale), into: target)
        guard let image = CIImage(mtlTexture: target, options: [.colorSpace: linearP3]) else { return nil }
        // Metal textures are top-down; Core Image is bottom-up.
        let flipped = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(
            x: 0,
            y: -image.extent.height,
        ))
        return CIContext().createCGImage(flipped, from: flipped.extent, format: .RGBA8, colorSpace: sRGB)
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

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateCoveredEventMonitor()
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

private extension CanvasMetalView {
    struct PlacedLayer {
        let texture: any MTLTexture
        let rect: CGRect
        let isOverview: Bool
        /// Keeps the half-plane where `x * clip.x + y * clip.y + clip.z <= 0`, in view points.
        var clip = SIMD3<Double>(0, 0, -1)
    }

    /// Where the current frame's layers go, in view points: the overview (if any) under the
    /// rendered region, then the comparison's, as the controller lays it out.
    func layers() -> [PlacedLayer] {
        guard let texture, bounds.width > 0, bounds.height > 0 else { return [] }
        let image = controller.imageRect(in: bounds.size)
        let edited = placed(texture, overview: overview, in: image)
        guard let comparison else { return edited }
        switch controller.comparison {
        case .none:
            return edited
        case .sideBySide:
            guard let pane = controller.comparisonStage(in: bounds.size),
                  let before = controller.comparisonImageRect(in: bounds.size)
            else { return edited }
            // Each side stops at the gap, so a zoomed-in photo doesn't spill into the other pane.
            let after = controller.stage(in: bounds.size)
            let (beforeClip, afterClip): (SIMD3<Double>, SIMD3<Double>) = switch controller.paneAxis(in: bounds.size) {
            case .horizontal: (SIMD3(1, 0, -Double(pane.maxX)), SIMD3(-1, 0, Double(after.minX)))
            case .vertical: (SIMD3(0, 1, -Double(pane.maxY)), SIMD3(0, -1, Double(after.minY)))
            }
            return placed(texture, overview: overview, in: image, clip: afterClip)
                + placed(comparison, overview: comparisonOverview, in: before, clip: beforeClip)
        case let .split(position):
            let frame = controller.visibleImageFrame(in: bounds.size)
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { return edited }
            // Before is the side where u + v < 2 * position, u and v normalised to the frame.
            let clip = SIMD3<Double>(
                1 / frame.width,
                1 / frame.height,
                -(frame.minX / frame.width + frame.minY / frame.height + 2 * position),
            )
            return edited + placed(comparison, overview: comparisonOverview, in: image, clip: clip)
        }
    }

    func placed(
        _ texture: any MTLTexture,
        overview: (any MTLTexture)?,
        in image: CGRect,
        clip: SIMD3<Double> = SIMD3(0, 0, -1),
    ) -> [PlacedLayer] {
        let part = CGRect(
            x: image.minX + region.x * image.width,
            y: image.minY + region.y * image.height,
            width: region.width * image.width,
            height: region.height * image.height,
        )
        return (overview.map { [PlacedLayer(texture: $0, rect: image, isOverview: true, clip: clip)] } ?? [])
            + [PlacedLayer(texture: texture, rect: part, isOverview: false, clip: clip)]
    }
}
