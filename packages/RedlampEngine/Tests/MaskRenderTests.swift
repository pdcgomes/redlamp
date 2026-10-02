import Foundation
import IOSurface
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampMasking
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Brush rasters, range masks and bitmaps, on synthetic linear photos through the real engine.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MaskRenderTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    // MARK: - Brush

    @Test func `brush raster matches the reference`() throws {
        let session = try makeSession(width: 320, height: 200) { _, _ in SIMD3(repeating: 0.2) }
        let brush = BrushMask(strokes: [
            BrushStroke(
                points: [ImagePoint(x: 0.1, y: 0.2), ImagePoint(x: 0.5, y: 0.5), ImagePoint(x: 0.8, y: 0.4)],
                size: 0.08, feather: 60, flow: 70, density: 90,
            ),
            BrushStroke(points: [ImagePoint(x: 0.3, y: 0.1), ImagePoint(x: 0.35, y: 0.9)], size: 0.05, flow: 100),
            BrushStroke(
                points: [ImagePoint(x: 0.5, y: 0.2), ImagePoint(x: 0.5, y: 0.8)], pressures: [0.3, 1], size: 0.04,
                feather: 20, flow: 80, erase: true,
            ),
        ])
        let resources = try MaskResources(device: device, kernels: kernels)
        resources.use(session)
        let gpu = try raster(brush, resources: resources)
        let reference = BrushReference.raster(brush, size: resources.rasterSize)
        let worst = zip(gpu, reference).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 2e-3, "largest difference \(worst)")
        #expect((reference.max() ?? 0) > 0.85)
    }

    /// Painting redraws only the stroke being drawn; the result must match drawing it all at once.
    @Test func `painting incrementally matches a full redraw`() throws {
        let session = try makeSession(width: 300, height: 300) { _, _ in SIMD3(repeating: 0.2) }
        let first = BrushStroke(points: [ImagePoint(x: 0.2, y: 0.2), ImagePoint(x: 0.8, y: 0.3)], size: 0.06, flow: 50)
        var second = BrushStroke(points: [ImagePoint(x: 0.5, y: 0.1)], size: 0.07, flow: 60)
        let resources = try MaskResources(device: device, kernels: kernels)
        resources.use(session)
        _ = try raster(BrushMask(strokes: [first]), resources: resources)
        for point in [ImagePoint(x: 0.5, y: 0.4), ImagePoint(x: 0.45, y: 0.7), ImagePoint(x: 0.3, y: 0.9)] {
            second.points.append(point)
            _ = try raster(BrushMask(strokes: [first, second]), resources: resources)
        }
        let painted = try raster(BrushMask(strokes: [first, second]), resources: resources)

        let fresh = try MaskResources(device: device, kernels: kernels)
        fresh.use(session)
        let full = try raster(BrushMask(strokes: [first, second]), resources: fresh)
        let worst = zip(painted, full).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-3, "largest difference \(worst)")
    }

    @Test func `brush mask brightens only where painted`() throws {
        let session = try makeSession(width: 400, height: 300) { _, _ in SIMD3(repeating: 0.18) }
        var mask = MaskLayer(name: "Brush", components: [MaskComponent(shape: .brush(BrushMask(strokes: [
            BrushStroke(points: [ImagePoint(x: 0.1, y: 0.5), ImagePoint(x: 0.4, y: 0.5)], size: 0.1, feather: 0),
        ])))])
        mask[.localExposure] = 1
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let plain = try render(EditRecipe(), session: session)
        let brushed = try render(recipe, session: session)
        let painted = 150 * 400 + 100
        let untouched = 150 * 400 + 320
        #expect(brushed[painted].y > plain[painted].y * 1.3)
        #expect(abs(brushed[untouched].y - plain[untouched].y) < 1e-3)
    }

    // MARK: - Ranges

    /// A dark left half and a bright right half: a range over the bright tones selects the right.
    @Test func `luminance range selects by lightness`() throws {
        let session = try makeSession(width: 400, height: 200) { x, _ in SIMD3(repeating: x < 200 ? 0.03 : 0.5) }
        var mask = MaskLayer(name: "Brights", components: [
            MaskComponent(shape: .luminanceRange(LuminanceRangeMask(lower: 60, upper: 100, lowerFeather: 10))),
        ])
        mask[.localExposure] = -1.5
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let plain = try render(EditRecipe(), session: session)
        let ranged = try render(recipe, session: session)
        let dark = 100 * 400 + 60
        let bright = 100 * 400 + 340
        #expect(ranged[bright].y < plain[bright].y * 0.6)
        #expect(abs(ranged[dark].y - plain[dark].y) < 2e-3)
    }

    /// Blue on the left, orange on the right: sampling the blue selects only the left.
    @Test func `color range selects the sampled colour`() throws {
        let session = try makeSession(width: 400, height: 200) { x, _ in
            x < 200 ? SIMD3(0.05, 0.12, 0.4) : SIMD3(0.45, 0.2, 0.05)
        }
        var mask = MaskLayer(name: "Blue", components: [
            MaskComponent(shape: .colorRange(ColorRangeMask(samples: [ColorSample(center: ImagePoint(
                x: 0.2,
                y: 0.5,
            ))]))),
        ])
        mask[.localExposure] = 1
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let plain = try render(EditRecipe(), session: session)
        let ranged = try render(recipe, session: session)
        let blue = 100 * 400 + 60
        let orange = 100 * 400 + 340
        #expect(ranged[blue].z > plain[blue].z * 1.3)
        #expect(abs(ranged[orange].x - plain[orange].x) < 2e-3)
    }

    /// The selection follows global edits: the guide is re-rendered when they change.
    @Test func `range masks follow the global edit`() throws {
        let session = try makeSession(width: 400, height: 200) { x, _ in SIMD3(repeating: x < 200 ? 0.03 : 0.5) }
        var mask = MaskLayer(name: "Darks", components: [
            MaskComponent(shape: .luminanceRange(LuminanceRangeMask(lower: 0, upper: 45, upperFeather: 5))),
        ])
        mask[.localExposure] = 1
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let engine = try RedlampEngine()
        let dark = 100 * 400 + 60
        let plain = try render(EditRecipe(), session: session, engine: engine)
        let before = try render(recipe, session: session, engine: engine)
        recipe[.exposure] = 3
        var brightened = recipe
        brightened.masks = []
        let after = try render(recipe, session: session, engine: engine)
        let reference = try render(brightened, session: session, engine: engine)
        // Three stops up, the left half is no longer dark, so the mask stops lifting it.
        #expect(before[dark].y > plain[dark].y * 1.3)
        #expect(abs(after[dark].y - reference[dark].y) < 2e-3)
    }

    /// Hiding a mask hides it from the photo and from the overlay, even while it's selected.
    @Test func `a hidden mask shows neither its effect nor its overlay`() throws {
        let session = try makeSession(width: 200, height: 100) { _, _ in SIMD3(repeating: 0.18) }
        var hidden = MaskLayer(
            name: "Hidden", components: [MaskComponent(shape: .radial(RadialMask(
                center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.4, radiusY: 0.4,
            )))],
            isVisible: false,
        )
        hidden[.localExposure] = 2
        var recipe = EditRecipe()
        recipe.masks = [hidden]
        let shown = try render(recipe, session: session, overlay: hidden.id)
        let plain = try render(EditRecipe(), session: session)
        let worst = zip(shown, plain).map { simd_abs($0 - $1).max() }.max() ?? 1
        #expect(worst < 1e-4, "differs by \(worst)")
    }

    // MARK: - Refinements

    /// A layer reusing another's coverage covers the same area, even when that mask is hidden.
    @Test func `a mask reference covers what the referenced mask covers`() throws {
        let session = try makeSession(width: 400, height: 200) { _, _ in SIMD3(repeating: 0.18) }
        let left = MaskLayer(
            name: "Left", components: [MaskComponent(shape: .linear(LinearMask(
                start: ImagePoint(x: 0.3, y: 0.5), end: ImagePoint(x: 0.5, y: 0.5),
            )))],
            isVisible: false,
        )
        var reuse = MaskLayer(name: "Reuse", components: [
            MaskComponent(shape: .maskReference(MaskReference(maskID: left.id))),
        ])
        reuse[.localExposure] = 1
        var direct = left
        direct.isVisible = true
        direct[.localExposure] = 1
        var reused = EditRecipe()
        reused.masks = [left, reuse]
        var drawn = EditRecipe()
        drawn.masks = [direct]
        let a = try render(reused, session: session)
        let b = try render(drawn, session: session)
        let worst = zip(a, b).map { simd_abs($0 - $1).max() }.max() ?? 1
        #expect(worst < 1e-3)
        #expect(a[100 * 400 + 20].y > a[100 * 400 + 380].y * 1.3)
    }

    /// Detail above 0 keeps the mask to textured areas: a flat half and a striped half.
    @Test func `detail refinement keeps textured areas`() throws {
        let session = try makeSession(width: 512, height: 256) { x, y in
            x < 256 ? SIMD3(repeating: 0.18) : SIMD3(repeating: (x / 2 + y / 2) % 2 == 0 ? 0.05 : 0.4)
        }
        var mask = MaskLayer(name: "All", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.5, y: 0.5), radiusX: 5, radiusY: 5, feather: 0,
        )))])
        mask[.localExposure] = 1
        mask.detail = 60
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let plain = try render(EditRecipe(), session: session)
        let refined = try render(recipe, session: session)
        let flat = 128 * 512 + 100
        #expect(abs(refined[flat].y - plain[flat].y) < 2e-3)
        let texturedGain = (380 ..< 400).map { refined[128 * 512 + $0].y / max(plain[128 * 512 + $0].y, 1e-4) }
        #expect((texturedGain.max() ?? 0) > 1.3)
    }

    // MARK: - Bitmaps

    @Test func `bitmap mask covers where the bitmap is white`() throws {
        let session = try makeSession(width: 300, height: 200) { _, _ in SIMD3(repeating: 0.18) }
        let gray = GrayMask(width: 150, height: 100, pixels: (0 ..< 150 * 100).map { $0 % 150 < 75 ? 255 : 0 })
        let bitmap = try #require(gray.bitmap())
        #expect(try GrayMask.decode(#require(bitmap.png))?.pixels == gray.pixels)
        var mask = MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.25, y: 0.5),
            bitmap: bitmap,
        )))])
        mask[.localExposure] = 1
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let plain = try render(EditRecipe(), session: session)
        let masked = try render(recipe, session: session)
        #expect(masked[100 * 300 + 40].y > plain[100 * 300 + 40].y * 1.3)
        #expect(abs(masked[100 * 300 + 260].y - plain[100 * 300 + 260].y) < 1e-3)

        // Without its bytes (a sidecar missing the file) it covers nothing.
        mask.components[0].shape = .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.25, y: 0.5),
            bitmap: MaskBitmap(sha256: bitmap.sha256, width: 150, height: 100),
        ))
        recipe.masks = [mask]
        let missing = try render(recipe, session: session)
        #expect(abs(missing[100 * 300 + 40].y - plain[100 * 300 + 40].y) < 1e-3)
    }

    /// A depth map that is near on the left and far on the right: a near range selects the left.
    @Test func `depth range selects by depth`() throws {
        let session = try makeSession(width: 300, height: 200) { _, _ in SIMD3(repeating: 0.18) }
        let pixels: [UInt8] = (0 ..< 150 * 100).map { index in
            let column = index % 150
            return UInt8(255 - column * 255 / 149)
        }
        let depth = GrayMask(width: 150, height: 100, pixels: pixels)
        let map = try AIMask(
            kind: .depthRange, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: #require(depth.bitmap()),
        )
        var mask = MaskLayer(name: "Near", components: [
            MaskComponent(shape: .depthRange(DepthRangeMask(depth: map, lower: 70, upper: 100, lowerFeather: 5))),
        ])
        mask[.localExposure] = 1
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let plain = try render(EditRecipe(), session: session)
        let ranged = try render(recipe, session: session)
        #expect(ranged[100 * 300 + 20].y > plain[100 * 300 + 20].y * 1.3)
        #expect(abs(ranged[100 * 300 + 280].y - plain[100 * 300 + 280].y) < 1e-3)
    }

    // MARK: - AI masks

    /// On the sample photos, Vision's Subject mask is a bitmap of the analysis render's shape,
    /// and Background is its inverse. (A landscape may have no subject: that is an error.)
    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `subject and background masks from Vision`() async throws {
        let engine = try RedlampEngine()
        var found = 0
        for url in EngineSmokeTests.fixtures.prefix(4) {
            let info = try await engine.open(url)
            do {
                let subject = try #require(try await engine.computeMasks(MaskRequest(kind: .subject)).first)
                let background = try #require(try await engine.computeMasks(MaskRequest(kind: .background)).first)
                found += 1
                #expect(subject.kind == .subject && background.kind == .background)
                #expect(subject.analysisHash == background.analysisHash)
                #expect(subject.bitmap.width <= VisionMaskProvider.storedLongEdge)
                #expect(abs(Double(subject.bitmap.width) / Double(subject.bitmap.height) - info.pixelSize.aspectRatio) <
                    0.02)
                let subjectPNG = try #require(subject.bitmap.png)
                let backgroundPNG = try #require(background.bitmap.png)
                let a = try #require(GrayMask.decode(subjectPNG))
                let b = try #require(GrayMask.decode(backgroundPNG))
                #expect(abs(a.coveredFraction + b.coveredFraction - 1) < 0.05)
            } catch let error as MaskComputationError {
                #expect(error == .nothingFound(.subject))
            }
        }
        print("subject found in \(found) of \(min(4, EngineSmokeTests.fixtures.count)) sample photos")
    }

    /// With Segment Anything on this Mac: a click on the globe in the Nikon sample selects it
    /// (about a tenth of the frame), and the hover preview is quick once the photo is encoded.
    @Test(.enabled(if: EngineSmokeTests.canRender && Self.samIsInstalled))
    func `objects select what was clicked`() async throws {
        setenv("REDLAMP_EVALUATION_MODELS", "1", 1)
        let engine = try RedlampEngine()
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })
        _ = try await engine.open(url)
        #expect(engine.availableMaskKinds().contains(.objects))
        let globe = ImagePoint(x: 0.70, y: 0.62)
        let mask = try #require(try await engine.computeMasks(MaskRequest(kind: .objects, prompts: [globe])).first)
        let png = try #require(mask.bitmap.png)
        let gray = try #require(GrayMask.decode(png))
        #expect(gray.coveredFraction > 0.04 && gray.coveredFraction < 0.2, "covered \(gray.coveredFraction)")
        #expect(gray[Int(0.70 * Double(gray.width)), Int(0.62 * Double(gray.height))] > 200)
        #expect(gray[Int(0.1 * Double(gray.width)), Int(0.2 * Double(gray.height))] < 30)

        let clock = ContinuousClock()
        _ = try await engine.previewObjectMask(MaskRequest(kind: .objects, prompts: [globe]))
        let started = clock.now
        let preview = try await engine.previewObjectMask(MaskRequest(
            kind: .objects,
            prompts: [ImagePoint(x: 0.3, y: 0.5)],
        ))
        print("object preview: \(clock.now - started)")
        #expect(preview != nil)
    }

    // MARK: - Helpers

    private func raster(_ brush: BrushMask, resources: MaskResources) throws -> [Float] {
        let commands = try #require(queue.makeCommandBuffer())
        let component = MaskComponent(shape: .brush(brush))
        let slices = try resources.slices(for: [component], analysisGuide: nil, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
        let slice = try #require(slices[component.id])
        return try readSlice(#require(resources.rasters), slice: slice)
    }

    private func readSlice(_ texture: any MTLTexture, slice: Int) throws -> [Float] {
        let rowBytes = texture.width * 2
        let buffer = try #require(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: slice, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * texture.height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        return (0 ..< texture.width * texture.height).map { Float(halves[$0]) }
    }

    /// The whole photo at full size, as linear output.
    private func render(
        _ recipe: EditRecipe, session: ImageSession, engine: RedlampEngine? = nil, overlay: UUID? = nil,
    ) throws -> [SIMD3<Float>] {
        let engine = try engine ?? RedlampEngine()
        let size = session.orientedSize
        let frame = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: size, maskOverlay: overlay, generation: 0), session: session,
        )
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface)
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(size.width * size.height)
        for y in 0 ..< size.height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0 ..< size.width {
                pixels.append(SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2])))
            }
        }
        return pixels
    }

    /// A noiseless linear raw of `color(x, y)` in camera RGB (identity matrix).
    private func makeSession(
        width: Int, height: Int, color: (Int, Int) -> SIMD3<Float>,
    ) throws -> ImageSession {
        let black: Float = 512
        let white: Float = 16383
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let value = color(x, y)
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16((black + value[channel] * (white - black))
                        .rounded())
                }
            }
        }
        var decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples,
            blackLevels: [black, black, black], whiteLevel: white,
            asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic-mask.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = DetailStageTests.noise
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }
}

