import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Remove Chromatic Aberration and Defringe (LNS-09).
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct ChromaticAberrationTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    func session(width: Int, height: Int, color: (Double, Double) -> SIMD3<Double>) throws -> ImageSession {
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let value = color(Double(x) + 0.5, Double(y) + 0.5)
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16(min(max(value[channel], 0), 1) * 65535)
                }
            }
        }
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/ca.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    /// Red's and blue's recorded scale at radius r (half-diagonals).
    static func red(_ r: Double) -> Double {
        1 + 0.0015 + 0.001 * r * r
    }

    static func blue(_: Double) -> Double {
        1 - 0.001
    }

    /// Soft-edged rings around the centre, their edges across the radius, with red and blue
    /// recorded at their own scale: a lens's lateral chromatic aberration.
    func rings(_ width: Int, _ height: Int, fringes: Bool) throws -> ImageSession {
        let centre = SIMD2(Double(width), Double(height)) / 2
        let reach = simd_length(centre)
        func ring(_ radius: Double) -> Double {
            0.12 + 0.5 * (0.5 + 0.5 * tanh(3 * sin(radius / 9)))
        }
        return try session(width: width, height: height) { x, y in
            let d = simd_length(SIMD2(x, y) - centre)
            let r = d / reach
            guard fringes else { return SIMD3(repeating: ring(d)) }
            return SIMD3(ring(d / Self.red(r)), ring(d), ring(d / Self.blue(r)))
        }
    }

    @Test func `the fringes' scale is measured from the photo's edges`() throws {
        let measured = try #require(LateralChromaticAberration.estimate(rings(2048, 1536, fringes: true)))
        #expect(measured.source == .measured && measured.correctsColorFringes)
        for r in [0.3, 0.6, 0.9] {
            let scale = measured.interpolate(measured.distortion, at: r)
            #expect(abs(scale.x - Self.red(r)) < 3e-4, "red at \(r): \(scale.x) vs \(Self.red(r))")
            #expect(abs(scale.z - Self.blue(r)) < 3e-4, "blue at \(r): \(scale.z) vs \(Self.blue(r))")
        }
        #expect(try LateralChromaticAberration.estimate(rings(2048, 1536, fringes: false)) == nil)
    }

    @Test func `Remove Chromatic Aberration realigns red and blue with green`() throws {
        let session = try rings(1536, 1024, fringes: true)
        func misalignment(_ recipe: EditRecipe) throws -> Double {
            let size = session.orientedSize
            let frame = try RedlampEngine().renderFrame(
                RenderRequest(recipe: recipe, targetSize: size, generation: 0), session: session,
            )
            let surface = frame.surface
            IOSurfaceLock(surface, .readOnly, nil)
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            let rowBytes = IOSurfaceGetBytesPerRow(surface)
            var total = 0.0
            // The outer frame, where the fringes are widest.
            for y in stride(from: 8, to: size.height - 8, by: 2) {
                let row = (IOSurfaceGetBaseAddress(surface) + y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in stride(from: 8, to: size.width / 6, by: 2) {
                    let (r, g, b) = (Double(row[x * 4]), Double(row[x * 4 + 1]), Double(row[x * 4 + 2]))
                    total += abs(r - g) + abs(b - g)
                }
            }
            return total
        }
        var on = EditRecipe()
        on[.lensRemoveChromaticAberration] = 1
        let before = try misalignment(EditRecipe()), after = try misalignment(on)
        #expect(after < before * 0.3, "fringes \(before) → \(after)")
    }

    @Test func `Defringe greys purple beside an edge and leaves purple elsewhere`() throws {
        let (width, height) = (512, 256)
        // A bright window in the left half, a purple fringe hugging its edge, and a purple patch
        // far from any edge on the right.
        let session = try session(width: width, height: height) { x, y in
            let purple = SIMD3(0.30, 0.08, 0.36)
            if x > 360, x < 460, y > 80, y < 180 {
                return purple
            }
            if x < 120 {
                return SIMD3(repeating: 0.95)
            }
            return x < 124 ? purple : SIMD3(repeating: 0.03)
        }
        func pixel(_ recipe: EditRecipe, _ x: Int, _ y: Int) throws -> SIMD3<Float> {
            let frame = try RedlampEngine().renderFrame(
                RenderRequest(recipe: recipe, targetSize: session.orientedSize, generation: 0), session: session,
            )
            IOSurfaceLock(frame.surface, .readOnly, nil)
            defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
            let row = (IOSurfaceGetBaseAddress(frame.surface) + y * IOSurfaceGetBytesPerRow(frame.surface))
                .assumingMemoryBound(to: Float16.self)
            return SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
        }
        func colourfulness(_ c: SIMD3<Float>) -> Float {
            c.max() - c.min()
        }
        var recipe = EditRecipe()
        recipe[.defringePurpleAmount] = 20
        let fringeBefore = try colourfulness(pixel(EditRecipe(), 121, 128))
        let fringeAfter = try colourfulness(pixel(recipe, 121, 128))
        let patchBefore = try colourfulness(pixel(EditRecipe(), 410, 130))
        let patchAfter = try colourfulness(pixel(recipe, 410, 130))
        #expect(fringeAfter < fringeBefore * 0.3, "fringe \(fringeBefore) → \(fringeAfter)")
        #expect(abs(patchAfter - patchBefore) < 1e-3, "patch \(patchBefore) → \(patchAfter)")
    }

    /// The whole frame, as a mask a local adjustment can use.
    static func everywhere(_ parameter: ParameterID, _ value: Double) -> MaskLayer {
        var mask = MaskLayer(name: "All", components: [
            MaskComponent(shape: .luminanceRange(LuminanceRangeMask(lower: 0, upper: 100))),
        ])
        mask[parameter] = value
        return mask
    }

    func fringeScene() throws -> ImageSession {
        try session(width: 512, height: 256) { x, _ in
            if x < 120 {
                return SIMD3(repeating: 0.95)
            }
            return x < 124 ? SIMD3(0.30, 0.08, 0.36) : SIMD3(repeating: 0.03)
        }
    }

    func pixel(_ session: ImageSession, _ recipe: EditRecipe, _ x: Int, _ y: Int) throws -> SIMD3<Float> {
        let frame = try RedlampEngine().renderFrame(
            RenderRequest(recipe: recipe, targetSize: session.orientedSize, generation: 0), session: session,
        )
        IOSurfaceLock(frame.surface, .readOnly, nil)
        defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
        let row = (IOSurfaceGetBaseAddress(frame.surface) + y * IOSurfaceGetBytesPerRow(frame.surface))
            .assumingMemoryBound(to: Float16.self)
        return SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
    }

    @Test func `a mask's Defringe greys fringes inside it, or holds the global Defringe back`() throws {
        let session = try fringeScene()
        func colourfulness(_ recipe: EditRecipe) throws -> Float {
            let c = try pixel(session, recipe, 121, 128)
            return c.max() - c.min()
        }
        let plain = try colourfulness(EditRecipe())
        var local = EditRecipe()
        local.masks = [Self.everywhere(.localDefringe, 100)]
        #expect(try colourfulness(local) < plain * 0.3)
        var global = EditRecipe()
        global[.defringePurpleAmount] = 20
        global.masks = [Self.everywhere(.localDefringe, -100)]
        #expect(try abs(colourfulness(global) - plain) < 1e-3, "the mask protects its area")
    }

    @Test func `a mask's Moiré takes the colour out of fine coloured stripes and keeps their brightness`() throws {
        // Alternating magenta and green columns of equal luminance: colour aliasing on a fine pattern.
        let session = try session(width: 256, height: 128) { x, _ in
            Int(x) % 2 == 0 ? SIMD3(0.4, 0.1, 0.4) : SIMD3(0.15, 0.25, 0.15)
        }
        var recipe = EditRecipe()
        recipe.masks = [Self.everywhere(.localMoire, 100)]
        let before = try pixel(session, EditRecipe(), 100, 64), after = try pixel(session, recipe, 100, 64)
        #expect(after.max() - after.min() < (before.max() - before.min()) * 0.3, "\(before) → \(after)")
        let luma = { (c: SIMD3<Float>) in simd_dot(c, SIMD3(0.2627, 0.6780, 0.0593)) }
        #expect(abs(luma(after) - luma(before)) < 0.05, "brightness \(luma(before)) → \(luma(after))")
    }

    @Test func `the vignette's Highlights keep bright corners bright`() throws {
        let session = try session(width: 256, height: 128) { _, _ in SIMD3(repeating: 0.9) }
        var recipe = EditRecipe()
        recipe[.vignetteAmount] = -100
        let darkened = try pixel(session, recipe, 2, 2)
        recipe[.vignetteHighlights] = 100
        let kept = try pixel(session, recipe, 2, 2)
        #expect(kept.y > darkened.y * 1.3, "corner \(darkened.y) → \(kept.y)")
    }
}
