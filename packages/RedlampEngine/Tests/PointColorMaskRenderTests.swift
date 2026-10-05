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

/// Point Color in masks (TON-29): a mask's swatches act where the mask covers, and a swatch can take
/// the mask's own colour, the median under it.
@Suite(.enabled(if: EngineSmokeTests.canRender))
struct PointColorMaskRenderTests: PointColorRendering {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// A mask over the left half's middle, x from 0.05 to 0.45 of the width: a radial's radii are in
    /// units of the height, and the frames here are four times as wide as they are high.
    private func leftMask(_ swatches: [PointColorSwatch]) -> MaskLayer {
        var mask = MaskLayer(name: "Left", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.25, y: 0.5), radiusX: 0.8, radiusY: 0.9, feather: 0,
        )))])
        mask.pointColor = swatches
        return mask
    }

    @Test func `a mask's swatch acts only where its mask covers`() throws {
        let session = try halves()
        let plain = try render(EditRecipe(), session: session)
        let outside = 20 * 160 + 78
        let shown = lch(plain[left])
        var recipe = EditRecipe()
        recipe.masks = [leftMask([swatch(shown, [.pointColorHueShift: 50])])]
        let shifted = try render(recipe, session: session)
        #expect(abs(hueDifference(lch(shifted[left]).z, shown.z + 15)) < 0.5, "under the mask: \(lch(shifted[left]))")
        #expect(simd_abs(shifted[outside] - plain[outside]).max() < 1e-3, "the same colour outside it")
        #expect(simd_abs(shifted[right] - plain[right]).max() < 1e-3)
    }

    @Test func `a mask's own colour is the median of what Point Color receives under it`() throws {
        let session = try halves()
        let engine = try RedlampEngine()
        let shown = try lch(render(EditRecipe(), session: session)[left])
        var recipe = EditRecipe()
        recipe.masks = [leftMask([PointColorSwatch(color: .mask, values: [.pointColorHueUniformity: 50])])]
        let commands = try #require(queue.makeCommandBuffer())
        let colors = try #require(try engine.encodeMaskPointColors(
            [0], recipe: recipe, session: session, commands: commands, retouchMaps: .current,
        ))
        let shared = try #require(device.makeBuffer(length: colors.length, options: .storageModeShared))
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(from: colors, sourceOffset: 0, to: shared, destinationOffset: 0, size: colors.length)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let measured = shared.contents().assumingMemoryBound(to: SIMD4<Float>.self)[0]
        #expect(measured.w > 0, "something is under the mask: \(measured)")
        #expect(abs(Double(measured.x) - shown.x) < 0.01, "lightness \(measured.x) against \(shown.x)")
        #expect(abs(Double(measured.y) - shown.y) < 0.01, "chroma \(measured.y) against \(shown.y)")
        #expect(abs(hueDifference(Double(measured.z), shown.z)) < 1, "hue \(measured.z) against \(shown.z)")
    }

    @Test func `a swatch of the mask's own colour pulls what it covers to the median under it`() throws {
        // Hues from 30° to 70° across the left half, a blue on the right.
        let session = try makeSession(width: 160, height: 40) { x, _ in
            guard x < 80 else { return Self.blue }
            let hue = (30 + 40 * Double(x) / 79) * .pi / 180
            let lab = SIMD3(0.62, 0.08 * cos(hue), 0.08 * sin(hue))
            return SIMD3<Float>(simd_max(Self.linearSRGB(oklab: lab), .zero) * 0.6)
        }
        let plain = try render(EditRecipe(), session: session)
        let covered = [20, 30, 40, 50, 60].map { 20 * 160 + $0 }
        let plainHues = covered.map { lch(plain[$0]).z }
        #expect(try #require(plainHues.last) - plainHues.first! > 10, "the ramp spreads: \(plainHues)")

        var recipe = EditRecipe()
        recipe.masks = [leftMask([PointColorSwatch(color: .mask, values: [
            .pointColorHueUniformity: 100, .pointColorHueRange: 100, .pointColorSmoothness: 0,
        ])])]
        let pulled = try render(recipe, session: session)
        let hues = covered.map { lch(pulled[$0]).z }
        #expect(try #require(hues.max()) - hues.min()! < 1, "one hue under the mask: \(hues)")
        #expect(abs(hueDifference(hues[2], plainHues[2])) < 2, "the middle of the ramp, its median: \(hues[2])")
        let outside = 20 * 160 + 78
        #expect(simd_abs(pulled[outside] - plain[outside]).max() < 1e-3, "outside the mask, as it was")

        // An edit before Point Color moves the colours, and the median with them.
        recipe[ColorBand.orange.hueParameter] = 60
        let turned = try render(recipe, session: session)
        let turnedHues = covered.map { lch(turned[$0]).z }
        #expect(try #require(turnedHues.max()) - turnedHues.min()! < 1, "still one hue: \(turnedHues)")
        #expect(abs(hueDifference(turnedHues[2], hues[2])) > 2, "a different one: \(turnedHues[2]) against \(hues[2])")
    }
}