extension MaskRenderTests {
    /// With Depth Anything 3 on this Mac: on the Nikon sample the front of the table is nearer
    /// than the wall behind the objects.
    @Test(.enabled(if: EngineSmokeTests.canRender && Self.isInstalled("depth-anything-3-mono-large")))
    func `depth anything 3 gives depth`() async throws {
        setenv("REDLAMP_EVALUATION_MODELS", "1", 1)
        let engine = try RedlampEngine()
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })
        _ = try await engine.open(url)
        let mask = try #require(try await engine.computeMasks(MaskRequest(kind: .depthRange)).first)
        #expect(mask.provider == "redlamp.depth-anything-3-mono-large")
        let png = try #require(mask.bitmap.png)
        let depth = try #require(GrayMask.decode(png))
        let table = depth[depth.width / 2, depth.height * 95 / 100]
        let wall = depth[depth.width * 9 / 10, depth.height / 10]
        #expect(table > wall + 60, "table \(table), wall \(wall)")
    }

    /// Whether any version of the model is in the model store's directory.
    static func isInstalled(_ id: String) -> Bool {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Redlamp/Models/\(id)")
        return !((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty
    }

    static var samIsInstalled: Bool {
        isInstalled("sam2.1-tiny")
    }
}

/// The brush rasteriser on the CPU, from the same plan: per stroke the strongest dab weight,
/// composited by Flow up to Density, or erased.
enum BrushReference {
    static func raster(_ brush: BrushMask, size: PixelSize) -> [Float] {
        var coverage = [Float](repeating: 0, count: size.width * size.height)
        for stroke in brush.strokes {
            let plan = BrushRaster.plan(stroke, rasterSize: size)
            let points = plan.runs.flatMap(\.points)
            let radius = Float(max(plan.radius, 0.5))
            let inner = min(1 - Float(stroke.feather / 100), 0.999)
            for y in 0 ..< size.height {
                for x in 0 ..< size.width {
                    let q = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    var best: Float = 0
                    for i in 0 ..< max(points.count - 1, 1) {
                        let a = points[i]
                        let b = points.count > 1 ? points[i + 1] : a
                        let ab = SIMD2(b.x - a.x, b.y - a.y)
                        let t = min(max(simd_dot(q - SIMD2(a.x, a.y), ab) / max(simd_dot(ab, ab), 1e-6), 0), 1)
                        let d = simd_length(q - (SIMD2(a.x, a.y) + t * ab)) / radius
                        guard d < 1 else { continue }
                        let edge = d <= inner ? 1 : 1 - smoothstep(inner, 1, d)
                        best = max(best, edge * (a.z + (b.z - a.z) * t))
                    }
                    guard best > 0 else { continue }
                    let index = y * size.width + x
                    let flow = Float(stroke.flow / 100)
                    if stroke.erase {
                        coverage[index] *= 1 - flow * best
                    } else {
                        coverage[index] += max(Float(stroke.density / 100) - coverage[index], 0) * flow * best
                    }
                    coverage[index] = min(max(coverage[index], 0), 1)
                }
            }
        }
        return coverage
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
