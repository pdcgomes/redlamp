import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Straight edges for automatic Upright (LNS-07).
struct LineDetectorTests {
    static let canRender = MTLCreateSystemDefaultDevice() != nil

    /// A bright rectangle, turned by `degrees`, on a dark ground, supersampled so its edges are
    /// soft as a lens leaves them, with optional noise.
    static func rectangle(degrees: Double, noise: Float = 0, width: Int = 640, height: Int = 480) -> LineDetector
        .Image {
        let angle = degrees * .pi / 180
        var random = BenchmarkRandom(seed: 3)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var inside = 0
                for sy in 0 ..< 4 {
                    for sx in 0 ..< 4 {
                        let px = Double(x) + (Double(sx) + 0.5) / 4 - Double(width) / 2
                        let py = Double(y) + (Double(sy) + 0.5) / 4 - Double(height) / 2
                        let u = px * cos(angle) + py * sin(angle), v = -px * sin(angle) + py * cos(angle)
                        inside += abs(u) < 180 && abs(v) < 120 ? 1 : 0
                    }
                }
                let gaussian = (random.uniform() + random.uniform() + random.uniform() - 1.5) * 2
                values[y * width + x] = 0.25 + 0.4 * Float(inside) / 16 + noise * gaussian
            }
        }
        return LineDetector.Image(width: width, height: height, values: values)
    }

    /// The line's angle from level, in degrees, in 0...180.
    static func angle(_ line: DetectedLine, _ image: LineDetector.Image) -> Double {
        let dx = (line.line.end.x - line.line.start.x) * Double(image.width)
        let dy = (line.line.end.y - line.line.start.y) * Double(image.height)
        let degrees = atan2(dy, dx) * 180 / .pi
        return degrees < 0 ? degrees + 180 : degrees
    }

    @Test(arguments: [0.0, 4, 17])
    func `finds a turned rectangle's four sides at their angle`(degrees: Double) {
        let image = Self.rectangle(degrees: degrees, noise: 0.01)
        let lines = LineDetector.lines(in: image)
        let long = lines.filter { $0.strength > 100 }
        #expect(long.count >= 4 && long.count <= 8, "\(long.count) long lines")
        for line in long {
            let found = Self.angle(line, image)
            let error = [degrees, degrees + 90, degrees + 180].map { abs(found - $0) }.min() ?? 0
            #expect(error < 0.5, "a side at \(found)°, rectangle at \(degrees)°")
        }
        let lengths = long.map { line in
            hypot(
                (line.line.end.x - line.line.start.x) * Double(image.width),
                (line.line.end.y - line.line.start.y) * Double(image.height),
            )
        }
        #expect(lengths.contains { abs($0 - 360) < 20 } && lengths.contains { abs($0 - 240) < 20 }, "\(lengths)")
    }

    @Test func `noise alone has no long lines`() {
        var random = BenchmarkRandom(seed: 9)
        let values = (0 ..< 640 * 480).map { _ in 0.4 + 0.02 * (random.uniform() + random.uniform() - 1) }
        let lines = LineDetector.lines(in: LineDetector.Image(width: 640, height: 480, values: values))
        #expect(lines.filter { $0.strength > 40 }.isEmpty, "\(lines.count) lines in noise")
    }

    /// Vertical bars turned by 3°, in a raw of the given LibRaw orientation, through the session
    /// builder: Level must make them upright in the photo as shown.
    @Test(.enabled(if: canRender), arguments: [0, 6])
    func `Level upright makes a turned photo's bars upright`(orientation: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let kernels = try KernelLibrary(device: device)
        let (width, height) = (1536, 1024)
        let angle = 3.0 * .pi / 180
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                // Supersampled, so the edges are soft as a lens leaves them, not stair-stepped.
                var bar = 0.0
                for sy in 0 ..< 4 {
                    for sx in 0 ..< 4 {
                        let px = Double(x) + (Double(sx) + 0.5) / 4 - Double(width) / 2
                        let py = Double(y) + (Double(sy) + 0.5) / 4 - Double(height) / 2
                        bar += abs(Int(floor((px * cos(angle) + py * sin(angle)) / 96))) % 2 == 0 ? 0.6 / 16 : 0.1 / 16
                    }
                }
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16(bar * 65535)
                }
            }
        }
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: orientation, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/bars.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        let session = try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
        let lines = LineDetector.lines(in: session)
        #expect(lines.count >= 6, "\(lines.count) lines")
        let size = session.orientedSize
        let solved = try #require(Transform().upright(.level, lines: lines, imageSize: size, orientation: .identity))
        #expect(abs(abs(solved.rotate) - 3) < 0.15, "rotate \(solved.rotate)")
        let map = GeometryMap(imageSize: size, transform: solved)
        for line in lines.filter({ $0.strength > 100 }) {
            guard let a = map.outputPoint(SIMD2(line.line.start.x, line.line.start.y)),
                  let b = map.outputPoint(SIMD2(line.line.end.x, line.line.end.y)) else { continue }
            let dx = (b.x - a.x) * Double(size.width), dy = (b.y - a.y) * Double(size.height)
            let off = abs(remainder(atan2(dx, dy), .pi)) * 180 / .pi
            #expect(min(off, 90 - off) < 0.2, "a bar edge \(off)° from upright or level")
        }
    }

    /// A facade of windows photographed looking up, so its verticals converge: Vertical must
    /// find the correction that was applied, from the detected edges alone.
    @Test(.enabled(if: canRender))
    func `Vertical upright straightens a facade shot looking up`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let kernels = try KernelLibrary(device: device)
        let (width, height) = (1024, 768)
        let size = PixelSize(width: width, height: height)
        var truth = Transform()
        truth.vertical = -25
        let map = GeometryMap(imageSize: size, transform: truth)
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var value = 0.0
                for sy in 0 ..< 2 {
                    for sx in 0 ..< 2 {
                        let photo = SIMD2(
                            (Double(x) + (Double(sx) + 0.5) / 2) / Double(width),
                            (Double(y) + (Double(sy) + 0.5) / 2) / Double(height),
                        )
                        // Where the corrected frame shows this photo point: windows on a wall.
                        let facade = map.outputPoint(photo) ?? photo
                        let column = (facade.x * 8).truncatingRemainder(dividingBy: 1)
                        let row = (facade.y * 6).truncatingRemainder(dividingBy: 1)
                        let window = column > 0.25 && column < 0.75 && row > 0.2 && row < 0.8
                        value += (window ? 0.08 : 0.5) / 4
                    }
                }
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16(value * 65535)
                }
            }
        }
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/facade.dng"),
                pixelSize: size,
                isRaw: true,
                sensorDescription: "synthetic",
            ),
        )
        let session = try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
        let lines = LineDetector.lines(in: session)
        let solved = try #require(Transform().upright(.vertical, lines: lines, imageSize: size, orientation: .identity))
        #expect(abs(solved.vertical - truth.vertical) < 2 && abs(solved.rotate) < 0.2, "\(solved)")
        let full = try #require(Transform().upright(.full, lines: lines, imageSize: size, orientation: .identity))
        #expect(abs(full.vertical - truth.vertical) < 2 && abs(full.horizontal) < 2, "\(full)")
    }
}
