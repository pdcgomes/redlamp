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

/// Synthetic photos and their renders, for Point Color's tests.
protocol PointColorRendering {
    var device: any MTLDevice { get }
    var queue: any MTLCommandQueue { get }
    var kernels: KernelLibrary { get }
}

extension PointColorRendering {
    /// A warm, skin-like colour on the left and a blue on the right, far apart in hue.
    static var skin: SIMD3<Float> {
        SIMD3(0.45, 0.25, 0.15)
    }

    static var blue: SIMD3<Float> {
        SIMD3(0.08, 0.12, 0.4)
    }

    /// Pixels in the middle row of `halves()`: the skin's and the blue's.
    var left: Int {
        20 * 160 + 40
    }

    var right: Int {
        20 * 160 + 120
    }

    func halves() throws -> ImageSession {
        try makeSession(width: 160, height: 40) { x, _ in x < 80 ? Self.skin : Self.blue }
    }

    func swatch(_ color: SIMD3<Double>, _ values: [ParameterID: Double] = [:]) -> PointColorSwatch {
        PointColorSwatch(color: .oklch(OKLCh(lightness: color.x, chroma: color.y, hue: color.z)), values: values)
    }

    /// OKLab lightness, chroma and hue (degrees) of a linear Display P3 output pixel.
    func lch(_ pixel: SIMD3<Float>) -> SIMD3<Double> {
        let srgb = RGBPrimaries.displayP3.conversion(to: .sRGB) * SIMD3<Double>(pixel)
        let lab = OKLab.fromLinearSRGB(srgb)
        let hue = atan2(lab.z, lab.y) * 180 / .pi
        return SIMD3(lab.x, hypot(lab.y, lab.z), hue < 0 ? hue + 360 : hue)
    }

    func hueDifference(_ a: Double, _ b: Double) -> Double {
        (a - b + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    /// Ottosson's OKLab to linear sRGB.
    static func linearSRGB(oklab lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        return SIMD3(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        )
    }

    /// The edit's frame at full size, as linear output.
    func render(_ recipe: EditRecipe, session: ImageSession, visualize: UUID? = nil) throws -> [SIMD3<Float>] {
        let engine = try RedlampEngine()
        let size = recipe.developedSize(imageSize: session.orientedSize)
        var request = RenderRequest(recipe: recipe, targetSize: size, generation: 0)
        request.visualizePointColor = visualize
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

    /// A noiseless linear raw of `color(x, y)` in camera RGB (identity matrix: linear sRGB), as the
    /// camera recorded it before turning it by `orientation` (LibRaw's code).
    func makeSession(
        width: Int, height: Int, orientation: Int = 0, color: (Int, Int) -> SIMD3<Float>,
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
            orientation: orientation, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic-point-color.dng"),
                pixelSize: orientation == 5 || orientation == 6
                    ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = DetailStageTests.noise
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }
}
