import Foundation
import IOSurface
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Point Color in the develop kernel (TON-29): what a swatch selects, how uniformity pulls and pushes
/// the colours it selects, its shifts, and Visualize Range.
@Suite(.enabled(if: EngineSmokeTests.canRender))
struct PointColorRenderTests: PointColorRendering {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    @Test func `a swatch that changes nothing, or a mask's own colour on the edit, leaves the render alone`() throws {
        let session = try halves()
        let plain = try render(EditRecipe(), session: session)
        let shown = lch(plain[left])
        var recipe = EditRecipe()
        recipe.pointColor = [
            swatch(shown, [.pointColorHueRange: 90, .pointColorSmoothness: 10]),
            PointColorSwatch(color: .mask, values: [.pointColorHueUniformity: 100]),
        ]
        #expect(try render(recipe, session: session) == plain)
    }

    @Test func `hue uniformity pulls the colours a swatch selects to its hue, and leaves the others`() throws {
        let session = try halves()
        let plain = try render(EditRecipe(), session: session)
        let shown = lch(plain[left])
        let target = SIMD3(shown.x, shown.y, shown.z + 12)
        var recipe = EditRecipe()
        recipe.pointColor = [swatch(target, [.pointColorHueUniformity: 100])]
        let pulled = try render(recipe, session: session)
        #expect(abs(hueDifference(lch(pulled[left]).z, target.z)) < 0.5, "all the way: \(lch(pulled[left]))")
        #expect(simd_abs(pulled[right] - plain[right]).max() < 1e-3, "the blue isn't selected")

        recipe.pointColor = [swatch(target, [.pointColorHueUniformity: 50])]
        let half = try lch(render(recipe, session: session)[left]).z
        #expect(abs(hueDifference(half, shown.z + 6)) < 0.5, "half way: \(half)")
    }

    @Test func `saturation and luminance uniformity pull chroma and lightness too`() throws {
        let session = try halves()
        let shown = try lch(render(EditRecipe(), session: session)[left])
        // Less chroma than the photo's: more would be slowed by the gamut-relative boost (TON-07).
        let target = SIMD3(shown.x + 0.05, shown.y * 0.75, shown.z)
        var recipe = EditRecipe()
        recipe.pointColor = [
            swatch(target, [.pointColorSaturationUniformity: 100, .pointColorLuminanceUniformity: 100]),
        ]
        let pulled = try lch(render(recipe, session: session)[left])
        #expect(abs(pulled.y - target.y) < 0.01 * target.y, "chroma: \(pulled.y) against \(target.y)")
        #expect(abs(pulled.x - target.x) < 0.005, "lightness: \(pulled.x) against \(target.x)")
    }

