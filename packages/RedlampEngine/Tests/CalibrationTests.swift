import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Lightroom's Calibration panel: the primaries' Hue and Saturation, and Shadows Tint.
struct CalibrationTests {
    @Test func `untouched primaries change nothing, and white stays white whatever they do`() throws {
        #expect(Calibration.matrix(EditRecipe()) == nil)
        var recipe = EditRecipe()
        recipe[.calibrationRedHue] = 60
        recipe[.calibrationGreenSaturation] = -40
        recipe[.calibrationBlueHue] = -80
        let matrix = try #require(Calibration.matrix(recipe))
        #expect(simd_length(matrix * SIMD3(repeating: 1) - SIMD3(repeating: 1)) < 1e-12)
    }

    @Test func `red's Hue turns red towards yellow, and its Saturation deepens it`() throws {
        func red(_ hue: Double, _ saturation: Double) throws -> SIMD3<Double> {
            var recipe = EditRecipe()
            recipe[.calibrationRedHue] = hue
            recipe[.calibrationRedSaturation] = saturation
            return try #require(Calibration.matrix(recipe)) * SIMD3(0.6, 0.2, 0.2)
        }
        let warmer = try red(50, 0), cooler = try red(-50, 0)
        #expect(warmer.y > warmer.z, "towards yellow: \(warmer)")
        #expect(cooler.z > cooler.y, "towards magenta: \(cooler)")
        func spread(_ c: SIMD3<Double>) -> Double {
            c.max() - c.min()
        }
        #expect(try spread(red(0, 60)) > spread(SIMD3(0.6, 0.2, 0.2)))
        #expect(try spread(red(0, -60)) < spread(SIMD3(0.6, 0.2, 0.2)))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func `Shadows Tint colours the shadows and leaves bright tones`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let kernels = try KernelLibrary(device: device)
        let (width, height) = (64, 16)
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let grey = x < width / 2 ? 0.02 : 0.7
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16(grey * 65535)
                }
            }
        }
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/tint.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        let session = try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
        func pixels(_ tint: Double) throws -> (dark: SIMD3<Float>, bright: SIMD3<Float>) {
            var recipe = EditRecipe()
            recipe[.calibrationShadowsTint] = tint
            let frame = try RedlampEngine().renderFrame(
                RenderRequest(recipe: recipe, targetSize: session.orientedSize, generation: 0), session: session,
            )
            IOSurfaceLock(frame.surface, .readOnly, nil)
            defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
            let row = (IOSurfaceGetBaseAddress(frame.surface) + 8 * IOSurfaceGetBytesPerRow(frame.surface))
                .assumingMemoryBound(to: Float16.self)
            func at(_ x: Int) -> SIMD3<Float> {
                SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
            }
            return (at(8), at(width - 8))
        }
        let plain = try pixels(0), magenta = try pixels(100), green = try pixels(-100)
        #expect(magenta.dark.x > plain.dark.x && magenta.dark.y < plain.dark.y, "\(plain.dark) → \(magenta.dark)")
        #expect(green.dark.y > plain.dark.y && green.dark.x < plain.dark.x, "\(plain.dark) → \(green.dark)")
        #expect(simd_abs(magenta.bright - plain.bright).max() < 2e-3, "bright tones keep their colour")
    }
}
