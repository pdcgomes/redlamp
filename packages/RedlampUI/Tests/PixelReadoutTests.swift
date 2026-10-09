import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The histogram's readout of the photo under the pointer (UX-32).
@MainActor @Suite(.serialized)
struct PixelReadoutTests {
    private func openEditor() async throws -> (EditorModel, StubEngine, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = StubEngine()
        let model = EditorModel(engine: engine)
        model.canvas.updateView(size: CGSize(width: 600, height: 400), backingScale: 2)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info != nil)
        let lab = model.showsLabReadout
        return (model, engine, {
            model.showsLabReadout = lab
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    @Test func `hovering the photo reads it, and leaving clears it`() async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        model.hoverReadout(at: CGPoint(x: 0.25, y: 0.75))
        try await eventually { model.pixelReadout != nil }
        #expect(model.pixelReadout == engine.readoutValue)
        let asked = try #require(engine.readouts.last)
        #expect(asked.point == CGPoint(x: 0.25, y: 0.75))
        #expect(asked.recipe == model.recipe)
        // Five pixels as displayed: the 600 × 400 photo fills the canvas at a scale of 2.
        let shown = model.canvas.imageRect(in: model.canvas.viewSize)
        #expect(abs(asked.area.width - 5 / (shown.width * 2)) < 1e-9)
        model.hoverReadout(at: nil)
        #expect(model.pixelReadout == nil)
    }

    @Test func `an edit while hovering reads the photo again`() async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        model.hoverReadout(at: CGPoint(x: 0.5, y: 0.5))
        try await eventually { model.pixelReadout != nil }
        model.setValue(.exposure, 1)
        try await eventually { engine.readouts.last?.recipe[.exposure] == 1 }
    }

    @Test func `another photo clears the readout until it's read`() async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        model.hoverReadout(at: CGPoint(x: 0.5, y: 0.5))
        try await eventually { model.pixelReadout != nil }
        engine.readoutValue = nil
        let next = try #require(model.selection).deletingLastPathComponent().appending(path: "IMG_0002.ARW")
        model.select(next)
        try await eventually { model.info?.url == next }
        try await eventually { model.pixelReadout == nil }
    }

    @Test func `the line shows RGB percentages or L*a*b*`() {
        let readout = PixelReadout(rgb: SIMD3(45.24, 100, 0), lab: SIMD3(50.04, -0.31, -0.04))
        #expect(EditorModel.readoutParts(readout, lab: false) == ["R 45.2", "G 100.0", "B 0.0 %"])
        #expect(EditorModel.readoutParts(readout, lab: true) == ["L* 50.0", "a* −0.3", "b* 0.0"])
    }

    @Test func `Show L*a*b* Values switches the line and is kept`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let before = model.showsLabReadout
        #expect(model.canPerform(.labReadout))
        #expect(model.perform(.labReadout))
        #expect(model.showsLabReadout != before)
        #expect(UserDefaults.standard.bool(forKey: "app.redlamp.labReadout") == model.showsLabReadout)
    }
}
