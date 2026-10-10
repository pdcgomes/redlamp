import AppKit
import CoreGraphics
import Foundation
import RedlampEngineAPI
import SwiftUI
import Testing
@_spi(Harness) @testable import RedlampUI

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

/// The canvas previews the mask or component under the pointer (UX-23) only while what the pointer
/// is over is still there: a mask's pin goes when the mask is selected or the Masking tool closes,
/// and a row of the new panel when its mask or component is deleted (#364). SwiftUI reads hovers
/// from the real pointer, which a test can't move, so each hover starts as the view reports it.
@MainActor
struct PointerPreviewTests {
    /// An editor with a photo open, showing `content` in a window of its own.
    private func open(
        _ content: () -> some View,
    ) async throws -> (model: EditorModel, engine: GatedEngine, window: NSWindow, cleanup: () -> Void) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = GatedEngine()
        engine.sendsFrames = true
        let model = EditorModel(engine: engine)
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 560), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content().environment(model).environment(ThemeSettings()))
        window.orderFront(nil)
        let cleanup = {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            model.select(folder.appending(path: "IMG_0011.ARW"))
            for _ in 0 ..< 400 where !model.hasFrame {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(model.hasFrame)
            model.activeTool = .masking
            for x in [0.3, 0.7] {
                model.startDrawing(.radial)
                model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: x, y: 0.5), radiusX: 0.1, radiusY: 0.1)))
                model.finishDrawing()
            }
            try await settle(window)
            return (model, engine, window, cleanup)
        } catch {
            cleanup()
            throw error
        }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func `a mask's pin previews it only while the pin is on the canvas`() async throws {
        let (model, engine, window, cleanup) = try await open { CanvasArea(onOpen: {}) }
        defer { cleanup() }
        let (left, right) = (model.masks[0].id, model.masks[1].id)
        try #require(model.selectedMaskID == right)

        // The pointer comes onto the left mask's pin and clicks it.
        model.hoveredPinMaskID = left
        #expect(model.maskOverlayShown == left)
        model.selectMask(left)
        try await settle(window)
        #expect(model.hoveredPinMaskID == nil, "the selected mask has no pin, so nothing previews it")
        model.selectMask(right)
        #expect(model.maskOverlayShown == right, "the overlay shows the mask chosen in the list")
        #expect(engine.base.lastRender?.maskOverlay == right)
        model.startDrawing(.radial)
        #expect(model.maskOverlayShown == nil, "a tool armed for a new mask shows no overlay (#354)")
        model.cancelDrawing()

        try await settle(window)
        model.hoveredPinMaskID = left
        model.activeTool = .edit
        try await settle(window)
        model.activeTool = .masking
        try await settle(window)
        #expect(model.maskOverlayShown == right, "the pins went with the Masking tool, and the preview with them")
    }

    @Test func `a row of the new Masks panel previews its mask or component only while it's there`() async throws {
        let (model, _, window, cleanup) = try await open { MasksPanel() }
        defer { cleanup() }
        let (left, right) = (model.masks[0].id, model.masks[1].id)

        // The pointer on the left mask's row deletes it from the row's menu.
        model.hoveredMaskID = left
        model.deleteMask(left)
        try await settle(window)
        #expect(model.hoveredMaskID == nil, "the deleted mask's row went, and its preview with it")
        model.undo()
        try await settle(window)
        #expect(model.maskOverlayShown == right, "back again, the mask isn't under the pointer")

        model.startDrawing(.linear, operation: .subtract, addingTo: right)
        model.beginDrawing(.linear(LinearMask(start: ImagePoint(x: 0.7, y: 0.2), end: ImagePoint(x: 0.7, y: 0.4))))
        model.finishDrawing()
        let component = try #require(model.recipe.mask(right)?.components.last?.id)
        try await settle(window)
        model.hoveredComponentID = component
        model.deleteComponent(component, in: right)
        try await settle(window)
        #expect(model.hoveredComponentID == nil, "the deleted component's row went, and its preview with it")
        model.undo()
        #expect(model.componentPreview(in: model.recipe) == nil)
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
