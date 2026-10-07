import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Pins inside each mask (UX-23): where the mask covers most, found with its thumbnail, rather
/// than at its first component's centre, which can be outside a crescent or a ring.
@MainActor
struct MaskPinTests {
    /// A 72 × 48 coverage, white where `covers`.
    private func coverage(_ covers: (Int, Int) -> Bool) throws -> CGImage {
        let (width, height) = (72, 48)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width where covers(x, y) {
                pixels[y * width + x] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent,
        ))
    }

    @Test func `a band's pin sits in its middle`() throws {
        let pin = try #require(EditorModel.innermostPoint(of: coverage { x, _ in x < 24 }))
        #expect(abs(pin.x - 12.0 / 72) < 0.03)
        #expect(abs(pin.y - 0.5) < 0.06)
    }

    @Test func `a ring's pin is on the ring, not in its hole`() throws {
        let pin = try #require(EditorModel.innermostPoint(of: coverage { x, y in
            let r = ((Double(x) - 36) * (Double(x) - 36) + (Double(y) - 24) * (Double(y) - 24)).squareRoot()
            return r >= 10 && r <= 20
        }))
        let r = ((pin.x * 72 - 36) * (pin.x * 72 - 36) + (pin.y * 48 - 24) * (pin.y * 48 - 24)).squareRoot()
        #expect(r > 11 && r < 19)
    }

    @Test func `a mask covering nothing has no pin, and one covering everything has it in the middle`() throws {
        #expect(try EditorModel.innermostPoint(of: coverage { _, _ in false }) == nil)
        let pin = try #require(EditorModel.innermostPoint(of: coverage { _, _ in true }))
        #expect(abs(pin.x - 0.5) < 0.03 && abs(pin.y - 0.5) < 0.03)
    }

    /// The stub draws every thumbnail grey, covered all over, so the pin is the frame's centre:
    /// with the right half cropped away, the left half's centre in the photo.
    @Test func `the pin is placed with the thumbnail, in the photo's coordinates`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0007.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info != nil)
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.8, y: 0.8), radiusX: 0.1, radiusY: 0.1)))
        model.finishDrawing()
        let mask = try #require(model.masks.first?.id)
        model.setCrop(CropRect(left: 0, top: 0, right: 0.5, bottom: 1))
        await model.refreshMaskThumbnails()
        let pin = try #require(model.maskPins[mask])
        #expect(abs(pin.x - 0.25) < 0.03)
        #expect(abs(pin.y - 0.5) < 0.03)

        model.deleteMask(mask)
        await model.refreshMaskThumbnails()
        #expect(model.maskPins.isEmpty)
    }
}

/// A component's own preview (UX-23): the pointer over its row shows its coverage alone.
@MainActor
struct ComponentPreviewTests {
    @Test func `the pointer over a component previews it alone, the photo as edited`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0007.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info != nil)
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
        model.finishDrawing()
        let mask = try #require(model.masks.first?.id)
        model.startDrawing(.linear, operation: .subtract, addingTo: mask)
        model.beginDrawing(.linear(LinearMask(start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.4))))
        model.finishDrawing()
        let subtracted = try #require(model.recipe.masks.first?.components.last)
        #expect(subtracted.operation == .subtract)

        model.hoveredComponentID = subtracted.id
        model.requestRender()
        for _ in 0 ..< 200 where engine.lastRender?.maskOverlay != EditorModel.componentPreviewID {
            try await Task.sleep(for: .milliseconds(5))
        }
        let render = try #require(engine.lastRender)
        #expect(render.maskOverlay == EditorModel.componentPreviewID)
        let preview = try #require(render.recipe.masks.last)
        #expect(render.recipe.masks.count == 2)
        #expect(preview.components.map(\.operation) == [.add])
        #expect(preview.components.first?.id == subtracted.id)
        #expect(preview.adjustments.isEmpty)
        #expect(model.recipe.masks.count == 1)

        model.activeTool = .edit
        #expect(model.componentPreview(in: model.recipe) == nil)
    }
}
