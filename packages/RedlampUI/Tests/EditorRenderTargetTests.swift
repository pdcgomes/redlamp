import CoreGraphics
import Foundation
import RedlampCanvas
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// What the editor asks the engine to render while zoomed in (PIPE-01).
@MainActor
struct EditorRenderTargetTests {
    /// A 6000×4000 photo in an 1800×1100 pt window at 2×.
    private func openEditor() async throws -> (EditorModel, StubEngine, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = StubEngine()
        engine.pixelSize = PixelSize(width: 6000, height: 4000)
        let model = EditorModel(engine: engine)
        model.canvas.updateView(size: CGSize(width: 1800, height: 1100), backingScale: 2)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil || model.canvas.imageSize.width == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.canvas.imageSize == engine.pixelSize)
        return (model, engine, { try? FileManager.default.removeItem(at: folder) })
    }

    /// The visible part in output pixels, at the zoom's density.
    private func visiblePixels(_ canvas: CanvasController) -> (rect: CGRect, columns: Double, rows: Double) {
        let density = min(canvas.pixelScale, 1)
        let columns = Double(canvas.imageSize.width) * density
        let rows = Double(canvas.imageSize.height) * density
        let visible = canvas.visibleImageRect
        return (
            CGRect(
                x: visible.minX * columns, y: visible.minY * rows,
                width: visible.width * columns, height: visible.height * rows,
            ),
            columns, rows,
        )
    }

    /// The renders a slider drag asks for.
    private func drag(_ model: EditorModel, _ engine: StubEngine) -> [RenderRequest] {
        let start = engine.renders.count
        model.beginEdit(.exposure)
        for step in 1 ... 10 {
            model.setValue(.exposure, Double(step) / 10)
        }
        return Array(engine.renders[start...])
    }

    @Test func `a drag at 1:1 asks only for the visible part and a guard band, then the margin once it ends`(
    ) async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        model.canvas.zoom = .oneToOne
        let (visible, columns, rows) = visiblePixels(model.canvas)
        let guardBand = 64.0
        let frames = drag(model, engine)
        #expect(frames.count == 10)
        for frame in frames {
            let region = try #require(frame.region)
            let x = region.x * columns, y = region.y * rows
            #expect(abs(x - x.rounded()) < 1e-6 && abs(y - y.rounded()) < 1e-6, "on the output pixel grid")
            #expect(abs(region.width * columns - Double(frame.targetSize.width)) < 1e-6)
            #expect(x <= visible.minX + 1e-6 && y <= visible.minY + 1e-6)
            #expect(x + Double(frame.targetSize.width) >= visible.maxX - 1e-6)
            #expect(y + Double(frame.targetSize.height) >= visible.maxY - 1e-6)
            #expect(x >= visible.minX - guardBand - 1 && y >= visible.minY - guardBand - 1)
            #expect(Double(frame.targetSize.width) <= visible.width + 2 * guardBand + 2)
            #expect(Double(frame.targetSize.height) <= visible.height + 2 * guardBand + 2)
        }

        let ended = engine.renders.count
        model.endEdit()
        #expect(engine.renders.count == ended + 1, "the margin, once")
        let settled = try #require(engine.lastRender)
        #expect(settled.targetSize == model.canvas.renderTarget.size)
        #expect(settled.region == model.canvas.renderTarget.region)
        #expect(settled.recipe == model.recipe)

        let after = engine.renders.count
        model.canvas.pan(byPoints: CGSize(width: 40, height: 30))
        #expect(engine.renders.count == after, "panning inside the margin renders nothing")
    }

    /// The budget: while a slider is dragged, the pixels asked for stay within 1.3 times the
    /// visible area, at 1:1 and closer, and between Fit and 1:1.
    @Test(arguments: [0.75, 1.0, 2.0])
    func `a drag asks for at most 1.3 times the visible pixels`(scale: Double) async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        model.canvas.zoom = .scale(scale)
        let visible = visiblePixels(model.canvas).rect
        let frames = drag(model, engine)
        #expect(!frames.isEmpty)
        let requested = frames.map { Double($0.targetSize.width * $0.targetSize.height) }.reduce(0, +)
        let budget = 1.3 * visible.width * visible.height * Double(frames.count)
        #expect(requested <= budget, "\(Int(requested)) pixels for \(Int(budget))")
        model.endEdit()
    }
}
