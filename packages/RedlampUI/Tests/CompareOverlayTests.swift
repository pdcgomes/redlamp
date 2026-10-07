import AppKit
import RedlampCanvas
import RedlampEngineAPI
import SwiftUI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Diagonal Split's handle over the canvas (#326). A press goes to the view AppKit's hit test
/// finds there: the handle drags the split, and the canvas under it zooms on a click.
@MainActor
struct CompareOverlayTests {
    /// Key without the test's process being active, so the overlay is hit-tested as in the app's
    /// front window.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool {
            true
        }
    }

    private static func views<T: NSView>(_: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(T.self, in: $0) }
    }

    /// A photo in the Diagonal Split on the editor's canvas, in a window of its own.
    private func split() async throws -> (EditorModel, NSWindow, CanvasMetalView, () -> Void) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = GatedEngine()
        engine.sendsFrames = true
        engine.base.pixelSize = PixelSize(width: 6000, height: 4000)
        let model = EditorModel(engine: engine)
        let window = KeyWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 560), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: CanvasArea(onOpen: {}).environment(model).environment(ThemeSettings()),
        )
        window.orderFront(nil)
        let cleanup = {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            model.select(folder.appending(path: "IMG_0001.ARW"))
            for _ in 0 ..< 400 where !model.hasFrame {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(model.hasFrame)
            model.showComparison(in: .split)
            for _ in 0 ..< 20 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let canvas = try #require(Self.views(CanvasMetalView.self, in: window.contentView).first)
            return (model, window, canvas, cleanup)
        } catch {
            cleanup()
            throw error
        }
    }

    @Test func `a press anywhere on the split's knob goes to the split, not to the canvas under it`() async throws {
        let (model, window, canvas, cleanup) = try await split()
        defer { cleanup() }
        let root = try #require(window.contentView?.superview)
        let line = try #require(model.canvas.splitLine(in: canvas.bounds.size))
        let knob = CGPoint(x: (line.start.x + line.end.x) / 2, y: (line.start.y + line.end.y) / 2)
        func view(at point: CGPoint) -> NSView? {
            root.hitTest(canvas.convert(point, to: nil))
        }

        // The knob is 26 points across, and the line runs through its middle.
        var onCanvas: [CGPoint] = []
        for dx in stride(from: -11.0, through: 11, by: 1) {
            for dy in stride(from: -11.0, through: 11, by: 1) where hypot(dx, dy) <= 11 {
                let point = CGPoint(x: knob.x + dx, y: knob.y + dy)
                if view(at: point) === canvas {
                    onCanvas.append(point)
                }
            }
        }
        #expect(onCanvas.count == 0, "points of the knob that go to the canvas, such as \(onCanvas.prefix(3))")

        let length = hypot(line.end.x - line.start.x, line.end.y - line.start.y)
        let along = CGVector(dx: (line.end.x - line.start.x) / length, dy: (line.end.y - line.start.y) / length)
        for distance in [-150.0, -60, 60, 150] {
            let point = CGPoint(x: knob.x + along.dx * distance, y: knob.y + along.dy * distance)
            #expect(view(at: point) !== canvas, "the line \(distance) points from the knob goes to the canvas")
        }
        #expect(view(at: CGPoint(x: knob.x - 150, y: knob.y - 150)) === canvas, "beside the line, the canvas has it")

        // A click on the knob's icon, beside the line's middle, as AppKit delivers it.
        let icon = canvas.convert(CGPoint(x: knob.x + along.dy * 4, y: knob.y - along.dx * 4), to: nil)
        let pressed = try #require(root.hitTest(icon))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: icon, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1,
            ))
            if type == .leftMouseDown {
                pressed.mouseDown(with: event)
            } else {
                pressed.mouseUp(with: event)
            }
        }
        #expect(model.canvas.zoom == .fit, "a click on the knob zoomed the photo to \(model.canvas.zoom)")
    }
}
