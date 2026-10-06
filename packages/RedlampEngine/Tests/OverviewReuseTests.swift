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
    /// Highlights, Shadows, Clarity and Dehaze read the retouched photo's maps, so the overview
    /// shows when they're made again.
    private func removal(_ retouch: RetouchTests) -> EditRecipe {
        var recipe = EditRecipe()
        recipe[.highlights] = -100
        recipe[.shadows] = 100
        recipe[.clarity] = 100
        recipe[.dehaze] = 60
        var spot = retouch.spot(.remove)
        spot.source = spot.center
        recipe.spots = [spot]
        return recipe
    }

    private func request(_ recipe: EditRecipe, at x: Double) -> RenderRequest {
        RenderRequest(
            recipe: recipe, targetSize: PixelSize(width: RetouchTests.width / 2, height: RetouchTests.height / 2),
            region: ImageRect(x: x, y: 0.25, width: 0.5, height: 0.5),
        )
    }

    /// The green channel of `surface`.
    private func pixels(_ surface: IOSurfaceRef?, _ size: PixelSize) throws -> [Float] {
        let surface = try #require(surface)
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        var values = [Float](repeating: 0, count: size.width * size.height)
        for y in 0 ..< size.height {
            let row = (IOSurfaceGetBaseAddress(surface) + y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0 ..< size.width {
                values[y * size.width + x] = Float(row[x * 4 + 1])
            }
        }
        return values
    }

    @Test func `a region frame's overview is rendered again once the retouched photo's maps are made`(
    ) async throws {
        let retouch = try RetouchTests()
        let engine = try RedlampEngine()
        let session = try retouch.scene(blemished: true)
        let recipe = removal(retouch)
        func overview(at x: Double) throws -> [Float] {
            let frame = try engine.renderFrame(request(recipe, at: x), session: session)
            return try pixels(frame.overview, frame.overviewSize)
        }

        let first = try overview(at: 0)
        var refreshed = first
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        var step = 0
        while refreshed == first, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            step += 1
            refreshed = try overview(at: step.isMultiple(of: 2) ? 0.5 : 0)
        }
        let changed = refreshed != first
        #expect(changed, "the overview shows the maps made again")
    }

    /// A still (or an export) makes the retouched photo's maps itself, which frames read from
    /// then on; the overview must too, whether or not the background refresh has come back yet.
    @Test func `the overview follows retouched maps a still made`() throws {
        let retouch = try RetouchTests()
        let recipe = removal(retouch)
        for attempt in 0 ..< 8 {
            let engine = try RedlampEngine()
            let session = try retouch.scene(blemished: true)
            _ = try engine.renderFrame(request(recipe, at: 0), session: session)
            _ = try engine.renderStillNow(StillRequest(recipe: recipe), session: session)
            let panned = try engine.renderFrame(request(recipe, at: 0.5), session: session)
            let shown = try pixels(panned.overview, panned.overviewSize)
            // No mask overlay is shown, so its opacity changes only the key: a fresh overview.
            var fresh = request(recipe, at: 0.5)
            fresh.maskOverlayOpacity = 0.3
            let reference = try engine.renderFrame(fresh, session: session)
            let same = try shown == pixels(reference.overview, reference.overviewSize)
            let histogram = panned.histogram == reference.histogram
            #expect(same, "attempt \(attempt): the overview kept the maps from before the still")
            #expect(histogram, "attempt \(attempt)")
        }
    }

    @Test func `a look registered after the overview was rendered renders it and the comparison again`(
    ) async throws {
        let url = try BaseLookTests.chart()
        defer { try? FileManager.default.removeItem(at: url) }
        let dark = try BaseLookDefinition(
            id: "local/test/overview-dark", version: 1, name: "Dark", parameters: .identity,
            table: LookTable(size: 9, space: .sceneLog) { _ in SIMD3(repeating: 0.2) },
        )
        var recipe = EditRecipe()
        recipe.baseLook = dark.reference
        var request = RenderRequest(
            recipe: recipe, targetSize: PixelSize(width: 64, height: 64),
            region: ImageRect(x: 0.25, y: 0.25, width: 0.25, height: 0.5),
        )
        request.comparison = recipe

        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        var frames = engine.frames().makeAsyncIterator()
        request.generation = 1
        engine.render(request)
        _ = try #require(await frames.next())
        engine.registerBaseLook(dark)
        request.generation = 2
        engine.render(request)
        let after = try #require(await frames.next())

        let fresh = try RedlampEngine()
        _ = try await fresh.open(url)
        fresh.registerBaseLook(dark)
        var freshFrames = fresh.frames().makeAsyncIterator()
        fresh.render(request)
        let reference = try #require(await freshFrames.next())

        let overview = try pixels(after.overview, after.overviewSize)
            == pixels(reference.overview, reference.overviewSize)
        let histogram = after.histogram == reference.histogram
        #expect(overview, "the overview shows the look")
        #expect(histogram)
        let comparison = try pixels(after.comparison, after.size) == pixels(reference.comparison, reference.size)
        #expect(comparison, "the comparison shows the look")
        let comparisonOverview = try pixels(after.comparisonOverview, after.overviewSize)
            == pixels(reference.comparisonOverview, reference.overviewSize)
        #expect(comparisonOverview)
    }
}
