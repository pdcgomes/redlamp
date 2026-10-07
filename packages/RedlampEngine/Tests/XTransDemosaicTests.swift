import Foundation
import Metal
import RedlampEngineAPI
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Markesteijn's X-Trans demosaic (CAM-07) through the real session builder.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct XTransDemosaicTests {
    let detail: DetailStageTests

    init() throws {
        detail = try DetailStageTests()
    }

    /// Fujifilm's tile, as `DetailStageTests.makeSession` uses it.
    static let tile: [UInt8] = [
        1, 1, 0, 1, 1, 2, 1, 1, 2, 1, 1, 0, 2, 0, 1, 0, 2, 1,
        1, 1, 2, 1, 1, 0, 1, 1, 0, 1, 1, 2, 0, 2, 1, 2, 0, 1,
    ]

    /// The tile seen from another origin, as a raw cut at another offset shows it.
    static func shifted(_ dx: Int, _ dy: Int) -> CFAPattern {
        CFAPattern(width: 6, height: 6, colors: (0 ..< 36).map { index in
            tile[((index / 6 + dy) % 6) * 6 + (index % 6 + dx) % 6]
        })
    }

    /// `signal` is each photosite's normalised value before white balance.
    func session(
        _ pattern: CFAPattern = shifted(0, 0),
        size: Int = 192,
        asShot: SIMD3<Double> = SIMD3(1, 1, 1),
        noise: Float = 0,
        demosaic: XTransDemosaic = .markesteijn,
        signal: (Int, Int, Int) -> Float,
    ) throws -> [SIMD3<Float>] {
        let black: Float = 512
        let white: Float = 16383
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func gaussian() -> Float {
            func uniform() -> Float {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return (Float(state >> 40) + 0.5) / Float(1 << 24)
            }
            return (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
        let samples = (0 ..< size * size).map { index in
            let (x, y) = (index % size, index / size)
            let value = signal(x, y, Int(pattern.color(x: x, y: y)))
            let noisy = value + noise * (DetailStageTests.noise.a.x * max(value, 0) + DetailStageTests.noise.b.x)
                .squareRoot() * gaussian()
            return UInt16(min(max(black + noisy * (white - black), 0), 65535).rounded())
        }
        var decoded = DecodedImage(
            width: size, height: size, layout: .mosaic(pattern), samples: samples,
            blackLevels: [Float](repeating: black, count: 36), whiteLevel: white, asShotMultipliers: asShot,
            cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/xtrans.raf"), pixelSize: PixelSize(width: size, height: size),
                isRaw: true, sensorDescription: "synthetic X-Trans",
            ),
        )
        decoded.noiseProfile = DetailStageTests.noise
        var builder = SessionBuilder(device: detail.device, queue: detail.queue, kernels: detail.kernels)
        builder.xTransDemosaic = demosaic
        return try detail.readLevel(builder.build(decoded), level: 0)
    }

    static func interior(_ size: Int) -> [(Int, Int)] {
        (12 ..< size - 12).flatMap { y in (12 ..< size - 12).map { x in (x, y) } }
    }

    @Test(arguments: [(0, 0), (1, 0), (2, 3), (3, 3), (5, 4)])
    func `the tables fit every phase of the pattern`(dx: Int, dy: Int) throws {
        let pattern = Self.shifted(dx, dy)
        let table = try #require(XTransMarkesteijn(pattern))
        #expect(table.hex.count == 72)
        let row = Int(table.solitaryRow), column = Int(table.solitaryColumn)
        #expect(pattern.color(x: column, y: row) == 1)
        for (x, y) in [(column + 1, row), (column + 5, row), (column, row + 1), (column, row + 5)] {
            #expect(pattern.color(x: x, y: y) != 1, "a solitary green's neighbours aren't green")
        }
    }

    @Test func `patterns that aren't X-Trans have no tables`() {
        #expect(XTransMarkesteijn(CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2])) == nil)
        #expect(XTransMarkesteijn(CFAPattern(width: 6, height: 6, colors: [UInt8](repeating: 1, count: 36))) == nil)
    }

    @Test(arguments: [(0, 0), (2, 3), (5, 4)])
    func `a flat field demosaics to itself at any phase and white balance`(dx: Int, dy: Int) throws {
        let pixels = try session(Self.shifted(dx, dy), asShot: SIMD3(2, 1, 1.5)) { _, _, _ in 0.25 }
        let expected = SIMD3<Float>(0.5, 0.25, 0.375)
        for (x, y) in Self.interior(192) {
            let pixel = pixels[y * 192 + x]
            #expect(simd_reduce_max(simd_abs(pixel - expected)) < 2e-3, "(\(x), \(y)): \(pixel)")
            if simd_reduce_max(simd_abs(pixel - expected)) >= 2e-3 {
                return
            }
        }
    }

    @Test func `values above white aren't clipped`() throws {
        let pixels = try session(asShot: SIMD3(2, 1, 1.9)) { _, _, _ in 0.6 }
        let pixel = pixels[96 * 192 + 96]
        #expect(abs(pixel.x - 1.2) < 3e-3 && abs(pixel.z - 1.14) < 3e-3, "\(pixel)")
    }

    @Test func `strong noise leaves no NaN and keeps the level`() throws {
        let pixels = try session(noise: 8) { _, _, _ in 0.1 }
        let interior = Self.interior(192).map { pixels[$0.1 * 192 + $0.0] }
        #expect(interior.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        let mean = interior.reduce(SIMD3<Float>.zero, +) / Float(interior.count)
        #expect(simd_reduce_max(simd_abs(mean - 0.1)) < 0.004, "\(mean)")
    }

    /// A grey edge at 5° and a grey zone plate, both box-filtered over each photosite.
    static func coverage(_ x: Int, _ y: Int, _ scene: (Float, Float) -> Float) -> Float {
        var sum: Float = 0
        for sy in 0 ..< 4 {
            for sx in 0 ..< 4 {
                sum += scene(Float(x) + (Float(sx) + 0.5) / 4, Float(y) + (Float(sy) + 0.5) / 4)
            }
        }
        return sum / 16
    }

    static func edge(_ x: Float, _ y: Float) -> Float {
        (x - 96) * cos(Float.pi / 36) + (y - 96) * sin(Float.pi / 36) > 0 ? 0.45 : 0.05
    }

    static func zonePlate(_ x: Float, _ y: Float) -> Float {
        let r2 = (x - 96) * (x - 96) + (y - 96) * (y - 96)
        return 0.25 + 0.2 * cos(Float.pi * 0.45 / 96 * r2)
    }

    @Test func `an edge keeps its sharpness`() throws {
        func error(_ demosaic: XTransDemosaic) throws -> Float {
            let pixels = try session(demosaic: demosaic) { x, y, _ in Self.coverage(x, y, Self.edge) }
            var squared: Float = 0
            for (x, y) in Self.interior(192) {
                let luma = simd_reduce_add(pixels[y * 192 + x]) / 3
                squared += pow(luma - Self.coverage(x, y, Self.edge), 2)
            }
            return squared.squareRoot()
        }
        let markesteijn = try error(.markesteijn), generic = try error(.generic)
        #expect(markesteijn < 0.6 * generic, "edge error \(markesteijn), generic \(generic)")
    }

    @Test func `fine grey detail stays grey`() throws {
        func falseColour(_ demosaic: XTransDemosaic) throws -> Float {
            let pixels = try session(demosaic: demosaic) { x, y, _ in Self.coverage(x, y, Self.zonePlate) }
            var sum: Float = 0
            for (x, y) in Self.interior(192) {
                let p = pixels[y * 192 + x]
                sum += abs(p.x - p.y) + abs(p.z - p.y)
            }
            return sum / Float(Self.interior(192).count)
        }
        let markesteijn = try falseColour(.markesteijn), generic = try falseColour(.generic)
        #expect(markesteijn < 0.3 * generic, "false colour \(markesteijn), generic \(generic)")
    }
}
