import Foundation
import Metal
import Synchronization
import Testing
@testable import RedlampCanvas

/// An idle canvas leaves its display link off the render thread's run loop, so the thread
/// doesn't wake; a scene published at any point of the link leaving or coming back is drawn.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct CanvasRendererTests {
    final class Link: CanvasDisplayLink, @unchecked Sendable {
        private struct State {
            var paused = false
            var attached = false
        }

        private let state = Mutex(State())

        var isPaused: Bool {
            get { state.withLock { $0.paused } }
            set { state.withLock { $0.paused = newValue } }
        }

        var isAttached: Bool {
            state.withLock { $0.attached }
        }

        func add(to _: RunLoop, forMode _: RunLoop.Mode) {
            state.withLock { $0.attached = true }
        }

        func remove(from _: RunLoop, forMode _: RunLoop.Mode) {
            state.withLock { $0.attached = false }
        }

        func invalidate() {
            state.withLock { $0.attached = false }
        }
    }

    let link = Link()
    let renderer: CanvasRenderer

    init() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        renderer = try #require(CanvasRenderer(device: device, link: link))
    }

    private func scene(_ red: Double) -> CanvasRenderer.Scene {
        CanvasRenderer.Scene(layers: [], clearColor: MTLClearColor(red: red, green: 0, blue: 0, alpha: 1))
    }

    /// The scene a display update draws, if any, on the render thread.
    private func update() async -> Double? {
        await withCheckedContinuation { continuation in
            renderer.onRenderThread { [renderer] in
                continuation.resume(returning: renderer.nextScene()?.clearColor.red)
            }
        }
    }

    /// Once the render thread has done what was asked of it so far.
    private func settled() async {
        await withCheckedContinuation { continuation in
            renderer.onRenderThread { continuation.resume() }
        }
    }

    private var running: Bool {
        !link.isPaused && link.isAttached
    }

    private var idle: Bool {
        link.isPaused && !link.isAttached
    }

    @Test func `an idle canvas takes its display link off the run loop`() async {
        defer { renderer.shutdown() }
        await settled()
        #expect(idle, "nothing is shown yet")
        renderer.publish(scene(1))
        await settled()
        #expect(running)
        #expect(await update() == 1)
        #expect(await update() == nil)
        #expect(idle)
    }

    @Test func `a scene published as the link leaves the run loop is drawn`() async {
        defer { renderer.shutdown() }
        renderer.publish(scene(1))
        await settled()
        #expect(await update() == 1)
        let published = Mutex(false)
        let next = scene(2)
        renderer.beforeIdling = { [renderer] in
            guard !published.withLock({ $0 }) else { return }
            published.withLock { $0 = true }
            renderer.publish(next)
        }
        #expect(await update() == nil)
        await settled()
        #expect(running)
        #expect(await update() == 2)
    }

    @Test func `a scene published as the link comes back to the run loop is drawn`() async {
        defer { renderer.shutdown() }
        renderer.publish(scene(1))
        await settled()
        #expect(await update() == 1)
        #expect(await update() == nil)
        let published = Mutex(false)
        let next = scene(3)
        renderer.whileWaking = { [renderer] in
            guard !published.withLock({ $0 }) else { return }
            published.withLock { $0 = true }
            renderer.publish(next)
        }
        renderer.publish(scene(2))
        await settled()
        #expect(running)
        #expect(await update() == 3)
        await settled()
        #expect(running)
        #expect(await update() == nil)
    }
}
