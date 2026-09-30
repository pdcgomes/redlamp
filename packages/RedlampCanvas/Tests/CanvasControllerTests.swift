import CoreGraphics
import RedlampCanvas
import RedlampEngineAPI
import Testing

@MainActor
struct CanvasControllerTests {
    /// A 6000×4000 photo in a 1000×800 pt view at 2×: Fit is 1:3.
    private func makeController() -> CanvasController {
        let controller = CanvasController()
        controller.updateView(size: CGSize(width: 1000, height: 800), backingScale: 2)
        controller.imageSize = PixelSize(width: 6000, height: 4000)
        return controller
    }

    @Test func `zooming keeps the point under the pointer in place`() throws {
        let controller = makeController()
        let pointer = CGPoint(x: 700, y: 300)
        controller.zoom(toScale: 0.5, anchoredAt: pointer)
        let before = try #require(controller.imagePoint(for: pointer))
        controller.zoom(toScale: 3, anchoredAt: pointer)
        let after = try #require(controller.imagePoint(for: pointer))
        #expect(abs(after.x - before.x) < 1e-9)
        #expect(abs(after.y - before.y) < 1e-9)
    }

    @Test func `zoom is limited to Fit and 11:1`() {
        let controller = makeController()
        controller.zoom(toScale: 50, anchoredAt: CGPoint(x: 500, y: 400))
        #expect(controller.pixelScale == 11)
        controller.zoom(toScale: 0.01, anchoredAt: CGPoint(x: 500, y: 400))
        #expect(controller.zoom == .fit)
    }

    @Test func `zoom in steps through Lightroom's ratios`() {
        let controller = makeController()
        var scales: [Double] = []
        while true {
            controller.zoomIn()
            guard scales.last != controller.pixelScale else { break }
            scales.append(controller.pixelScale)
        }
        #expect(scales == [0.5, 1, 2, 3, 4, 8, 11])
    }

    @Test func `centering on a point stays inside the photo`() {
        let controller = makeController()
        controller.zoom = .oneToOne
        controller.centerOn(CGPoint(x: -1, y: 2))
        let visible = controller.visibleImageRect
        #expect(abs(visible.minX) < 1e-9)
        #expect(abs(visible.maxY - 1) < 1e-9)
    }

    @Test func `ratio labels`() {
        #expect(CanvasController.zoomRatios.map(CanvasController.ratioLabel) == [
            "1:16", "1:8", "1:4", "1:3", "1:2", "1:1", "2:1", "3:1", "4:1", "8:1", "11:1",
        ])
    }
}
