import CoreGraphics
import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Dehaze's dark channel prior on a synthetic hazy scene, and its effect on a real photo.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct HazeTests {
    static let airlight = SIMD3<Float>(0.7, 0.75, 0.8)
    static let transmission: Float = 0.6

    /// A scene of random colours with dark grid lines (every patch has a dark pixel, as the prior
    /// expects), seen through uniform haze, I = J t + A (1 - t), under a sky that is all airlight.
    private func hazySession() throws -> ImageSession {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let kernels = try KernelLibrary(device: device)
        let width = 768
        let height = 512
        let white: Float = 65535
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let block = UInt32((y / 8) * 997 + (x / 8) * 131)
                let line = x % 12 == 0 || y % 12 == 0
                for channel in 0 ..< 3 {
                    let random = Float((block &* 2_654_435_761 &+ UInt32(channel) &* 40503) % 1000) / 1000
                    let scene: Float = line ? 0.02 : 0.1 + 0.8 * random
                    let transmission = y < height / 5 ? 0 : Self.transmission
                    let hazy = scene * transmission + Self.airlight[channel] * (1 - transmission)
                    samples[(y * width + x) * 3 + channel] = UInt16((hazy * white).rounded())
                }
            }
        }
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: white, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/hazy.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    @Test func `the airlight and the haze are measured`() throws {
        let session = try hazySession()
        for channel in 0 ..< 3 {
            #expect(abs(session.airlight[channel] / Self.airlight[channel] - 1) < 0.1, "airlight \(session.airlight)")
        }
        let map = try readMap(session.hazeMap)
        let belowSky = (session.hazeMap.height * 3 / 4) * session.hazeMap.width + session.hazeMap.width / 2
        #expect(abs(map[belowSky] - (1 - Self.transmission)) < 0.06, "haze \(map[belowSky])")
    }

    private func readMap(_ texture: any MTLTexture) throws -> [Float] {
        let device = texture.device
        let rowBytes = texture.width * 2
        let buffer = try #require(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * texture.height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        return (0 ..< texture.width * texture.height).map { Float(halves[$0]) }
    }

    /// Mean of each pixel's darkest channel: the veil Dehaze removes.
    private func veil(_ image: CGImage) throws -> Double {
        let data = try #require(image.dataProvider?.data) as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        var total = 0.0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for row in 0 ..< image.height {
                for column in 0 ..< image.width {
                    let offset = row * image.bytesPerRow + column * bytesPerPixel
                    total += Double(min(bytes[offset], bytes[offset + 1], bytes[offset + 2]))
                }
            }
        }
        return total / Double(image.width * image.height)
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `dehaze lifts the veil and negative dehaze adds it`() async throws {
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "_DSC0009.ARW" })
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        func render(_ amount: Double) async throws -> Double {
            var recipe = EditRecipe()
            recipe[.dehaze] = amount
            return try await veil(engine.renderStill(StillRequest(recipe: recipe, maxLongEdge: 600)))
        }
        let base = try await render(0)
        let lifted = try await render(60)
        let added = try await render(-60)
        // This scene is barely hazy, so the prior finds little to remove.
        #expect(lifted < base * 0.97, "\(base) → \(lifted)")
        #expect(added > base * 1.1, "\(base) → \(added)")
    }
}
