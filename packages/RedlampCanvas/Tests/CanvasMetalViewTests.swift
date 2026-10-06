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
        withKnownIssue("MEM-06: the canvas keeps up to 16 surfaces") {
            #expect(Set(view.textures.keys) == Set(fit.prefix(2).map(IOSurfaceGetID)))
        }
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
        withKnownIssue("MEM-06: the canvas keeps up to 16 surfaces") {
            #expect(view.textures.count <= 8)
        }
        view.display(nil)
        withKnownIssue("MEM-06: the canvas keeps up to 16 surfaces") {
            #expect(view.textures.isEmpty)
        }
    }
}