    @Test func `pushing colours apart keeps them in order across the range's edge`() throws {
        // Hues 60° either side of the middle column's, so the ramp crosses the range's fading edge.
        let columns = 96
        let session = try makeSession(width: columns, height: 8) { x, _ in
            let hue = (40 + 120 * Double(x) / Double(columns - 1)) * .pi / 180
            let lab = SIMD3(0.6, 0.09 * cos(hue), 0.09 * sin(hue))
            return SIMD3<Float>(simd_max(Self.linearSRGB(oklab: lab), .zero) * 0.6)
        }
        let row = 4 * columns
        let plain = try render(EditRecipe(), session: session)
        let plainHues = (0 ..< columns).map { lch(plain[row + $0]).z }
        #expect(zip(plainHues, plainHues.dropFirst()).allSatisfy { $0 < $1 }, "the ramp's own hues rise")
        for smoothness in [0.0, 50, 100] {
            var recipe = EditRecipe()
            recipe.pointColor = [swatch(lch(plain[row + columns / 2]), [
                .pointColorHueUniformity: -100, .pointColorSmoothness: smoothness,
            ])]
            let pushed = try render(recipe, session: session)
            let hues = (0 ..< columns).map { lch(pushed[row + $0]).z }
            #expect(
                zip(hues, hues.dropFirst()).allSatisfy { $0 < $1 },
                "Smoothness \(smoothness): colours keep their order",
            )
            #expect(hues[columns / 2 + 8] - hues[columns / 2 - 8] > plainHues[columns / 2 + 8] -
                plainHues[columns / 2 - 8])
        }
    }

    @Test func `a shift turns the colours a swatch selects`() throws {
        let session = try halves()
        let plain = try render(EditRecipe(), session: session)
        let shown = lch(plain[left])
        var recipe = EditRecipe()
        recipe.pointColor = [swatch(shown, [.pointColorHueShift: 50])]
        let shifted = try render(recipe, session: session)
        #expect(abs(hueDifference(lch(shifted[left]).z, shown.z + 15)) < 0.5, "+15°: \(lch(shifted[left]))")
        #expect(simd_abs(shifted[right] - plain[right]).max() < 1e-3)
    }

    @Test func `visualizing the range shows what a swatch selects in colour and the rest in grey`() throws {
        let session = try halves()
        let plain = try render(EditRecipe(), session: session)
        var recipe = EditRecipe()
        let shown = swatch(lch(plain[left]))
        recipe.pointColor = [shown]
        let visualized = try render(recipe, session: session, visualize: shown.id)
        #expect(simd_abs(visualized[left] - plain[left]).max() < 1e-3, "selected: as it was")
        #expect(lch(visualized[right]).y < 0.005, "not selected: grey, \(lch(visualized[right]))")
        #expect(try render(recipe, session: session) == plain, "without Visualize Range, a neutral swatch is no swatch")
    }

    @Test func `the eyedropper reads what Point Color receives, global edits and masks included`() throws {
        let session = try halves()
        let engine = try RedlampEngine()
        let shown = try lch(render(EditRecipe(), session: session)[left])
        let spot = CGPoint(x: 0.25, y: 0.5)
        let plain = try engine.samplePointColorInput(at: spot, radius: 0, recipe: EditRecipe(), session: session)
        #expect(abs(plain.lightness - shown.x) < 0.003, "lightness \(plain.lightness) against \(shown.x)")
        #expect(abs(plain.chroma - shown.y) < 0.003, "chroma \(plain.chroma) against \(shown.y)")
        #expect(abs(hueDifference(plain.hue, shown.z)) < 1, "hue \(plain.hue) against \(shown.z)")

        var saturated = EditRecipe()
        saturated[.saturation] = 40
        let more = try engine.samplePointColorInput(at: spot, radius: 0, recipe: saturated, session: session)
        #expect(more.chroma > plain.chroma + 0.01, "Saturation comes before Point Color")

        var masked = EditRecipe()
        var mask = MaskLayer(name: "Left", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.25, y: 0.5), radiusX: 0.2, radiusY: 0.9, feather: 0,
        )))])
        mask[.localExposure] = 1
        masked.masks = [mask]
        let brighter = try engine.samplePointColorInput(at: spot, radius: 0.1, recipe: masked, session: session)
        #expect(brighter.lightness > plain.lightness + 0.03, "a mask's Exposure comes before it too")
        let wide = try engine.samplePointColorInput(at: spot, radius: 0.1, recipe: EditRecipe(), session: session)
        #expect(abs(wide.chroma - plain.chroma) < 0.003, "a wider disc of one colour averages to it")
    }

    @Test func `on a turned, cropped, straightened and transformed photo the eyedropper reads what's clicked`() throws {
        let size = PixelSize(width: 160, height: 120)
        let session = try makeSession(width: size.width, height: size.height) { x, y in
            SIMD3(0.05 + 0.6 * Float(x) / Float(size.width), 0.05 + 0.6 * Float(y) / Float(size.height), 0.2)
        }
        let engine = try RedlampEngine()
        var reframed = EditRecipe()
        reframed.orientation = ImageOrientation(quarterTurns: 1)
        reframed.crop = CropRect(left: 0.15, top: 0.1, right: 0.8, bottom: 0.85)
        reframed[.cropAngle] = 6
        reframed[.transformVertical] = 15
        reframed[.transformRotate] = 3
        let map = GeometryMap(recipe: reframed, imageSize: size, lens: nil)
        for click in [SIMD2(0.25, 0.3), SIMD2(0.7, 0.6), SIMD2(0.5, 0.85)] {
            let photo = try #require(map.imagePoint(click))
            let point = CGPoint(x: photo.x, y: photo.y)
            let picked = try engine.samplePointColorInput(at: point, radius: 0, recipe: reframed, session: session)
            let plain = try engine.samplePointColorInput(at: point, radius: 0, recipe: EditRecipe(), session: session)
            let difference = simd_abs(picked.clippedLinearSRGB - plain.clippedLinearSRGB).max()
            #expect(difference < 0.005, "click \(click): \(picked) against \(plain)")
        }
    }
}

