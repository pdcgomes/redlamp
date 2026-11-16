import AppKit
import IOSurface
import RedlampEngineAPI
import Testing
@testable import RedlampCanvas

/// What a canvas keeps of the surfaces it has shown: the engine rebuilds its rings when the render
/// size changes, and a surface the canvas still holds stays in memory.
@MainActor
struct CanvasMetalViewTests {
    /// Three surfaces, as the engine's `SurfacePool` makes for one size.
    private func ring(_ width: Int, _ height: Int) throws -> [IOSurfaceRef] {
        try (0 ..< 3).map { _ in
            let properties: [CFString: Any] = [
                kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 8,
                kIOSurfacePixelFormat: 0x5247_6841,
            ]
            return try #require(IOSurfaceCreate(properties as CFDictionary))
        }
    }

    private func size(_ surface: IOSurfaceRef) -> PixelSize {
        PixelSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
    }

    private func frame(
        _ surface: IOSurfaceRef, overview: IOSurfaceRef? = nil, comparison: IOSurfaceRef? = nil,
        comparisonOverview: IOSurfaceRef? = nil,
    ) -> RenderedFrame {
        let region = overview == nil ? ImageRect.full : ImageRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        return RenderedFrame(
            surface: surface, size: size(surface), region: region, overview: overview,
            overviewSize: overview.map(size) ?? .zero, comparison: comparison,
            comparisonOverview: comparisonOverview, histogram: .empty, generation: 0, renderDuration: .zero,
        )
    }

    @Test func `a canvas lets go of the full-size ring once it shows frames from the next one`() throws {
        let view = CanvasMetalView(controller: CanvasController())
        // A 24 MP photo at 1:1, panned so each of the ring's surfaces is shown, then back to Fit.
        let oneToOne = try ring(6024, 4024)
        let fit = try ring(2395, 1600)
        for surface in oneToOne + fit.prefix(2) {
            view.display(frame(surface))
        }
        #expect(Set(view.textures.keys) == Set(fit.prefix(2).map(IOSurfaceGetID)))
    }

    @Test func `a canvas holds the surfaces of two frames at most`() throws {
        let view = CanvasMetalView(controller: CanvasController())
        let (surfaces, overviews) = try (ring(1200, 800), ring(600, 400))
        let (comparisons, comparisonOverviews) = try (ring(1200, 800), ring(600, 400))
        for index in 0 ..< 6 {
            view.display(frame(
                surfaces[index % 3], overview: overviews[index % 3], comparison: comparisons[index % 3],
                comparisonOverview: comparisonOverviews[index % 3],
            ))
        }
        #expect(view.textures.count <= 8)
        view.display(nil)
        #expect(view.textures.isEmpty)
    }

    /// A 6000×4000 photo at Fit in a 1000×800 pt view.
    private func fittedView() -> (CanvasMetalView, CanvasController) {
        let controller = CanvasController()
        controller.imageSize = PixelSize(width: 6000, height: 4000)
        let view = CanvasMetalView(controller: controller)
        view.setFrameSize(NSSize(width: 1000, height: 800))
        return (view, controller)
    }

