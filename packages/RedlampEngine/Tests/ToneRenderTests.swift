import Foundation
import IOSurface
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Edge-aware Highlights and Shadows (process 7) against the per-pixel ones (process 6), through
/// the real engine on a synthetic linear photo.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct ToneRenderTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// A shadow with texture (columns half a stop apart, about two stops under middle grey, where
    /// Shadows' weight changes fastest) beside a bright area. Lifting it per pixel lifts its darker
    /// threads more than its lighter ones and flattens them; the edge-aware lift moves the shadow
    /// together, as a plain exposure change to the same brightness would.
    @Test func `lifting the shadows keeps their texture`() throws {
        let width = 256
        let height = 128
        let session = try makeSession(width: width, height: height) { x, _ in
            guard x < width / 2 else { return SIMD3(repeating: 0.6) }
            return SIMD3(repeating: x % 2 == 0 ? 0.04 : 0.04 * 1.41)
        }
        func texture(_ recipe: EditRecipe) throws -> (contrast: Float, level: Float) {
            let pixels = try render(recipe, session: session)
            var ratios: [Float] = []
            var levels: [Float] = []
            let luma = SIMD3<Float>(0.2627, 0.678, 0.0593)
            for y in stride(from: 20, to: height - 20, by: 4) {
                for x in stride(from: 20, to: width / 2 - 20, by: 2) {
                    let dark = simd_dot(pixels[y * width + x], luma)
                    let light = simd_dot(pixels[y * width + x + 1], luma)
                    ratios.append(light / max(dark, 1e-6))
                    levels.append((dark + light) / 2)
                }
            }
            return (ratios.reduce(0, +) / Float(ratios.count), levels.reduce(0, +) / Float(levels.count))
        }
        func edit(shadows: Double = 0, exposure: Double = 0, process: Int) -> EditRecipe {
            var recipe = EditRecipe()
            recipe.processVersion = process
            recipe[.shadows] = shadows
            recipe[.exposure] = exposure
            return recipe
        }
        let untouched = try texture(edit(process: 7))
        let perPixel = try texture(edit(shadows: 100, process: 6))
        let edgeAware = try texture(edit(shadows: 100, process: 7))
        #expect(
            perPixel.level > untouched.level * 1.3 && edgeAware.level > untouched.level * 1.3,
            "both lift the shadow",
        )
        // The exposure that lifts the shadow as far: the texture a lift should keep.
        var matched = untouched
        for step in 1 ... 60 {
            let candidate = try texture(edit(exposure: Double(step) * 0.05, process: 7))
            matched = candidate
            if candidate.level >= edgeAware.level {
                break
            }
        }
        print(
            "texture contrast: untouched \(untouched.contrast), exposure-matched \(matched.contrast), per pixel \(perPixel.contrast), edge-aware \(edgeAware.contrast)",
        )
        #expect(
            edgeAware.contrast > perPixel.contrast + 0.03,
            "edge-aware \(edgeAware.contrast), per pixel \(perPixel.contrast)",
        )
        #expect(
            abs(edgeAware.contrast - matched.contrast) < abs(perPixel.contrast - matched.contrast) / 2,
            "an exposure lift to the same level keeps \(matched.contrast); edge-aware \(edgeAware.contrast), per pixel \(perPixel.contrast)",
        )
        #expect(try texture(edit(process: 6)).contrast == untouched.contrast, "without Shadows the processes agree")
    }

    // MARK: - Helpers (as MaskRenderTests')

    private func render(_ recipe: EditRecipe, session: ImageSession) throws -> [SIMD3<Float>] {
        let engine = try RedlampEngine()
        let size = session.orientedSize
        let frame = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: size, generation: 0), session: session,
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

    private func makeSession(width: Int, height: Int, color: (Int, Int) -> SIMD3<Float>) throws -> ImageSession {
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
                url: URL(fileURLWithPath: "/synthetic-tone.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = DetailStageTests.noise
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }
}
