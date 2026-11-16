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

    @Test func `zoom is limited to a quarter of Fit and 11:1`() {
        let controller = makeController()
        controller.zoom(toScale: 50, anchoredAt: CGPoint(x: 500, y: 400))
        #expect(controller.pixelScale == 11)
        controller.zoom(toScale: 0.01, anchoredAt: CGPoint(x: 500, y: 400))
        #expect(controller.pixelScale == controller.fitScale / 4)
    }

    /// Where each of `notches` leaves the zoom, from `scale`, as a fraction of Fit.
    private func steps(
        _ controller: CanvasController, from scale: Double, _ notches: [Double], holding hold: inout FitHold,
    ) -> [Double] {
        var scale = scale
        return notches.map { notches in
            scale = controller.zoomedScale(from: scale, byNotches: notches, holding: &hold)
            return scale / controller.fitScale
        }
    }

    private func expectClose(
        _ actual: [Double],
        _ expected: [Double],
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (actual, expected) in zip(actual, expected) {
            #expect(abs(actual - expected) < 1e-9, "\(actual) isn't \(expected)", sourceLocation: sourceLocation)
        }
    }

    @Test func `zooming out holds at Fit for six notches of the wheel, then goes on from Fit`() {
        let controller = makeController()
        var hold = FitHold.wheel
        let scales = steps(
            controller,
            from: controller.fitScale * pow(2, 0.5),
            Array(repeating: -1, count: 10),
            holding: &hold,
        )
        // Two notches reach Fit, the next six hold there, and the ninth goes on a notch below it.
        expectClose(scales, [pow(2, 0.25), 1, 1, 1, 1, 1, 1, 1, pow(2, -0.25), pow(2, -0.5)])
    }

    @Test func `a wheel spun hard turns through the hold a notch at a time`() {
        let controller = makeController()
        var hold = FitHold.wheel
        let scales = steps(controller, from: controller.fitScale, Array(repeating: -4, count: 8), holding: &hold)
        expectClose(scales, [1, 1, 1, 1, 1, 1, pow(2, -0.25), pow(2, -1.25)])
        // And on the way back in: the first turn reaches Fit, and the next six hold there.
        let inward = steps(controller, from: controller.minScale, Array(repeating: 4, count: 10), holding: &hold)
        expectClose(inward, [0.5, 1, 1, 1, 1, 1, 1, 1, pow(2, 0.25), pow(2, 1.25)])
    }

    @Test func `zooming in from below holds at Fit for six notches of the wheel, then goes on from Fit`() {
        let controller = makeController()
        var hold = FitHold.wheel
        let scales = steps(
            controller,
            from: controller.fitScale * pow(2, -0.5),
            Array(repeating: 1, count: 10),
            holding: &hold,
        )
        // Two notches reach Fit, the next six hold there, and the ninth goes on a notch above it.
        expectClose(scales, [pow(2, -0.25), 1, 1, 1, 1, 1, 1, 1, pow(2, 0.25), pow(2, 0.5)])
    }

    @Test func `zooming in from Fit passes it at once, and the hold starts again for the next zoom out`() {
        let controller = makeController()
        var hold = FitHold.wheel
        let inward = steps(controller, from: controller.fitScale, [1, 1], holding: &hold)
        expectClose(inward, [pow(2, 0.25), pow(2, 0.5)])
        // Two notches into the hold, a notch in leaves it, and zooming out meets all of it again.
        let wiggle = steps(
            controller, from: controller.fitScale, [-1, -1, 1] + Array(repeating: -1, count: 8), holding: &hold,
        )
        expectClose(wiggle, [1, 1, pow(2, 0.25), 1, 1, 1, 1, 1, 1, 1, pow(2, -0.25)])
    }

    @Test func `turning back at Fit, having come up to it, meets the hold again either way`() {
        let controller = makeController()
        var hold = FitHold.wheel
        // A notch in reaches Fit and two more are held; turning back out is held too, for all six,
        // and so is turning in again, as the zoom came up to Fit and hasn't left it.
        let notches: [Double] = [1, 1, 1] + Array(repeating: -1, count: 5) + Array(repeating: 1, count: 7)
        let scales = steps(controller, from: controller.fitScale * pow(2, -0.25), notches, holding: &hold)
        expectClose(scales, Array(repeating: 1, count: 14) + [pow(2, 0.25)])
    }

    @Test func `a hold that starts again at Fit, as the wheel's does once it rests, passes a zoom in`() {
        let controller = makeController()
        var hold = FitHold.wheel
        let arriving = steps(controller, from: controller.fitScale * pow(2, -0.25), [1, 1], holding: &hold)
        expectClose(arriving, [1, 1])
        hold.restart()
        #expect(controller.zoomedScale(from: controller.fitScale, byNotches: 1, holding: &hold) > controller.fitScale)
    }

    @Test func `zooming out stops at a quarter of Fit`() {
        let controller = makeController()
        var hold = FitHold.wheel
        // Six notches hold at Fit, and eight more reach a quarter of it.
        let scales = steps(controller, from: controller.fitScale, Array(repeating: -1, count: 17), holding: &hold)
        expectClose(Array(scales.suffix(5)), [pow(2, -1.75), 0.25, 0.25, 0.25, 0.25])
    }

    @Test func `a pinch counts its scale in notches and holds at Fit for one`() {
        let controller = makeController()
        var hold = FitHold.pinch
        let middle = CGPoint(x: 500, y: 400)
        // Each 5% pinch is about 0.3 of a notch (four times log2 of 1 / 0.95).
        for _ in 0 ..< 3 {
            controller.magnify(by: 0.95, at: middle, holding: &hold)
        }
        #expect(controller.zoom == .fit)
        controller.magnify(by: 0.95, at: middle, holding: &hold)
        let spent: Double = 4 * 4 * log2(1 / 0.95)
        let below = controller.fitScale * pow(2, -(spent - 1) / 4)
        #expect(abs(controller.pixelScale - below) < 1e-12)
        // Pinching back in holds at Fit for a notch too: 15% is 0.81 of a notch, of which 0.18 reach
        // Fit, and the pinch after spends the rest of the hold and goes on 0.43 of a notch above.
        controller.magnify(by: 1.15, at: middle, holding: &hold)
        #expect(abs(controller.pixelScale - controller.fitScale) < 1e-12)
        controller.magnify(by: 1.15, at: middle, holding: &hold)
        let above = controller.fitScale * pow(2, (2 * 4 * log2(1.15) - (spent - 1) - 1) / 4)
        #expect(abs(controller.pixelScale - above) < 1e-12)
    }

    @Test func `a pinch in from Fit passes it at once`() {
        let controller = makeController()
        var hold = FitHold.pinch
        controller.magnify(by: 1.05, at: CGPoint(x: 500, y: 400), holding: &hold)
        #expect(controller.isZoomedIn)
    }

    @Test func `from a ratio below a quarter of Fit, zooming out goes no further and zooming in doesn't jump`() {
        let controller = makeController()
        var hold = FitHold.wheel
        let ratio = 1.0 / 16
        controller.zoom = .scale(ratio)
        let outward = controller.zoomedScale(from: ratio, byNotches: -1, holding: &hold)
        #expect(outward == ratio)
        let inward = controller.zoomedScale(from: ratio, byNotches: 1, holding: &hold)
        let notchIn = ratio * pow(2, 0.25)
        #expect(abs(inward - notchIn) < 1e-12)
    }

    private func isClose(_ rect: CGRect, _ other: CGRect) -> Bool {
        abs(rect.minX - other.minX) < 1e-9 && abs(rect.minY - other.minY) < 1e-9
            && abs(rect.width - other.width) < 1e-9 && abs(rect.height - other.height) < 1e-9
    }

    private func isClose(_ point: CGPoint, _ x: Double, _ y: Double) -> Bool {
        abs(point.x - x) < 1e-9 && abs(point.y - y) < 1e-9
    }

    private func isCentred(_ rect: CGRect, in area: CGRect) -> Bool {
        isClose(CGPoint(x: rect.midX, y: rect.midY), area.midX, area.midY)
    }

    @Test func `below Fit the photo stays centred on the stage, at its own shape, and the tools land on it`() throws {
        let controller = makeController()
        controller.stageInsets = StageInsets(leading: 100, trailing: 40, top: 52, bottom: 20)
        let fit = controller.imageRect(in: controller.viewSize)
        // Where an earlier zoom left the view's centre.
        controller.center = CGPoint(x: 0.9, y: 0.1)
        controller.zoom(toScale: controller.minScale, anchoredAt: CGPoint(x: 900, y: 100))
        let stage = controller.stage(in: controller.viewSize)
        let photo = controller.imageRect(in: controller.viewSize)
        #expect(isCentred(photo, in: stage))
        let quarter = CGSize(width: fit.width / 4, height: fit.height / 4)
        #expect(isClose(photo, CGRect(origin: photo.origin, size: quarter)))
        #expect(!controller.isZoomedIn)

        let inside = CGPoint(x: photo.minX + photo.width * 0.25, y: photo.minY + photo.height * 0.75)
        let point = try #require(controller.imagePoint(for: inside))
        #expect(isClose(point, 0.25, 0.75))
        #expect(controller.imagePoint(for: CGPoint(x: photo.minX - 2, y: photo.midY)) == nil)

        // The Navigator sees all of it; the engine renders it whole, at the size it shows.
        #expect(isClose(controller.visibleImageRect, CGRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(controller.renderTarget.region == nil)
        #expect(controller.renderTarget.size == controller.renderSize)
        let shown = Double(photo.width) * 2
        #expect(abs(Double(controller.renderSize.width) - shown) <= 1)
    }

    @Test func `below Fit, Before and After's panes and split follow the smaller photo`() throws {
        let controller = makeController()
        controller.comparison = .sideBySide
        controller.zoom(toScale: controller.minScale, anchoredAt: .zero)
        let afterPane = controller.stage(in: controller.viewSize)
        let beforePane = try #require(controller.comparisonStage(in: controller.viewSize))
        let after = controller.imageRect(in: controller.viewSize)
        let before = try #require(controller.comparisonImageRect(in: controller.viewSize))
        #expect(isCentred(after, in: afterPane))
        #expect(isCentred(before, in: beforePane))
        let inBefore = CGPoint(x: before.minX + before.width * 0.3, y: before.minY + before.height * 0.6)
        let fromBefore = try #require(controller.imagePoint(for: inBefore))
        #expect(isClose(fromBefore, 0.3, 0.6))

        controller.comparison = .split(position: 0.5)
        let photo = controller.imageRect(in: controller.viewSize)
        let frame = controller.visibleImageFrame(in: controller.viewSize)
        #expect(isClose(frame, photo))
        let line = try #require(controller.splitLine(in: controller.viewSize))
        #expect(line.start == CGPoint(x: frame.maxX, y: frame.minY))
        #expect(line.end == CGPoint(x: frame.minX, y: frame.maxY))
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

    @Test func `zoom out steps past Fit to a half and a quarter of it, and zoom in comes back to Fit`() {
        let controller = makeController()
        controller.zoom = .oneToOne
        var scales: [Double] = []
        while true {
            controller.zoomOut()
            guard scales.last != controller.pixelScale else { break }
            scales.append(controller.pixelScale)
        }
        let expected: [Double] = [0.5, 1.0 / 3, 1.0 / 6, 1.0 / 12]
        #expect(scales == expected)
        controller.zoomIn()
        controller.zoomIn()
        #expect(controller.zoom == .fit)
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
