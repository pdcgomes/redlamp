import Foundation
import IOSurface
import Metal
import RedlampEngineAPI
import Testing
@testable import RedlampEngine

/// A frame that shows part of the photo keeps the previous overview while only the region
/// moves (PIPE-01), but not past anything the overview depends on.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct OverviewReuseTests {
    @Test func `a region frame's overview is rendered again once the retouched photo's maps are made`(
    ) async throws {
        let retouch = try RetouchTests()
        let engine = try RedlampEngine()
        let session = try retouch.scene(blemished: true)
        var recipe = EditRecipe()
        recipe[.highlights] = -100
        recipe[.shadows] = 100
        recipe[.clarity] = 100
        recipe[.dehaze] = 60
        var spot = retouch.spot(.remove)
        spot.source = spot.center
        recipe.spots = [spot]
        func overview(at x: Double) throws -> [Float] {
            let frame = try engine.renderFrame(
                RenderRequest(
                    recipe: recipe, targetSize: PixelSize(
                        width: RetouchTests.width / 2,
                        height: RetouchTests.height / 2,
                    ),
                    region: ImageRect(x: x, y: 0.25, width: 0.5, height: 0.5),
                ),
                session: session,
            )
            let surface = try #require(frame.overview)
            IOSurfaceLock(surface, .readOnly, nil)
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            let rowBytes = IOSurfaceGetBytesPerRow(surface)
            var values = [Float](repeating: 0, count: frame.overviewSize.width * frame.overviewSize.height)
            for y in 0 ..< frame.overviewSize.height {
                let row = (IOSurfaceGetBaseAddress(surface) + y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0 ..< frame.overviewSize.width {
                    values[y * frame.overviewSize.width + x] = Float(row[x * 4 + 1])
                }
            }
            return values
        }

        let first = try overview(at: 0)
        var refreshed = first
        for step in 0 ..< 150 where refreshed == first {
            try await Task.sleep(for: .milliseconds(20))
            refreshed = try overview(at: step.isMultiple(of: 2) ? 0.5 : 0)
        }
        let changed = refreshed != first
        #expect(changed, "the overview shows the maps made again")
    }
}
