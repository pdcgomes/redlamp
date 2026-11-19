import CoreGraphics
import Foundation
import ImageIO
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd
import Testing
@testable import RedlampEngine

/// Output sharpening (EDT-28) against Lightroom's Screen sharpening, as measured from its exports
/// of a test chart on 2026-11-18: gains, a line's response and the tone mask are its numbers.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct OutputSharpeningTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// An image of encoded sRGB values, row by row.
    struct Image {
        var width: Int
        var height: Int
        var pixels: [SIMD3<Float>]

        init(width: Int, height: Int, _ value: (Int, Int) -> SIMD3<Float>) {
            self.width = width
            self.height = height
            pixels = (0 ..< height).flatMap { y in (0 ..< width).map { x in value(x, y) } }
        }

        subscript(x: Int, y: Int) -> SIMD3<Float> {
            pixels[y * width + x]
        }

        func row(_ y: Int) -> [Float] {
            (0 ..< width).map { self[$0, y].y }
        }
    }

    static func grey(_ v: Float) -> SIMD3<Float> {
        SIMD3(repeating: v)
    }

    private static func decode(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Runs `image` through the export's last step: decoded to linear light, then encoded as
    /// `sharpening` says, into a 16-bit texture (or 8-bit).
    func run(
        _ image: Image,
        _ sharpening: OutputSharpening,
        colorSpace: OutputColorSpace = .sRGB,
        sixteenBit: Bool = true,
    ) throws -> Image {
        let input = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: image.width, height: image.height, mipmapped: false,
        )
        input.usage = [.shaderRead]
        input.storageMode = .shared
        let linear = try #require(device.makeTexture(descriptor: input))
        var floats: [Float] = image.pixels.flatMap { p in [Self.decode(p.x), Self.decode(p.y), Self.decode(p.z), 1] }
        linear.replace(
            region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
            withBytes: &floats, bytesPerRow: image.width * 16,
        )
        let format: MTLPixelFormat = sixteenBit ? .rgba16Unorm : .rgba8Unorm
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: image.width, height: image.height, mipmapped: false,
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let commands = try #require(queue.makeCommandBuffer())
        try OutputSharpen.encode(
            linear, into: output, sharpening: sharpening, colorSpace: colorSpace, kernels: kernels,
            commands: commands,
        )
        commands.commit()
        commands.waitUntilCompleted()
        try #require(commands.status == .completed, "\(commands.error.map { "\($0)" } ?? "")")
        let region = MTLRegionMake2D(0, 0, image.width, image.height)
        if sixteenBit {
            var values = [UInt16](repeating: 0, count: image.width * image.height * 4)
            output.getBytes(&values, bytesPerRow: image.width * 8, from: region, mipmapLevel: 0)
            return Image(width: image.width, height: image.height) { x, y in
                let i = (y * image.width + x) * 4
                return SIMD3(Float(values[i]), Float(values[i + 1]), Float(values[i + 2])) / 65535
            }
        }
        var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
        output.getBytes(&values, bytesPerRow: image.width * 4, from: region, mipmapLevel: 0)
        return Image(width: image.width, height: image.height) { x, y in
            let i = (y * image.width + x) * 4
            return SIMD3(Float(values[i]), Float(values[i + 1]), Float(values[i + 2])) / 255
        }
    }

    /// A sine's amplitude at `frequency` (cycles per pixel), by least squares.
    private static func amplitude(_ profile: [Float], _ frequency: Float) -> Float {
        var (cc, ss, cs, c1, s1, n) = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(profile.count))
        var (vc, vs, v1) = (Float(0), Float(0), Float(0))
        for (x, v) in profile.enumerated() {
            let c = cos(2 * .pi * frequency * Float(x))
            let s = sin(2 * .pi * frequency * Float(x))
            cc += c * c; ss += s * s; cs += c * s; c1 += c; s1 += s
            vc += v * c; vs += v * s; v1 += v
        }
        // Normal equations for v ≈ a cos + b sin + m, solved by Cramer's rule.
        let m = simd_float3x3(rows: [SIMD3(cc, cs, c1), SIMD3(cs, ss, s1), SIMD3(c1, s1, n)])
        let solution = m.inverse * SIMD3(vc, vs, v1)
        return (solution.x * solution.x + solution.y * solution.y).squareRoot()
    }

    /// Lightroom's Screen Low, Standard and High.
    static let levels: [OutputSharpening] = [.low, .standard, .high]

    /// What Lightroom adds across a 1 px line (0.6 on 0.5) at the line and beside it, per unit of its height. On
    /// the chart's own line this operator adds 0.170 / 0.283 / 0.452 at the line; on this ideal one about 4% more.
    static let lineResponse: [OutputSharpening: (Float, Float)] = [
        .low: (0.169, -0.082), .standard: (0.282, -0.136), .high: (0.450, -0.216),
    ]

    @Test(arguments: levels)
    func `a 1 px line gets Lightroom's response`(sharpening: OutputSharpening) throws {
        let image = Image(width: 33, height: 9) { x, _ in Self.grey(x == 16 ? 0.6 : 0.5) }
        let out = try run(image, sharpening)
        let added = (14 ... 18).map { (out[$0, 4].y - image[$0, 4].y) / 0.1 }
        let (centre, side) = try #require(Self.lineResponse[sharpening])
        #expect(abs(added[2] - centre) < 0.06 * centre, "centre \(added[2]) for Lightroom's \(centre)")
        #expect(abs(added[1] - side) < 0.01 && abs(added[3] - side) < 0.01, "sides \(added[1]), \(added[3])")
        #expect(abs(added[0]) < 0.002 && abs(added[4]) < 0.002, "two pixels out \(added[0]), \(added[4])")
    }

    /// Periods in pixels and Lightroom's gain on a grating of amplitude 0.10 about 0.5.
    static let periods: [Float] = [16, 8, 6, 4, 3, 2.5, 2.222]
    static let gratingGains: [OutputSharpening: [Float]] = [
        .low: [1.012, 1.047, 1.080, 1.164, 1.243, 1.292, 1.316],
        .standard: [1.020, 1.078, 1.133, 1.274, 1.405, 1.487, 1.526],
        .high: [1.033, 1.125, 1.212, 1.438, 1.648, 1.779, 1.842],
    ]

    @Test(arguments: levels)
    func `gratings gain what Lightroom's do`(sharpening: OutputSharpening) throws {
        let expected = try #require(Self.gratingGains[sharpening])
        for (period, lightroom) in zip(Self.periods, expected) {
            let image = Image(width: 160, height: 5) { x, _ in
                Self.grey(0.5 + 0.1 * sin(2 * .pi * Float(x) / period))
            }
            let out = try run(image, sharpening)
            let before = Self.amplitude(Array(image.row(2)[8 ..< 152]), 1 / period)
            let after = Self.amplitude(Array(out.row(2)[8 ..< 152]), 1 / period)
            #expect(
                abs(after / before - lightroom) < 0.005 + 0.08 * (lightroom - 1),
                "\(period) px: \(after / before), Lightroom \(lightroom)",
            )
        }
    }

    /// Lightroom's gain on a 4 px grating of amplitude 0.03, by encoded level: the tone mask.
    static let toneLevels: [Float] = [0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95]
    static let toneGains: [Float] = [1.00, 1.03, 1.12, 1.18, 1.24, 1.31, 1.27, 1.19, 1.08, 1.01]

    @Test func `the gain follows Lightroom's tone mask, fading towards black and white`() throws {
        for (level, lightroom) in zip(Self.toneLevels, Self.toneGains) {
            let image = Image(width: 80, height: 5) { x, _ in
                Self.grey(level + 0.03 * sin(2 * .pi * Float(x) / 4))
            }
            let out = try run(image, .standard)
            let before = Self.amplitude(Array(image.row(2)[8 ..< 72]), 0.25)
            let after = Self.amplitude(Array(out.row(2)[8 ..< 72]), 0.25)
            #expect(abs(after / before - lightroom) < 0.03, "at \(level): \(after / before), Lightroom \(lightroom)")
        }
    }

    @Test(arguments: [(Float(0.05), Float(0.95)), (0, 1)])
    func `an edge into black or white gets no halo`(low: Float, high: Float) throws {
        let image = Image(width: 24, height: 5) { x, _ in Self.grey(x < 12 ? low : high) }
        let out = try run(image, .high)
        for x in 0 ..< 24 {
            let change = abs(out[x, 2].y - image[x, 2].y)
            #expect(change < 0.01 * (high - low), "\(change) at \(x)")
        }
    }

    @Test func `colours keep their channels' proportions at an edge`() throws {
        let dark = SIMD3<Float>(0.35, 0.12, 0.08)
        let light = SIMD3<Float>(0.75, 0.40, 0.30)
        let image = Image(width: 24, height: 5) { x, _ in x < 12 ? dark : light }
        let out = try run(image, .high)
        #expect(abs(out[11, 2].y - image[11, 2].y) > 0.005, "the edge wasn't sharpened")
        for x in 0 ..< 24 {
            let ratio = out[x, 2] / image[x, 2]
            #expect(abs(ratio.x - ratio.y) < 0.003 && abs(ratio.x - ratio.z) < 0.004, "\(ratio) at \(x)")
        }
    }

    @Test func `an edge between colours of equal luminance isn't sharpened`() throws {
        // Red and green of the same luminance in linear light, as the study chart draws them.
        let red = SIMD3<Float>(0.75, 0.32, 0.30)
        let weights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(Self.decode(c.x), Self.decode(c.y), Self.decode(c.z))
        }
        let target = (linear(red) * weights).sum()
        let g = (target - 0.2126 * Self.decode(0.30) - 0.0722 * Self.decode(0.25)) / 0.7152
        let green = SIMD3<Float>(0.30, pow(g, 1 / 2.4) * 1.055 - 0.055, 0.25)
        let image = Image(width: 24, height: 5) { x, _ in x < 12 ? red : green }
        let plain = try run(image, .off)
        let out = try run(image, .high)
        for (a, b) in zip(plain.pixels, out.pixels) {
            #expect(simd_abs(a - b).max() < 0.002, "\(a) became \(b)")
        }
    }

    @Test(arguments: [OutputColorSpace.sRGB, .displayP3], [true, false])
    func `a flat field stays flat to its edges`(colorSpace: OutputColorSpace, sixteenBit: Bool) throws {
        let image = Image(width: 17, height: 11) { _, _ in SIMD3(0.42, 0.53, 0.61) }
        let plain = try run(image, .off, colorSpace: colorSpace, sixteenBit: sixteenBit)
        let out = try run(image, .high, colorSpace: colorSpace, sixteenBit: sixteenBit)
        let step: Float = sixteenBit ? 1 / 65535 : 1 / 255
        for (a, b) in zip(plain.pixels, out.pixels) {
            #expect(simd_abs(a - b).max() <= step * 1.001, "\(a) became \(b)")
        }
    }

    @Test func `off is the plain encode`() throws {
        let image = Image(width: 9, height: 9) { x, y in Self.grey(Float((x * 7 + y * 3) % 11) / 10) }
        let out = try run(image, .off, sixteenBit: false)
        for (a, b) in zip(image.pixels, out.pixels) {
            #expect(simd_abs(a - b).max() < 0.5 / 255 + 1e-4, "\(a) became \(b)")
        }
    }

    /// Writes `chart-native.tif` from the study folder, sharpened at each level, as 16-bit TIFFs in
    /// `<folder>/exports/redlamp/<level>/`, for its `analyze.py` to measure beside Lightroom's:
    /// `TEST_RUNNER_REDLAMP_OUTPUT_SHARPENING_STUDY=<folder>`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_OUTPUT_SHARPENING_STUDY"] != nil))
    func `the study chart, sharpened at each level`() throws {
        let folder = try URL(fileURLWithPath: #require(
            ProcessInfo.processInfo.environment["REDLAMP_OUTPUT_SHARPENING_STUDY"],
        ))
        let chart = try Self.readTIFF(folder.appending(path: "charts/chart-native.tif"))
        for sharpening in OutputSharpening.allCases {
            let out = try run(chart, sharpening)
            let directory = folder
                .appending(path: "exports/redlamp/\(sharpening == .off ? "off" : "screen-\(sharpening.rawValue)")")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.writeTIFF(out, to: directory.appending(path: "chart-native.tif"))
        }
    }

    private static func readTIFF(_ url: URL) throws -> Image {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (width, height) = (image.width, image.height)
        var values = [UInt16](repeating: 0, count: width * height * 4)
        let space = try #require(image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        try values.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 16,
                bytesPerRow: width * 8, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue,
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Image(width: width, height: height) { x, y in
            let i = (y * width + x) * 4
            return SIMD3(Float(values[i]), Float(values[i + 1]), Float(values[i + 2])) / 65535
        }
    }

    private static func writeTIFF(_ image: Image, to url: URL) throws {
        var values: [UInt16] = image.pixels.flatMap { p in
            [p.x, p.y, p.z].map { UInt16(($0 * 65535).rounded()) } + [65535]
        }
        let data = Data(bytes: &values, count: values.count * 2)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let cgImage = try #require(CGImage(
            width: image.width, height: image.height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: image.width * 8, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