/// Point Color's sliders in the kernel's units.
struct PointColorMathTests {
    private let skin = OKLCh(lightness: 0.6, chroma: 0.08, hue: 50)

    @Test func `at the defaults a swatch selects hue within 47.5°, fully within about 21°`() {
        let swatch = PointColorSwatch(color: .oklch(skin))
        let widths = PointColorMath.halfWidths(swatch)
        #expect(abs(widths.x - 47.5) < 1e-9)
        #expect(abs(widths.x * (1 - PointColorMath.fade(swatch)) - 21.4) < 0.1)
    }

    @Test func `the push limit keeps the mapping's slope above its floor at every Smoothness`() throws {
        for smoothness in stride(from: 0.0, through: 100, by: 10) {
            let swatch = PointColorSwatch(color: .oklch(skin), values: [.pointColorSmoothness: smoothness])
            let fade = PointColorMath.fade(swatch)
            let limit = PointColorMath.pushLimit(fade: fade)
            func weight(_ x: Double) -> Double {
                let t = min(max((x - (1 - fade)) / fade, 0), 1)
                return 1 - t * t * (3 - 2 * t)
            }
            let mapped = (0 ... 1200).map { step -> Double in
                let x = Double(step) / 1000
                return x * (1 + limit * weight(x))
            }
            let slopes = zip(mapped, mapped.dropFirst()).map { ($1 - $0) * 1000 }
            #expect(try #require(slopes.min()) >= 0.249, "Smoothness \(smoothness): slope \(slopes.min()!)")
        }
        #expect(PointColorMath.pushLimit(fade: 0.1) < PointColorMath.pushLimit(fade: 1), "smoother edges push further")
    }

    @Test func `the kernel runs swatches that change something, and the one Visualize Range shows`() {
        let neutral = PointColorSwatch(color: .oklch(skin))
        let pulling = PointColorSwatch(color: .oklch(skin), values: [.pointColorHueUniformity: 40])
        let typical = PointColorSwatch(color: .mask, values: [.pointColorHueUniformity: 40])
        var recipe = EditRecipe()
        recipe.pointColor = [neutral, typical]
        let none = PointColorMath.buffers(recipe, visualized: nil)
        #expect(none.swatches.isEmpty && none.visualized == 0 && none.measured.isEmpty)
        recipe.pointColor = [pulling, neutral, typical]
        let shown = PointColorMath.buffers(recipe, visualized: neutral.id)
        #expect(shown.swatches.count == 2 && shown.visualized == 2)
        #expect(shown.swatches[0].uniformity.x == 0.4)
        let pushing = PointColorSwatch(color: .oklch(skin), values: [.pointColorHueUniformity: -100])
        let limit = PointColorMath.pushLimit(fade: PointColorMath.fade(pushing))
        #expect(PointColorMath.gpu(pushing)?.uniformity.x == Float(-limit))
    }

    @Test func `masks' swatches follow the edit's, each with its mask's place and Amount`() {
        let pulling = PointColorSwatch(color: .oklch(skin), values: [.pointColorHueUniformity: 40])
        let own = PointColorSwatch(color: .mask, values: [.pointColorHueShift: 50])
        var hidden = MaskLayer(name: "Hidden", components: [])
        hidden.isVisible = false
        hidden.pointColor = [pulling]
        var face = MaskLayer(name: "Face", components: [])
        face.amount = 50
        face.pointColor = [pulling, own]
        var recipe = EditRecipe()
        recipe.pointColor = [pulling]
        recipe.masks = [hidden, face]

        let packed = PointColorMath.buffers(recipe, visualized: nil)
        #expect(packed.swatches.map(\.color.w) == [0, 1, 1], "the edit's, then the visible mask's, as layer 0")
        #expect(packed.swatches[1].uniformity.x == 0.2, "half the pull at Amount 50")
        #expect(packed.swatches[2].shift.x == 7.5 && packed.swatches[2].uniformity.w == 1)
        #expect(packed.measured == [0], "the mask's own colour is measured for its layer")
    }
}
