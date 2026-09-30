import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Demosaic quality against known full-colour images, through the real session builder.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct DemosaicTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// Real detail: each sample camera's centre, binned 2 x 2 into a clean full-colour image,
    /// mosaiced again and demosaiced. Menon must beat Malvar on colour PSNR.
    @Test(.enabled(if: !EngineSmokeTests.fixtures.isEmpty))
    func `menon is more accurate than malvar on real detail`() throws {
        var gains: [Double] = []
        for url in EngineSmokeTests.fixtures {
            let decoded = try ImageDecoder.decode(url)
            guard case let .mosaic(pattern) = decoded.layout, pattern.width == 2 else { continue }
            let clean = binned(decoded, pattern: pattern, width: 1024, height: 768)
            let menon = try psnr(clean, demosaic(clean, .menon))
            let malvar = try psnr(clean, demosaic(clean, .malvar))
            print(String(format: "demosaic %@: Menon %.2f dB, Malvar %.2f dB", url.lastPathComponent, menon, malvar))
            gains.append(menon - malvar)
        }
        try #require(!gains.isEmpty)
        #expect(gains.reduce(0, +) / Double(gains.count) > 0.3)
    }

    /// A neutral zone plate: every colour a demosaic produces is false colour.
    @Test func `menon makes less false colour than malvar`() throws {
        let width = 512
        let height = 512
        let plate = Image(width: width, height: height, pixels: (0 ..< width * height).map { index in
            let x = Double(index % width - width / 2)
            let y = Double(index / width - height / 2)
            return SIMD3(repeating: Float(0.3 + 0.2 * cos(.pi * (x * x + y * y) / Double(width))))
        })
        let menon = try falseColour(demosaic(plate, .menon))
        let malvar = try falseColour(demosaic(plate, .malvar))
        print(String(format: "zone plate false colour: Menon %.4f, Malvar %.4f", menon, malvar))
        #expect(menon < malvar * 0.8)
    }

    // MARK: - Helpers

    struct Image {
        var width: Int
        var height: Int
        /// White-balanced linear RGB.
        var pixels: [SIMD3<Float>]
    }

    /// One pixel per 2 x 2 block of the mosaic's centre: its red, mean green and blue,
    /// white-balanced and scaled below clipping.
    private func binned(_ image: DecodedImage, pattern: CFAPattern, width: Int, height: Int) -> Image {
        let balance = SIMD3<Float>(image.asShotMultipliers / image.asShotMultipliers.min())
        let x0 = (image.width / 2 - width) & ~1
        let y0 = (image.height / 2 - height) & ~1
        var pixels: [SIMD3<Float>] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                var sums = SIMD3<Float>.zero
                var counts = SIMD3<Float>.zero
                for dy in 0 ..< 2 {
                    for dx in 0 ..< 2 {
                        let px = x0 + 2 * x + dx
                        let py = y0 + 2 * y + dy
                        let color = Int(pattern.color(x: px, y: py))
                        let black = image.blackLevels[((py % 2) * 2 + px % 2) % image.blackLevels.count]
                        let value = (Float(image.samples[py * image.width + px]) - black) / (image.whiteLevel - black)
                        sums[color] += max(value, 0) * balance[color]
                        counts[color] += 1
                    }
                }
                pixels.append(sums / counts)
            }
        }
        let peak = max(pixels.map { $0.max() }.max() ?? 1, 1e-6)
        return Image(width: width, height: height, pixels: pixels.map { $0 * (0.9 / peak) })
    }

    /// Mosaics an image as RGGB and demosaics it with `algorithm`.
    private func demosaic(_ image: Image, _ algorithm: BayerDemosaic) throws -> Image {
        let pattern = CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2])
        let black: Float = 512
        let white: Float = 16383
        var samples = [UInt16](repeating: 0, count: image.width * image.height)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let value = image.pixels[y * image.width + x][Int(pattern.color(x: x, y: y))]
                samples[y * image.width + x] = UInt16((black + min(value, 1) * (white - black)).rounded())
            }
        }
        var decoded = DecodedImage(
            width: image.width, height: image.height, layout: .mosaic(pattern), samples: samples,
            blackLevels: [black, black, black, black], whiteLevel: white, asShotMultipliers: SIMD3(1, 1, 1),
            cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic.dng"),
                pixelSize: PixelSize(width: image.width, height: image.height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = .quantization
        var builder = SessionBuilder(device: device, queue: queue, kernels: kernels)
        builder.bayerDemosaic = algorithm
        let session = try builder.build(decoded)
        return try Image(width: image.width, height: image.height, pixels: readLevel0(session))
    }

    private func readLevel0(_ session: ImageSession) throws -> [SIMD3<Float>] {
        let width = session.pyramid.width
        let height = session.pyramid.height
        let rowBytes = width * 8
        let buffer = try #require(device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: session.pyramid, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        return (0 ..< width * height).map { index in
            SIMD3(Float(halves[index * 4]), Float(halves[index * 4 + 1]), Float(halves[index * 4 + 2]))
        }
    }

    /// Colour PSNR away from an 8 px border.
    private func psnr(_ reference: Image, _ result: Image) -> Double {
        var squares = 0.0
        var count = 0.0
        for y in 8 ..< reference.height - 8 {
            for x in 8 ..< reference.width - 8 {
                let d = reference.pixels[y * reference.width + x] - result.pixels[y * reference.width + x]
                squares += Double(simd_dot(d, d))
                count += 3
            }
        }
        return 10 * log10(1 / (squares / count))
    }

    /// Mean distance from grey, away from an 8 px border.
    private func falseColour(_ image: Image) -> Double {
        var total = 0.0
        var count = 0.0
        for y in 8 ..< image.height - 8 {
            for x in 8 ..< image.width - 8 {
                let p = image.pixels[y * image.width + x]
                let grey = (p.x + p.y + p.z) / 3
                total += Double(simd_length(p - SIMD3(repeating: grey)))
                count += 1
            }
        }
        return total / count
    }
}
