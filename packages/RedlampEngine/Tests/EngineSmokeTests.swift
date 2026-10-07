import CoreGraphics
import Foundation
import IOSurface
import Metal
import RedlampEngineAPI
import Testing
@testable import RedlampEngine

/// Renders every downloaded fixture (tests/fixtures/raw, fetched from raw.pixls.us).
struct EngineSmokeTests {
    /// Needs the sample files and a Metal GPU (hosted CI VMs may have neither).
    static let canRender = !fixtures.isEmpty && MTLCreateSystemDefaultDevice() != nil

    static let fixtures: [URL] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/fixtures/raw")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter(SupportedFormats.isSupported).sorted { $0.path < $1.path }
    }()

    @Test(.enabled(if: canRender), arguments: fixtures)
    func `opens and renders`(url: URL) async throws {
        let engine = try RedlampEngine()
        let info = try await engine.open(url)
        #expect(info.pixelSize.width > 0)
        #expect(info.isRaw)
        let image = try await engine.renderStill(StillRequest(recipe: EditRecipe(), maxLongEdge: 512))
        #expect(max(image.width, image.height) == 512)
    }

    @Test(.enabled(if: canRender))
    func `interactive render delivers frame`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(Self.fixtures[0])
        let frames = engine.frames()
        engine.render(RenderRequest(
            recipe: EditRecipe(),
            targetSize: PixelSize(width: 800, height: 800),
            generation: 7,
        ))
        var iterator = frames.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        #expect(frame.generation == 7)
        #expect(frame.size.longEdge == 800)
        #expect(frame.histogram.totalCount > 0)
    }

    @Test(.enabled(if: canRender))
    func `prefetched image opens without waiting`() async throws {
        let engine = try RedlampEngine()
        let url = Self.fixtures[0]
        #expect(engine.openIfReady(url) == nil)

        engine.prefetch([url])
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        var ready: ImageInfo?
        while ready == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            ready = engine.openIfReady(url)
        }
        let info = try #require(ready)
        #expect(info.url == url)

        let started = clock.now
        _ = try await engine.open(url)
        #expect(clock.now - started < .milliseconds(20))
    }

    @Test(.enabled(if: canRender && fixtures.count >= 2))
    func `open cancels when the image is no longer wanted`() async throws {
        let engine = try RedlampEngine()
        let first = Self.fixtures[0]
        let second = Self.fixtures[1]
        let opened = Task { try await engine.open(first) }
        try await Task.sleep(for: .milliseconds(1))
        _ = try await engine.open(second)
        await #expect(throws: CancellationError.self) { try await opened.value }
    }

    /// A linear gradient darkening the top darkens the top rows and leaves the bottom
    /// rows untouched.
    @Test(.enabled(if: canRender))
    func `linear mask darkens only its region`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(Self.fixtures[0])
        let plain = try await engine.renderStill(StillRequest(recipe: EditRecipe(), maxLongEdge: 256))

        var recipe = EditRecipe()
        var mask = MaskLayer(name: "Top", components: [
            MaskComponent(shape: .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.5)))),
        ])
        mask[.localExposure] = -2
        recipe.masks = [mask]
        let masked = try await engine.renderStill(StillRequest(recipe: recipe, maxLongEdge: 256))

        let bottomRows = (plain.height - 10) ..< plain.height
        #expect(brightness(masked, rows: 0 ..< 10) < brightness(plain, rows: 0 ..< 10) * 0.6)
        #expect(abs(brightness(masked, rows: bottomRows) - brightness(plain, rows: bottomRows)) < 0.5)
    }

    /// Rendering only part of the photo must give exactly the pixels a full render has there,
    /// including everything positioned on the whole photo: masks, vignette and grain.
    @Test(.enabled(if: canRender))
    func `region render matches a crop of the full render`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(Self.fixtures[0])
        var recipe = EditRecipe()
        recipe[.vignetteAmount] = -40
        recipe[.grainAmount] = 40
        var mask = MaskLayer(name: "Spot", components: [
            MaskComponent(shape: .radial(RadialMask(center: ImagePoint(x: 0.4, y: 0.45), radiusX: 0.2, radiusY: 0.15))),
        ])
        mask[.localExposure] = 1
        recipe.masks = [mask]

        let frames = engine.frames()
        var iterator = frames.makeAsyncIterator()
        engine.render(RenderRequest(recipe: recipe, targetSize: PixelSize(width: 1200, height: 1200), generation: 1))
        let full = try #require(await iterator.next())
        let fullPixels = pixels(of: full)

        let x0 = full.size.width / 4, y0 = full.size.height / 3, width = 320, height = 240
        let region = ImageRect(
            x: Double(x0) / Double(full.size.width), y: Double(y0) / Double(full.size.height),
            width: Double(width) / Double(full.size.width), height: Double(height) / Double(full.size.height),
        )
        engine.render(RenderRequest(
            recipe: recipe, targetSize: PixelSize(width: width, height: height), region: region, generation: 2,
        ))
        let part = try #require(await iterator.next())
        #expect(part.region == region)
        #expect(part.size == PixelSize(width: width, height: height))
        #expect(part.histogram.totalCount > 0)

        let partPixels = pixels(of: part)
        var largest: Float = 0
        for y in 0 ..< height {
            for x in 0 ..< width {
                for channel in 0 ..< 3 {
                    let a = partPixels[(y * width + x) * 4 + channel]
                    let b = fullPixels[((y0 + y) * full.size.width + x0 + x) * 4 + channel]
                    largest = max(largest, abs(a - b))
                }
            }
        }
        #expect(largest < 2e-3)
    }

    /// The comparison recipe renders like a main render of it, and survives edits to the main
    /// recipe without being re-rendered or overwritten.
    @Test(.enabled(if: canRender))
    func `comparison renders once and is reused while editing`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(Self.fixtures[0])
        let frames = engine.frames()
        var iterator = frames.makeAsyncIterator()
        let size = PixelSize(width: 600, height: 600)
        let before = EditRecipe()

        engine.render(RenderRequest(recipe: before, targetSize: size, generation: 1))
        let reference = try #require(await iterator.next())
        let referencePixels = pixels(of: reference.surface, size: reference.size)

        var edited = EditRecipe()
        var comparedSurfaces: [IOSurfaceID] = []
        for (step, exposure) in [0.5, 1.0, 1.5, 2.0].enumerated() {
            edited[.exposure] = exposure
            var request = RenderRequest(recipe: edited, targetSize: size, generation: UInt64(step + 2))
            request.comparison = before
            engine.render(request)
            let frame = try #require(await iterator.next())
            let comparison = try #require(frame.comparison)
            comparedSurfaces.append(IOSurfaceGetID(comparison))
            #expect(pixels(of: comparison, size: frame.size) == referencePixels)
        }
        #expect(Set(comparedSurfaces).count == 1)

        engine.render(RenderRequest(recipe: edited, targetSize: size, generation: 9))
        #expect(try #require(await iterator.next()).comparison == nil)
    }

    /// Panning only moves the region: the frame keeps the previous overview of the whole photo
    /// and the histogram made from it, the same as a fresh render's, until the overview changes.
    @Test(.enabled(if: canRender))
    func `a pan reuses the overview and its histogram`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(Self.fixtures[0])
        var frames = engine.frames().makeAsyncIterator()
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        func request(
            at x: Double,
            _ recipe: EditRecipe,
            clipping: Bool = false,
            _ generation: UInt64,
        ) -> RenderRequest {
            RenderRequest(
                recipe: recipe, targetSize: PixelSize(width: 320, height: 240),
                region: ImageRect(x: x, y: 0.3, width: 0.2, height: 0.2), showClipping: clipping,
                generation: generation,
            )
        }

        engine.render(request(at: 0.1, recipe, 1))
        let first = try #require(await frames.next())
        let overview = try #require(first.overview)
        engine.render(request(at: 0.4, recipe, 2))
        let panned = try #require(await frames.next())
        let reused = try #require(panned.overview)
        #expect(IOSurfaceGetID(reused) == IOSurfaceGetID(overview))
        #expect(panned.overviewSize == first.overviewSize)
        #expect(panned.histogram == first.histogram)

        let fresh = try RedlampEngine()
        _ = try await fresh.open(Self.fixtures[0])
        var freshFrames = fresh.frames().makeAsyncIterator()
        fresh.render(request(at: 0.4, recipe, 1))
        let reference = try #require(await freshFrames.next())
        let referenceOverview = try #require(reference.overview)
        #expect(pixels(of: reused, size: panned.overviewSize) == pixels(
            of: referenceOverview, size: reference.overviewSize,
        ))
        #expect(panned.histogram == reference.histogram)

        var edited = recipe
        edited[.exposure] = 1
        engine.render(request(at: 0.4, edited, 3))
        let changed = try #require(await frames.next())
        let changedOverview = try #require(changed.overview)
        #expect(IOSurfaceGetID(changedOverview) != IOSurfaceGetID(overview))
        #expect(changed.histogram != first.histogram)
        engine.render(request(at: 0.4, edited, clipping: true, 4))
        let clipped = try #require(await frames.next())
        #expect(try IOSurfaceGetID(#require(clipped.overview)) != IOSurfaceGetID(changedOverview))
    }

    /// A pinch or a resize changes the frame's size every frame: once the ring holds the larger
    /// size, frames of either size render into the surfaces it has, as they would alone.
    @Test(.enabled(if: canRender))
    func `frames of alternating sizes reuse their surfaces`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(Self.fixtures[0])
        let sizes = [PixelSize(width: 1640, height: 1640), PixelSize(width: 1600, height: 1600)]
        func render(_ index: Int, on engine: RedlampEngine) throws -> RenderedFrame {
            try engine.renderFrame(
                RenderRequest(recipe: EditRecipe(), targetSize: sizes[index % 2], generation: UInt64(index)),
                session: #require(engine.currentSession()),
            )
        }
        for index in 0 ..< 6 {
            _ = try render(index, on: engine)
        }
        let made = engine.surfaces.surfacesMade
        var last: RenderedFrame?
        for index in 0 ..< 12 {
            let frame = try render(index, on: engine)
            #expect(frame.size.longEdge == sizes[index % 2].longEdge)
            last = frame
        }
        #expect(engine.surfaces.surfacesMade - made <= 1)

        let frame = try #require(last)
        let fresh = try RedlampEngine()
        _ = try await fresh.open(Self.fixtures[0])
        let reference = try render(11, on: fresh)
        #expect(frame.size == reference.size)
        #expect(pixels(of: frame) == pixels(of: reference), "the same pixels in a larger surface")
    }

    /// RGBA float16 surface contents, row-major and tightly packed.
    private func pixels(of frame: RenderedFrame) -> [Float] {
        pixels(of: frame.surface, size: frame.size)
    }

    private func pixels(of surface: IOSurfaceRef, size: PixelSize) -> [Float] {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        var result = [Float](repeating: 0, count: size.width * size.height * 4)
        for y in 0 ..< size.height {
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float16.self)
            for x in 0 ..< size.width * 4 {
                result[y * size.width * 4 + x] = Float(row[x])
            }
        }
        return result
    }

    private func brightness(_ image: CGImage, rows: Range<Int>) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var total = 0.0
        for row in rows {
            for x in 0 ..< width {
                let index = (row * width + x) * 4
                total += Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])
            }
        }
        return total / Double(rows.count * width * 3)
    }
}
