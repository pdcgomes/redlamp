import Foundation
import Metal
import QuartzCore
import Synchronization

/// What the renderer needs of its display link; tests drive a stand-in.
protocol CanvasDisplayLink: AnyObject {
    var isPaused: Bool { get set }
    func add(to runloop: RunLoop, forMode mode: RunLoop.Mode)
    func remove(from runloop: RunLoop, forMode mode: RunLoop.Mode)
    func invalidate()
}

extension CAMetalDisplayLink: CanvasDisplayLink {}

/// Presents canvas scenes on its own thread. The display link runs only while there is
/// something new to show, and pauses and leaves the run loop once the latest scene is on
/// screen, so an idle canvas's thread sleeps.
final class CanvasRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    struct Layer: @unchecked Sendable {
        var texture: any MTLTexture
        /// The quad in NDC: left, top, right, bottom.
        var rect: SIMD4<Float>
        var nearest: Bool
        /// Keeps the half-plane where `dot(clip.xyz, (x, y, 1)) <= 0`, in drawable pixels.
        var clip: SIMD4<Float>
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
    private let link: any CanvasDisplayLink
    /// Set once by the render thread before `init` returns.
    private var runLoop: CFRunLoop?
    /// Whether the link is on the render thread's run loop; only while there is a scene to show.
    /// Render thread only.
    private var isAttached = false
    /// For tests, on the render thread: as the link is about to go idle, and as a publish wakes it.
    var beforeIdling: (() -> Void)?
    var whileWaking: (() -> Void)?

    convenience init?(device: any MTLDevice, layer: CAMetalLayer) {
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameLatency = 1
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        self.init(device: device, link: link)
        link.delegate = self
    }

    init?(device: any MTLDevice, link: any CanvasDisplayLink) {
        guard let queue = device.makeCommandQueue(), let pipeline = Self.makePipeline(device: device)
        else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.link = link
        super.init()
        link.isPaused = true

        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            // Keeps the run loop alive while the display link is paused.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            started.signal()
            while !shared.withLock({ $0.stopped }) {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
            self.link.invalidate()
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
        guard wake else { return }
        onRenderThread { [self] in
            shared.withLock { $0.wakeScheduled = false }
            whileWaking?()
            if !isAttached {
                link.add(to: .current, forMode: .default)
                isAttached = true
            }
            link.isPaused = false
        }
    }

    /// Runs `body` on the render thread, after what was asked of it before.
    func onRenderThread(_ body: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(runLoop)
    }

    func shutdown() {
        shared.withLock { $0.stopped = true }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    func metalDisplayLink(_: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let scene = nextScene() else { return }
        draw(scene, to: update.drawable)
    }

    /// The scene to draw at this display update. With none, the link pauses and leaves the run
    /// loop, whose display timer would otherwise still wake the thread; a scene published
    /// meanwhile has its wake queued behind this, which brings the link back. On the render
    /// thread.
    func nextScene() -> Scene? {
        let scene = shared.withLock { shared in
            defer { shared.pending = nil }
            return shared.pending
        }
        if let scene {
            return scene
        }
        beforeIdling?()
        link.isPaused = true
        if isAttached {
            link.remove(from: .current, forMode: .default)
            isAttached = false
        }
        return nil
    }

    private func draw(_ scene: Scene, to drawable: any CAMetalDrawable) {
        guard let commands = encode(scene, into: drawable.texture) else { return }
        commands.present(drawable)
        commands.commit()
    }

    /// Draws `scene` into `texture` and waits for it (for snapshots).
    func render(_ scene: Scene, into texture: any MTLTexture) {
        guard let commands = encode(scene, into: texture) else { return }
        commands.commit()
        commands.waitUntilCompleted()
    }

    private func encode(_ scene: Scene, into texture: any MTLTexture) -> (any MTLCommandBuffer)? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = scene.clearColor
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }
        encoder.setRenderPipelineState(pipeline)
        for layer in scene.layers {
            var rect = layer.rect
            var nearest: UInt32 = layer.nearest ? 1 : 0
            var clip = layer.clip
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(layer.texture, index: 0)
            encoder.setFragmentBytes(&nearest, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.setFragmentBytes(&clip, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        return commands
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
