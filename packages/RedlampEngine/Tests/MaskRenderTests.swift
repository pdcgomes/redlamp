import CoreGraphics
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

    @Test func `the overlay's opacity sets how strongly it tints the mask`() throws {
        let session = try makeSession(width: 200, height: 100) { _, _ in SIMD3(repeating: 0.18) }
        let mask = MaskLayer(name: "Centre", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.3, feather: 0,
        )))])
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let centre = 50 * 200 + 100
        let plain = try render(recipe, session: session)[centre]
        let tints = try [0, 0.55, 1].map { try render(recipe, session: session, overlay: mask.id, opacity: $0)[centre] }
        #expect(simd_abs(tints[0] - plain).max() < 1e-3, "no tint at 0%")
        #expect(tints[0].x < tints[1].x && tints[1].x < tints[2].x && tints[2].y < tints[1].y)
        #expect(tints[2].x > 10 * tints[2].y, "the overlay's red at 100%")
        let fallback = try render(recipe, session: session, overlay: mask.id)[centre]
        #expect(simd_abs(fallback - tints[1]).max() < 1e-4, "55% until it's changed")
    }

    @Test func `a mask's Color swatch tints what it covers, and no swatch leaves the photo as it was`() throws {
        let session = try makeSession(width: 200, height: 100) { _, _ in SIMD3(repeating: 0.18) }
        var mask = MaskLayer(name: "Centre", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.3, feather: 0,
        )))])
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let plain = try render(EditRecipe(), session: session)
        let none = try render(recipe, session: session)
        #expect(zip(none, plain).allSatisfy { $0 == $1 }, "a mask with no adjustment changes nothing")

        mask[.localColorHue] = 220
        mask[.localColorSaturation] = 100
        recipe.masks = [mask]
        let tinted = try render(recipe, session: session)
        let (centre, corner) = (50 * 200 + 100, 5 * 200 + 5)
        #expect(tinted[centre].z > tinted[centre].x + 0.02, "blue where the mask covers: \(tinted[centre])")
        #expect(simd_abs(tinted[corner] - plain[corner]).max() < 1e-4, "nothing outside it")
        mask.amount = 50
        recipe.masks = [mask]
        let half = try render(recipe, session: session)[centre]
        #expect(half.z - half.x < tinted[centre].z - tinted[centre].x, "Amount scales the tint")
    }

    @Test func `a mask's Curves change what it covers, channel by channel`() throws {
        let session = try makeSession(width: 200, height: 100) { _, _ in SIMD3(repeating: 0.18) }
        var mask = MaskLayer(name: "Centre", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.3, feather: 0,
        )))])
        let (centre, corner) = (50 * 200 + 100, 5 * 200 + 5)
        let plain = try render(EditRecipe(), session: session)
        var recipe = EditRecipe()

        var curves = MaskCurves()
        curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.3), CurvePoint(x: 1, y: 1)]
        mask.curves = curves
        recipe.masks = [mask]
        let darker = try render(recipe, session: session)
        #expect(darker[centre].x < plain[centre].x * 0.8 && darker[centre].z < plain[centre].z * 0.8)
        #expect(simd_abs(darker[corner] - plain[corner]).max() < 1e-4, "nothing outside the mask")

        curves = MaskCurves()
        curves.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]
        mask.curves = curves
        recipe.masks = [mask]
        let redder = try render(recipe, session: session)[centre]
        let lift = redder - plain[centre]
        #expect(lift.x > 0.02, "red lifted: \(redder)")
        // The curve lifts red in the working space; the output's primaries mix a little of that in.
        #expect(abs(lift.y) < 0.2 * lift.x && abs(lift.z) < 0.2 * lift.x, "mostly red: \(lift)")

        mask.curves = MaskCurves()
        #expect(mask.curves == nil, "straight curves are no Curves")
    }

    @Test func `Image on B&W shows the mask in colour and the rest in grey`() throws {
        let session = try makeSession(width: 200, height: 100) { _, _ in SIMD3(0.4, 0.2, 0.1) }
        let mask = MaskLayer(name: "Centre", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.3, feather: 0,
        )))])
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let (centre, corner) = (50 * 200 + 100, 5 * 200 + 5)
        let plain = try render(recipe, session: session)
        let shown = try render(recipe, session: session, overlay: mask.id, style: .imageOnBlackAndWhite)
        #expect(simd_abs(shown[centre] - plain[centre]).max() < 1e-3, "the mask as it is")
        #expect(shown[corner].max() - shown[corner].min() < 1e-3, "grey outside: \(shown[corner])")
        #expect(plain[corner].x - plain[corner].z > 0.05, "the photo outside is coloured")
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

    /// A sharp edge in the photo under an AI mask of its bright side at half the analysis grid's
    /// resolution, as Vision's masks are on large photos: drawn at full size, process 12 ramps
    /// over the mask's pixels upsampled eightfold, and process 13 steps at the photo's edge
    /// (MSK-07). The B&W overlay shows the coverage.
    @Test func `from process 13, an AI mask's edge follows the photo's at full size`() throws {
        let (width, height) = (4096, 128)
        let session = try makeSession(width: width, height: height) { x, _ in SIMD3(repeating: x < 2048 ? 0.05 : 0.4) }
        let gray = GrayMask(width: 512, height: 16, pixels: (0 ..< 512 * 16).map { $0 % 512 < 256 ? 0 : 255 })
        let mask = try MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.75, y: 0.5),
            bitmap: #require(gray.bitmap()),
        )))])
        var recipe = EditRecipe()
        recipe.masks = [mask]
        /// Pixels of the row between 20% and 80% coverage (sRGB-encoded grey, shown linear).
        func ramp(_ version: Int) throws -> Int {
            recipe.processVersion = version
            let shown = try render(recipe, session: session, overlay: mask.id, style: .blackAndWhite)
            let row = height / 2 * width
            return (1900 ..< 2200).filter { shown[row + $0].y > 0.033 && shown[row + $0].y < 0.604 }.count
        }
        let (before, after) = try (ramp(12), ramp(13))
        #expect(before >= 4, "process 12 ramps over \(before) px")
        #expect(after <= 2, "process 13 steps within \(after) px")
    }

    /// A mask solved per pixel is stored at the photo's size (up to 4096 px), and from process 13 it's
    /// drawn as it is, as in process 12: fitted to the photo's luminance on the coarser analysis grid,
    /// its fine structure would be lost (MSK-26). Here its soft edge lies away from the photo's.
    @Test func `from process 13, a mask at the size masks are stored at is drawn as it is`() throws {
        let (width, height) = (4096, 128)
        let session = try makeSession(width: width, height: height) { x, _ in SIMD3(repeating: x < 2048 ? 0.05 : 0.4) }
        let gray = GrayMask(width: width, height: height, pixels: (0 ..< width * height).map { index in
            UInt8((min(max(Double(index % width - 1700) / 200, 0), 1) * 255).rounded())
        })
        let mask = try MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.75, y: 0.5),
            bitmap: #require(gray.bitmap()),
        )))])
        var recipe = EditRecipe()
        recipe.masks = [mask]
        recipe.processVersion = 12
        let before = try render(recipe, session: session, overlay: mask.id, style: .blackAndWhite)
        recipe.processVersion = 13
        let after = try render(recipe, session: session, overlay: mask.id, style: .blackAndWhite)
        let row = height / 2 * width
        let worst = (1600 ..< 2200).map { abs(after[row + $0].y - before[row + $0].y) }.max() ?? 1
        #expect(worst < 1e-3, "process 13 moves the mask by \(worst)")
        #expect(
            after[row + 1800].y > 0.15 && after[row + 1800].y < 0.3,
            "half covered mid-ramp: \(after[row + 1800].y)",
        )
    }

    /// From process 13 a mask's Whites and Blacks are end points, as the global sliders are: under
    /// full coverage they render as the same global values, and add to them (MSK-24).
    @Test func `from process 13, a mask's Whites and Blacks move the end points as the global sliders do`() throws {
        let session = try makeSession(width: 256, height: 16) { x, _ in
            SIMD3(repeating: Float(pow(2, Double(x) / 256 * 10 - 10)))
        }
        let everywhere = GrayMask(width: 16, height: 1, pixels: [UInt8](repeating: 255, count: 16))
        func masked(whites: Double, blacks: Double) throws -> MaskLayer {
            var mask = try MaskLayer(name: "All", components: [MaskComponent(shape: .ai(AIMask(
                kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
                bitmap: #require(everywhere.bitmap()),
            )))])
            mask[.localWhites] = whites
            mask[.localBlacks] = blacks
            return mask
        }
        func difference(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
            zip(a, b).map { simd_abs($0 - $1).max() }.max() ?? 1
        }
        var global = EditRecipe()
        global[.whites] = 40
        global[.blacks] = -30
        var local = EditRecipe()
        local.masks = try [masked(whites: 40, blacks: -30)]
        var both = EditRecipe()
        both[.blacks] = 20
        both.masks = try [masked(whites: 40, blacks: -50)]
        let reference = try render(global, session: session)
        #expect(try difference(render(local, session: session), reference) < 2e-3)
        #expect(try difference(render(both, session: session), reference) < 2e-3, "local Blacks add to global")

        local.processVersion = 12
        global.processVersion = 12
        #expect(try difference(render(local, session: session), render(global, session: session)) > 0.01)
    }

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

    /// What `redlamp render --coverage` measures: a still with its mask in the B&W overlay is the
    /// mask's coverage, drawn at the size asked for rather than downscaled from full size.
    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `a still in the B&W overlay is its mask's coverage`() async throws {
        let engine = try RedlampEngine()
        let url = try #require(EngineSmokeTests.fixtures.first)
        _ = try await engine.open(url)
        let mask = MaskLayer(name: "Centre", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2, feather: 0,
        )))])
        var recipe = EditRecipe()
        recipe.masks = [mask]
        var request = StillRequest(recipe: recipe, maxLongEdge: 300, purpose: .export)
        request.maskOverlay = mask.id
        request.maskOverlayStyle = .blackAndWhite
        let image = try await engine.renderStill(request)
        #expect(max(image.width, image.height) == 300)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let centre = bytes[(image.height / 2 * image.width + image.width / 2) * 4]
        let corner = bytes[(5 * image.width + 5) * 4]
        #expect(centre > 250 && corner < 5, "centre \(centre), corner \(corner)")
    }

    // MARK: - Quality gate (MSK-25)

    /// Sky coverage of a frame crossed by twelve dark branches 0.5 to 3 px wide, exact to 1/16.
    private func branchCoverage(width: Int, height: Int) -> [Float] {
        let lines: [(SIMD2<Float>, SIMD2<Float>, Float)] = (0 ..< 12).map { i in
            let t = Float(i) / 12
            let start = SIMD2<Float>(Float(width) * (0.05 + 0.9 * t), 0)
            let end = SIMD2<Float>(Float(width) * (0.5 + 0.45 * sin(7 * t)), Float(height))
            return (start, end, 0.5 + 2.5 * Float(i % 6) / 5)
        }
        return (0 ..< width * height).map { index in
            var branch = 0
            for sy in 0 ..< 4 {
                for sx in 0 ..< 4 {
                    let p = SIMD2<Float>(
                        Float(index % width) + (Float(sx) + 0.5) / 4,
                        Float(index / width) + (Float(sy) + 0.5) / 4,
                    )
                    let hit = lines.contains { start, end, width in
                        let axis = end - start
                        let t = simd_clamp(simd_dot(p - start, axis) / simd_length_squared(axis), 0, 1)
                        return simd_length(p - (start + t * axis)) < width / 2
                    }
                    branch += hit ? 1 : 0
                }
            }
            return 1 - Float(branch) / 16
        }
    }

    private func lightness(_ colour: SIMD3<Float>) -> Float {
        let y = simd_dot(colour, SIMD3(0.2126, 0.7152, 0.0722))
        return y > 0.008856 ? 116 * cbrt(y) - 16 : 903.3 * y
    }

    /// How far an exposure edit through a mask of known coverage lands from the scene edited before
    /// it was composited, in L*: averaged over the pixels mostly outside the mask (signed: positive
    /// is lighter than it should be) and, unsigned, over the pixels wholly inside it.
    private func edgeError(
        coverage: [Float], width: Int, height: Int, kind: MaskKind, exposure: Double,
        inside: (Int) -> SIMD3<Float>, outside: SIMD3<Float>,
    ) throws -> (rim: Float, deep: Float) {
        let gain = Float(pow(2, exposure))
        let scene = try makeSession(width: width, height: height) { x, y in
            coverage[y * width + x] * inside(y) + (1 - coverage[y * width + x]) * outside
        }
        let ideal = try makeSession(width: width, height: height) { x, y in
            coverage[y * width + x] * inside(y) * gain + (1 - coverage[y * width + x]) * outside
        }
        var mask = try MaskLayer(name: "Gate", components: [MaskComponent(shape: .ai(AIMask(
            kind: kind, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: #require(GrayMask(width: width, height: height, coverage: coverage).bitmap()),
        )))])
        mask[.localExposure] = exposure
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let difference = try zip(render(recipe, session: scene), render(EditRecipe(), session: ideal))
            .map { lightness($0) - lightness($1) }
        let deep = coverage.indices.filter { coverage[$0] == 1 }
        let rim = coverage.indices.filter { coverage[$0] > 0.05 && coverage[$0] < 0.5 }
        return (
            rim.map { difference[$0] }.reduce(0, +) / Float(rim.count),
            deep.map { abs(difference[$0]) }.reduce(0, +) / Float(deep.count),
        )
    }

    /// Darkening a sky by 1.5 EV through its true coverage should look like the scene with its sky
    /// darkened before compositing. A pixel part sky and part branch is darkened by too little, so
    /// branches come out lighter than they should: the gate holds that rim where it is until edits
    /// are applied to the pure colour behind a mixed pixel (MSK-27).
    @Test func `a sky darkened through its true coverage keeps the rim along its branches within the gate`() throws {
        let (width, height) = (512, 256)
        let error = try edgeError(
            coverage: branchCoverage(width: width, height: height), width: width, height: height, kind: .sky,
            exposure: -1.5, inside: { SIMD3(0.45, 0.55, 0.75) * (0.9 + 0.2 * Float($0) / Float(height)) },
            outside: SIMD3(0.03, 0.025, 0.02),
        )
        #expect(error.deep < 0.5, "deep in the sky, the edit misses the ideal by \(error.deep) L*")
        #expect(error.rim < 14.5, "branches come out \(error.rim) L* lighter than they should")
    }

    /// Brightening dark strands by 1 EV through their true coverage brightens the light background
    /// mixed into their edges with them, so a glow follows the strands just outside them (MSK-27).
    @Test func `strands brightened through their true coverage keep the glow beside them within the gate`() throws {
        let (width, height) = (512, 256)
        let error = try edgeError(
            coverage: branchCoverage(width: width, height: height).map { 1 - $0 }, width: width, height: height,
            kind: .subject, exposure: 1, inside: { _ in SIMD3(0.06, 0.045, 0.035) },
            outside: SIMD3(0.55, 0.52, 0.48),
        )
        #expect(error.deep < 0.5, "inside the strands, the edit misses the ideal by \(error.deep) L*")
        #expect(error.rim < 3.5, "the background beside the strands comes out \(error.rim) L* lighter")
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
                // Solved per pixel at the size masks are stored at, not Vision's.
                #expect(max(subject.bitmap.width, subject.bitmap.height) <= MaskResources.rasterLongEdge)
                #expect(subject.provider.hasSuffix("+closed-form"))
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
        style: MaskOverlayStyle = .colorOverlay, opacity: Double = MaskOverlayStyle.defaultOpacity,
    ) throws -> [SIMD3<Float>] {
        let engine = try engine ?? RedlampEngine()
        let size = session.orientedSize
        var request = RenderRequest(recipe: recipe, targetSize: size, maskOverlay: overlay, generation: 0)
        request.maskOverlayStyle = style
        request.maskOverlayOpacity = opacity
        let frame = try engine.renderFrame(request, session: session)
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
    /// Opening the Masking tool gets the open photo's mask renders ready in the background, and
    /// those of the photo opened next.
    @Test(.enabled(if: EngineSmokeTests.canRender && EngineSmokeTests.fixtures.count >= 2))
    func `warming up prepares the mask renders, for the next photo too`() async throws {
        let engine = try RedlampEngine()
        func ready(within seconds: Double) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                if let session = engine.currentSession(),
                   engine.matteCache.withLock({ $0?.session === session }),
                   engine.analysisCache.withLock({ $0?.session === session }) {
                    return true
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        _ = try await engine.open(EngineSmokeTests.fixtures[0])
        #expect(try await !ready(within: 1.5), "nothing is warmed before the Masking tool opens")
        engine.warmUpMasks()
        #expect(try await ready(within: 30))
        _ = try await engine.open(EngineSmokeTests.fixtures[1])
        #expect(try await ready(within: 30), "the next photo")
    }

    /// With SAM 3 on this Mac: the Sony sample's trees are vegetation, named for the class, and
    /// its edges solved per pixel.
    @Test(.enabled(if: EngineSmokeTests.canRender && Self.isInstalled("sam3")))
    func `landscape finds the trees`() async throws {
        setenv("REDLAMP_EVALUATION_MODELS", "1", 1)
        let engine = try RedlampEngine()
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "_DSC0009.ARW" })
        _ = try await engine.open(url)
        let mask = try #require(try await engine.computeMasks(MaskRequest(kind: .landscape, landscape: .vegetation))
            .first)
        #expect(mask.part == LandscapeClass.vegetation.rawValue)
        #expect(mask.provider == "redlamp.sam3+closed-form")
        let png = try #require(mask.bitmap.png)
        let vegetation = try #require(GrayMask.decode(png))
        #expect(vegetation.coveredFraction > 0.05, "vegetation covers \(vegetation.coveredFraction)")
    }

    /// With SAM 3 on this Mac: People offers hair, facial hair, body skin and clothes on any photo.
    /// None of the samples has a person, but Vision takes the Canon's pig statues for people, one
    /// with a tuft SAM 3 calls hair; the Sony landscape has no clothes.
    @Test(.enabled(if: EngineSmokeTests.canRender && Self.isInstalled("sam3")))
    func `people parts come from SAM 3`() async throws {
        setenv("REDLAMP_EVALUATION_MODELS", "1", 1)
        let engine = try RedlampEngine()
        #expect(engine.availablePersonParts().isSuperset(of: [.hair, .facialHair, .bodySkin, .clothes]))
        let canon = try #require(EngineSmokeTests.fixtures.first { $0.pathExtension == "CR3" })
        _ = try await engine.open(canon)
        let hair = try #require(try await engine.computeMasks(MaskRequest(kind: .people, part: .hair)).first)
        #expect(hair.part == PersonPart.hair.rawValue)
        // Its edge with the background is the statue's own matte.
        #expect(hair.provider == "redlamp.sam3+closed-form")
        #expect(hair.instance != nil)

        let sony = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "_DSC0009.ARW" })
        _ = try await engine.open(sony)
        await #expect(throws: MaskComputationError.notFound(PersonPart.clothes)) {
            try await engine.computeMasks(MaskRequest(kind: .people, part: .clothes))
        }
    }

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
