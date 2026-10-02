import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Lens profiles in the develop kernel (LNS-01): distortion, colour fringes and vignetting as
/// `GeometryMap` and `LensCorrection` describe them.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct LensProfileRenderTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary
    static let (width, height) = (384, 256)

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// A barrel correction with red recorded a little wider and blue a little narrower than
    /// green, and corners a stop dark.
    static let lens = LensCorrection(
        source: .sony, center: SIMD2(0.52, 0.48), radii: [0, 0.4, 0.8, 1.2],
        distortion: [
            SIMD3(repeating: 1), SIMD3(1.003, 0.99, 0.997), SIMD3(1.004, 0.97, 0.995), SIMD3(1.006, 0.94, 0.99),
        ],
        vignetting: [1, 1.15, 1.6, 2.2],
    )

    /// Smooth enough that bilinear sampling and the analytic value agree.
    static func pattern(_ point: SIMD2<Double>) -> SIMD3<Double> {
        let wave = sin(2 * .pi * 2.5 * point.x) * cos(2 * .pi * 1.5 * point.y)
        return SIMD3(0.25 + 0.1 * wave, 0.22 - 0.08 * wave, 0.2 + 0.06 * sin(2 * .pi * 3 * point.y))
    }

    func session(lens: LensCorrection?, color: (Int, Int) -> SIMD3<Double>) throws -> ImageSession {
        let (width, height) = (Self.width, Self.height)
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let value = color(x, y)
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16(min(max(value[channel], 0), 1) * 65535)
                }
            }
        }
        var decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/lens.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.lensCorrection = lens
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    func render(_ session: ImageSession, _ recipe: EditRecipe) throws -> [SIMD3<Float>] {
        let size = session.orientedSize
        let frame = try RedlampEngine().renderFrame(
            RenderRequest(recipe: recipe, targetSize: size, generation: 0), session: session,
        )
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface)
        return (0 ..< size.height).flatMap { y in
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
            return (0 ..< size.width)
                .map { x in SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2])) }
        }
    }

    @Test func `the kernel corrects distortion, fringes and vignetting as the geometry says`() throws {
        let profiled = try session(lens: Self.lens) { x, y in
            Self.pattern(SIMD2((Double(x) + 0.5) / Double(Self.width), (Double(y) + 0.5) / Double(Self.height)))
        }
        let size = PixelSize(width: Self.width, height: Self.height)
        let map = GeometryMap(recipe: EditRecipe(), imageSize: size, lens: Self.lens)
        let profile = try #require(map.lensProfile)
        let scale = profile.offsetScale(imageSize: size)
        // The corrected photo, resampled on the CPU: each channel from where the lens put it, lit
        // by the gain at the radius green was recorded at.
        let expected = try session(lens: nil) { x, y in
            let output = SIMD2((Double(x) + 0.5) / Double(Self.width), (Double(y) + 0.5) / Double(Self.height))
            let offset = output - profile.center
            let scales = profile.interpolate(profile.distortion, at: simd_length(offset * scale))
            let green = profile.center + offset * scales.y
            let gain = profile.interpolate(profile.vignetting, at: simd_length((green - profile.center) * scale))
            return gain * SIMD3(
                Self.pattern(profile.center + offset * scales.x).x, Self.pattern(green).y,
                Self.pattern(profile.center + offset * scales.z).z,
            )
        }
        let rendered = try render(profiled, EditRecipe())
        let reference = try render(expected, EditRecipe())
        var off = EditRecipe()
        off[.lensProfile] = 0
        let plain = try render(profiled, off)
        // Away from the border, where clamping at the photo's edge differs. The corners' gain of
        // 2.2 magnifies sampling differences most there.
        var (worst, error, correction): (Float, Float, Float) = (0, 0, 0)
        for y in 8 ..< Self.height - 8 {
            for x in 8 ..< Self.width - 8 {
                let index = y * Self.width + x
                let difference = simd_abs(rendered[index] - reference[index]).max()
                worst = max(worst, difference)
                error += difference
                correction += simd_abs(rendered[index] - plain[index]).max()
            }
        }
        let count = Float((Self.width - 16) * (Self.height - 16))
        #expect(worst < 8e-3 && error / count < 1.5e-3, "largest difference \(worst), mean \(error / count)")
        #expect(correction / count > 0.05, "the correction shows: \(correction / count)")

        let unprofiled = try render(session(lens: nil) { x, y in
            Self.pattern(SIMD2((Double(x) + 0.5) / Double(Self.width), (Double(y) + 0.5) / Double(Self.height)))
        }, off)
        #expect(zip(plain, unprofiled).allSatisfy { simd_abs($0 - $1).max() == 0 }, "turned off, nothing changes")
    }
}