    /// A notch of a mouse wheel, rolled away from you or towards you, whatever the scrolling
    /// direction setting, at least `rest` seconds after now.
    private func notch(away: Bool, restingFor rest: Double = 0) throws -> NSEvent {
        func event(_ lines: Int32) throws -> NSEvent {
            let cgEvent = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0,
            ))
            cgEvent.flags = []
            cgEvent.timestamp += UInt64(rest * 1e9)
            return try #require(NSEvent(cgEvent: cgEvent))
        }
        let rolled = try event(1)
        return try (CanvasMetalView.notches(of: rolled) > 0) == away ? rolled : event(-1)
    }

    /// A trackpad pinch's event as the trackpad makes one: a gesture (type 29) of the magnify kind
    /// (8, in field 110), `magnification` in field 113, and its phase in field 132 (1 began, 2
    /// changed, 4 ended).
    private func pinch(_ magnification: Double, phase: Int64) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(source: nil))
        cgEvent.type = try #require(CGEventType(rawValue: 29))
        try cgEvent.setIntegerValueField(#require(CGEventField(rawValue: 110)), value: 8)
        try cgEvent.setDoubleValueField(#require(CGEventField(rawValue: 113)), value: magnification)
        try cgEvent.setIntegerValueField(#require(CGEventField(rawValue: 132)), value: phase)
        let event = try #require(NSEvent(cgEvent: cgEvent))
        try #require(event.type == .magnify)
        return event
    }

    @Test func `the wheel holds at Fit for six notches, through each notch's easing, until it rests`() throws {
        let (view, controller) = fittedView()
        defer { view.stopWheelZoom() }
        let fit = controller.fitScale
        for _ in 0 ..< 6 {
            try view.scrollWheel(with: notch(away: false))
            #expect(view.wheelZoom.target == fit)
            // At Fit, each notch's easing ends at once.
            view.stopWheelZoom()
        }
        // After a rest the hold starts again: this is its first notch.
        try view.scrollWheel(with: notch(away: false, restingFor: 10))
        #expect(view.wheelZoom.target == fit)
        view.stopWheelZoom()
        for _ in 0 ..< 5 {
            try view.scrollWheel(with: notch(away: false))
            view.stopWheelZoom()
        }
        try view.scrollWheel(with: notch(away: false))
        let target = try #require(view.wheelZoom.target)
        let notchBelow = fit * pow(2, -0.25)
        #expect(abs(target - notchBelow) < 1e-12)
    }

    @Test func `the wheel coming up to Fit holds there for six notches, and from Fit it zooms in at once`() throws {
        let (view, controller) = fittedView()
        defer { view.stopWheelZoom() }
        let fit = controller.fitScale
        let notchAbove = fit * pow(2, 0.25)
        controller.zoom = .scale(fit * pow(2, -0.25))
        // A notch in reaches Fit, and the next six hold there.
        for _ in 0 ..< 7 {
            try view.scrollWheel(with: notch(away: true))
            #expect(view.wheelZoom.target == fit)
        }
        try view.scrollWheel(with: notch(away: true))
        var target = try #require(view.wheelZoom.target)
        #expect(abs(target - notchAbove) < 1e-12)
        // Coming up to Fit and resting there, the wheel then starts from Fit.
        view.stopWheelZoom()
        controller.zoom = .scale(fit * pow(2, -0.25))
        try view.scrollWheel(with: notch(away: true))
        #expect(view.wheelZoom.target == fit)
        view.stopWheelZoom()
        controller.zoom = .fit
        try view.scrollWheel(with: notch(away: true, restingFor: 10))
        target = try #require(view.wheelZoom.target)
        #expect(abs(target - notchAbove) < 1e-12)
    }

    @Test func `each pinch meets the hold at Fit again, and a pinch in holds only coming up to Fit`() throws {
        let (view, controller) = fittedView()
        // Each 5% step spends about 0.3 of the pinch's one notch.
        for phase: Int64 in [1, 2, 2] {
            try view.magnify(with: pinch(-0.05, phase: phase))
        }
        try view.magnify(with: pinch(0, phase: 4))
        #expect(controller.zoom == .fit)
        try view.magnify(with: pinch(-0.05, phase: 1))
        #expect(controller.zoom == .fit, "a new pinch starts the hold again")
        for _ in 0 ..< 3 {
            try view.magnify(with: pinch(-0.05, phase: 2))
        }
        #expect(controller.pixelScale < controller.fitScale)
        // Back in, the pinch reaches Fit and holds there for a notch (a 10% step is 0.55 of one).
        try view.magnify(with: pinch(0.1, phase: 2))
        #expect(abs(controller.pixelScale - controller.fitScale) < 1e-12)
        try view.magnify(with: pinch(0.1, phase: 2))
        #expect(abs(controller.pixelScale - controller.fitScale) < 1e-12)
        try view.magnify(with: pinch(0.3, phase: 2))
        #expect(controller.isZoomedIn)
        try view.magnify(with: pinch(0, phase: 4))
        // A pinch that starts at Fit zooms in at once.
        controller.zoom = .fit
        try view.magnify(with: pinch(0.05, phase: 1))
        #expect(controller.isZoomedIn)
        try view.magnify(with: pinch(0, phase: 4))
    }

    @Test func `panning a zoomed-in canvas redraws it without a SwiftUI update`() async throws {
        let controller = CanvasController()
        controller.imageSize = PixelSize(width: 6000, height: 4000)
        let view = CanvasMetalView(controller: controller)
        view.setFrameSize(NSSize(width: 1000, height: 800))
        controller.zoom = .oneToOne
        try view.display(frame(ring(1200, 800)[0]))
        let before = try #require(view.publishedRects.first)
        controller.pan(byPoints: CGSize(width: 50, height: 0))
        try await Task.sleep(for: .milliseconds(50))
        let after = try #require(view.publishedRects.first)
        #expect(after != before)
    }
}
