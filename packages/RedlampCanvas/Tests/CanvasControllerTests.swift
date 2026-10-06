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

    @Test func `renders the whole photo at Fit`() {
        let controller = makeController()
        #expect(controller.renderTarget.region == nil)
        #expect(controller.renderTarget.size == controller.renderSize)
    }

    @Test func `renders only around the visible part when zoomed in`() throws {
        let controller = makeController()
        controller.zoom = .oneToOne
        let target = controller.renderTarget
        let region = try #require(target.region)
        let visible = controller.visibleImageRect
        #expect(region.x <= visible.minX && region.y <= visible.minY)
        #expect(region.x + region.width >= visible.maxX && region.y + region.height >= visible.maxY)
        #expect(target.size.width * target.size.height < 6000 * 4000 * 6 / 10)
        // On the output pixel grid, so successive regions line up exactly.
        #expect(abs(region.x * 6000 - (region.x * 6000).rounded()) < 1e-6)
        #expect(abs(region.width * 6000 - Double(target.size.width)) < 1e-6)
    }

    /// At rest (PIPE-01 covers drags), a 24 MP photo on a 2400×1600 px stage and a 60 MP one on a
    /// 4800×2700 px stage render around the view, at most 2.25 times the pixels on screen, rather
    /// than the whole photo.
    @Test(arguments: [
        (PixelSize(width: 6024, height: 4024), CGSize(width: 1200, height: 800)),
        (PixelSize(width: 9504, height: 6336), CGSize(width: 2400, height: 1350)),
    ])
    func `at 1-to-1 the area rendered around the view at rest is capped`(image: PixelSize, view: CGSize) {
        let controller = CanvasController()
        controller.updateView(size: view, backingScale: 2)
        controller.imageSize = image
        controller.zoom = .oneToOne
        let target = controller.renderTarget
        let visible = controller.visibleImageRect
        let shown = visible.width * Double(image.width) * visible.height * Double(image.height)
        #expect(target.region != nil)
        // Each side rounds up to whole pixels.
        let rounding = Double(target.size.width + target.size.height)
        #expect(Double(target.size.width * target.size.height) <= 2.25 * shown + rounding)
    }

    @Test func `panning inside the rendered margin keeps the target`() throws {
        let controller = makeController()
        controller.zoom = .oneToOne
        let before = controller.renderTarget
        controller.pan(byPoints: CGSize(width: 40, height: 30))
        #expect(controller.renderTarget == before)

        controller.pan(byPoints: CGSize(width: -900, height: 0))
        let after = controller.renderTarget
        let region = try #require(after.region)
        #expect(after != before)
        #expect(after.size == before.size)
        #expect(region.x + region.width >= controller.visibleImageRect.maxX)
        #expect(region.x <= controller.visibleImageRect.minX)
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

    @Test func `side by side fits the photo in each pane`() throws {
        let controller = makeController()
        let fit = controller.fitScale
        controller.comparison = .sideBySide
        // A 3:2 photo in a 1000×800 view shows larger stacked than across.
        #expect(controller.paneAxis(in: controller.viewSize) == .vertical)
        let before = try #require(controller.comparisonStage(in: controller.viewSize))
        let after = controller.stage(in: controller.viewSize)
        #expect(before.maxY + CanvasController.paneGap == after.minY)
        #expect(before.size == after.size)
        #expect(controller.fitScale < fit)
        #expect(controller.renderTarget.size == controller.renderSize)

        let photo = controller.imageRect(in: controller.viewSize)
        let mirrored = try #require(controller.comparisonImageRect(in: controller.viewSize))
        #expect(mirrored.size == photo.size)
        #expect(abs((mirrored.minY - photo.minY) - (before.minY - after.minY)) < 1e-9)

        controller.comparison = .none
        #expect(controller.comparisonStage(in: controller.viewSize) == nil)
        #expect(controller.fitScale == fit)
    }

    @Test func `wide views put the panes side by side`() {
        let controller = makeController()
        controller.updateView(size: CGSize(width: 2000, height: 700), backingScale: 2)
        controller.comparison = .sideBySide
        #expect(controller.paneAxis(in: controller.viewSize) == .horizontal)
    }

    @Test func `a point in the before pane maps to the same spot of the photo`() throws {
        let controller = makeController()
        controller.comparison = .sideBySide
        let photo = controller.imageRect(in: controller.viewSize)
        let mirrored = try #require(controller.comparisonImageRect(in: controller.viewSize))
        let inAfter = CGPoint(x: photo.minX + photo.width * 0.3, y: photo.minY + photo.height * 0.6)
        let inBefore = CGPoint(x: mirrored.minX + mirrored.width * 0.3, y: mirrored.minY + mirrored.height * 0.6)
        let fromAfter = try #require(controller.imagePoint(for: inAfter))
        let fromBefore = try #require(controller.imagePoint(for: inBefore))
        #expect(abs(fromAfter.x - fromBefore.x) < 1e-9)
        #expect(abs(fromAfter.y - fromBefore.y) < 1e-9)
    }

    @Test func `the split line follows the visible photo's diagonal`() throws {
        let controller = makeController()
        #expect(controller.splitLine(in: controller.viewSize) == nil)
        controller.comparison = .split(position: 0.5)
        let frame = controller.visibleImageFrame(in: controller.viewSize)
        let centered = try #require(controller.splitLine(in: controller.viewSize))
        #expect(centered.start == CGPoint(x: frame.maxX, y: frame.minY))
        #expect(centered.end == CGPoint(x: frame.minX, y: frame.maxY))

        controller.comparison = .split(position: 0.25)
        let early = try #require(controller.splitLine(in: controller.viewSize))
        let middle = CGPoint(x: (early.start.x + early.end.x) / 2, y: (early.start.y + early.end.y) / 2)
        #expect(abs(controller.splitPosition(through: middle) - 0.25) < 1e-9)
        #expect(controller.splitPosition(through: CGPoint(x: -500, y: -500)) == 0)
    }

    @Test func `ratio labels`() {
        #expect(CanvasController.zoomRatios.map(CanvasController.ratioLabel) == [
            "1:16", "1:8", "1:4", "1:3", "1:2", "1:1", "2:1", "3:1", "4:1", "8:1", "11:1",
        ])
    }
}
