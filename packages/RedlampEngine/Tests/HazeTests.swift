import CoreGraphics
import Foundation
import IOSurface
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

    // MARK: - The refined map (process 8)

    private static let edgeWidth = 768
    private static let edgeHeight = 512
    private static let tree = 400 ..< 520

    private static let skyHaze: Float = 0.7
    private static let treeTransmission: Float = 0.8

    /// A sky darker than the airlight (which a hazier corner sets) and a nearer, less hazy,
    /// textured tree rising into it. The coarse map spreads the tree's low haze a patch-width into
    /// the sky.
    private static func edgeScene(x: Int, y: Int) -> SIMD3<Float> {
        if x < 200, y < 150 {
            return airlight
        }
        guard tree.contains(x), y >= 150 else { return airlight * skyHaze }
        let block = UInt32((y / 6) * 997 + (x / 6) * 131)
        let line = x % 10 == 0 || y % 10 == 0
        return SIMD3((0 ..< 3).map { channel -> Float in
            let random = Float((block &* 2_654_435_761 &+ UInt32(channel) &* 40503) % 1000) / 1000
            let scene: Float = line ? 0.01 : 0.03 + 0.15 * random
            return scene * treeTransmission + airlight[channel] * (1 - treeTransmission)
        })
    }

    @Test func `the refined map keeps the sky's haze up to the tree`() {
        // The coarse map's blocks, as `rl_haze_dark` makes them.
        let block = 2
        let width = Self.edgeWidth / block
        let height = Self.edgeHeight / block
        var dark = [Float](repeating: 1, count: width * height)
        var guide = [Float](repeating: 0, count: width * height)
        for y in 0 ..< Self.edgeHeight {
            for x in 0 ..< Self.edgeWidth {
                let texel = (y / block) * width + x / block
                let pixel = Self.edgeScene(x: x, y: y)
                dark[texel] = min(dark[texel], (pixel / Self.airlight).min())
                guide[texel] += Haze.guide(pixel, airlight: Self.airlight) / Float(block * block)
            }
        }
        let refined = Haze.refined(dark: dark, guide: guide, width: width, height: height)
        let c = refined.coefficients
        func haze(x: Int, y: Int) -> Float {
            let texel = (y / block) * width + x / block
            let guided = c.a[texel] * Haze.guide(Self.edgeScene(x: x, y: y), airlight: Self.airlight) + c.b[texel]
            return min(guided, refined.ceiling[texel])
        }
        let openSky = haze(x: 300, y: 350)
        let besideTree = haze(x: Self.tree.lowerBound - 4, y: 350)
        let inTree = (0 ..< 20).map { haze(x: Self.tree.lowerBound + 20 + $0 * 4, y: 350) }.reduce(0, +) / 20
        print("haze: open sky \(openSky), beside the tree \(besideTree), in the tree \(inTree)")
        #expect(abs(openSky - Self.skyHaze) < 0.05, "open sky \(openSky)")
        // The patch minimum leaves the tree's haze beside it; the refined map takes it at least
        // three quarters of the way back to the sky's.
        let treeHaze = 1 - Self.treeTransmission
        #expect(
            openSky - besideTree < (openSky - treeHaze) / 4,
            "beside the tree \(besideTree), open sky \(openSky), the tree \(treeHaze)",
        )
        #expect(abs(inTree - (1 - Self.treeTransmission)) < 0.1, "in the tree \(inTree)")
    }

    /// The ceiling's reconstruction grows back through what is connected and as high as the mask,
    /// but not across a darker barrier.
    @Test func `the reconstruction grows only through what it is connected to`() {
        let width = 9
        // Sky (0.7) on the left, a dark wall (0.1) at column 4, more sky (0.7) behind it.
        let mask = (0 ..< width).map { x -> Float in x == 4 ? 0.1 : 0.7 }
        // The patch minimum: the sky beside the wall eroded, the sky behind it eroded entirely.
        let marker: [Float] = [0.7, 0.7, 0.2, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1]
        let grown = Haze.reconstruction(of: marker, under: mask, width: width, height: 1)
        #expect(Array(grown[0 ..< 4]) == [0.7, 0.7, 0.7, 0.7], "the sky beside the wall grows back: \(grown)")
        #expect(grown[4] == 0.1, "the wall keeps its own: \(grown)")
        #expect(Array(grown[5...]).allSatisfy { $0 == 0.1 }, "nothing crosses the wall: \(grown)")
    }

    /// A session on a synthetic linear scene of `edgeWidth` by `edgeHeight`, as a raw.
    private static func syntheticSession(
        named name: String, _ scene: (_ x: Int, _ y: Int) -> SIMD3<Float>,
    ) throws -> ImageSession {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let kernels = try KernelLibrary(device: device)
        let width = edgeWidth
        let height = edgeHeight
        let white: Float = 65535
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let value = scene(x, y)
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16((value[channel] * white).rounded())
                }
            }
        }
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: white, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/\(name)"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    @Test func `refined Dehaze leaves no glow beside the tree`() throws {
        let session = try Self.syntheticSession(named: "tree.dng", Self.edgeScene)
        let engine = try RedlampEngine()
        func glow(process: Int) throws -> Float {
            var recipe = EditRecipe()
            recipe.processVersion = process
            recipe[.dehaze] = 100
            let frame = try engine.renderFrame(
                RenderRequest(recipe: recipe, targetSize: session.orientedSize, generation: 0), session: session,
            )
            let surface = frame.surface
            IOSurfaceLock(surface, .readOnly, nil)
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            let rowBytes = IOSurfaceGetBytesPerRow(surface)
            let base = IOSurfaceGetBaseAddress(surface)
            func brightness(_ columns: Range<Int>) -> Float {
                var total: Float = 0
                var count: Float = 0
                for y in 250 ..< 450 {
                    let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
                    for x in columns {
                        total += Float(row[x * 4]) + Float(row[x * 4 + 1]) + Float(row[x * 4 + 2])
                        count += 3
                    }
                }
                return total / count
            }
            let beside = brightness(Self.tree.lowerBound - 8 ..< Self.tree.lowerBound - 2)
            let open = brightness(300 ..< 340)
            return beside / open - 1
        }
        let coarse = try glow(process: 7)
        let refined = try glow(process: 8)
        print("glow beside the tree: coarse \(coarse), refined \(refined)")
        #expect(coarse > 0.05, "the coarse map leaves a glow: \(coarse)")
        #expect(abs(refined) < coarse / 3, "refined \(refined), coarse \(coarse)")
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

    // MARK: - Added haze (process 18)

    private static let wall = 100 ..< 300
    private static let books = 468 ..< 668

    /// A bright, neutral wall on the left and dark, saturated books on the right, each a ramp of
    /// brightness down the frame, so a veil shows as the ramp flattening. The wall's brightest rows
    /// set the airlight, so the prior finds the wall hazy and the books clear, and the veil's cool
    /// tint shows against the wall's grey.
    private static func fogScene(x: Int, y: Int) -> SIMD3<Float> {
        let ramp = 0.7 + 0.3 * Float(y) / Float(edgeHeight)
        return (x < edgeWidth / 2 ? SIMD3(0.52, 0.52, 0.52) : SIMD3(0.2, 0.065, 0.035)) * ramp
    }

    /// The frame's pixels as RGB, in the encoding frames are drawn in.
    private static func pixels(of frame: RenderedFrame) -> [SIMD3<Float>] {
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface)
        return (0 ..< width * height).map { index in
            let row = (base + (index / width) * rowBytes).assumingMemoryBound(to: Float16.self)
            let x = index % width
            return SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
        }
    }

    /// Over `columns`, away from the frame's edges: the mean luminance, the ramp's variation (the
    /// luminance's standard deviation over its mean) and blue over red, in the frame's encoding.
    private static func region(
        _ columns: Range<Int>,
        of pixels: [SIMD3<Float>],
    ) -> (lum: Float, ramp: Float, cool: Float) {
        var count = 0.0
        var sum = 0.0
        var sumSquares = 0.0
        var blueOverRed = 0.0
        for y in 100 ..< edgeHeight - 100 {
            for x in columns {
                let pixel = pixels[y * edgeWidth + x]
                let lum = Double(dot(pixel, SIMD3(0.2126, 0.7152, 0.0722)))
                count += 1
                sum += lum
                sumSquares += lum * lum
                blueOverRed += Double(pixel.z / max(pixel.x, 1e-3))
            }
        }
        let mean = sum / count
        return (Float(mean), Float((sumSquares / count - mean * mean).squareRoot() / mean), Float(blueOverRed / count))
    }

    @Test func `added haze thickens on the bright wall and leaves the dark books clear`() throws {
        let session = try Self.syntheticSession(named: "fog.dng", Self.fogScene)
        let engine = try RedlampEngine()
        func render(process: Int, dehaze: Double) throws -> [SIMD3<Float>] {
            var recipe = EditRecipe()
            recipe.processVersion = process
            recipe[.dehaze] = dehaze
            return try Self.pixels(of: engine.renderFrame(
                RenderRequest(recipe: recipe, targetSize: session.orientedSize, generation: 0), session: session,
            ))
        }
        // What -100 does to each region against 0: how much of the ramp's variation is left, how
        // far the luminance rose, and how blue over red moved.
        struct Change {
            var wallRamp: Float
            var booksRamp: Float
            var wallLift: Float
            var booksLift: Float
            var wallCool: Float
            var booksCool: Float
        }
        var changes: [Int: Change] = [:]
        for process in [17, 18] {
            let base = try render(process: process, dehaze: 0)
            let hazed = try render(process: process, dehaze: -100)
            let wall = (Self.region(Self.wall, of: base), Self.region(Self.wall, of: hazed))
            let books = (Self.region(Self.books, of: base), Self.region(Self.books, of: hazed))
            changes[process] = Change(
                wallRamp: wall.1.ramp / wall.0.ramp, booksRamp: books.1.ramp / books.0.ramp,
                wallLift: wall.1.lum - wall.0.lum, booksLift: books.1.lum - books.0.lum,
                wallCool: wall.1.cool - wall.0.cool, booksCool: books.1.cool - books.0.cool,
            )
            print("process \(process): the wall \(wall.0) → \(wall.1), the books \(books.0) → \(books.1)")
        }
        let even = try #require(changes[17])
        let byMap = try #require(changes[18])
        // The veil swallows the wall, flattening its ramp, while the books keep theirs; the even
        // blend lifted the books into its grey, which flattened their ramp more than the wall's.
        #expect(byMap.wallRamp < byMap.booksRamp - 0.3, "process 18: \(byMap)")
        #expect(even.wallRamp > even.booksRamp, "process 17: \(even)")
        // The books rise about as far as under the even blend (the veil's clear parts are lifted too),
        // but keep most of their ramp and more of their colour, where the grey blend flattened both.
        #expect(
            byMap.booksRamp > 2 * even.booksRamp,
            "the books kept \(byMap.booksRamp) of their ramp against \(even.booksRamp)",
        )
        #expect(
            byMap.booksCool < even.booksCool,
            "blue over red on the books rose \(byMap.booksCool) against \(even.booksCool)",
        )
        // The veil is cooler than the grey wall it lies over; the even blend's grey leaves it grey.
        #expect(byMap.wallCool > 0.01, "blue over red changed by \(byMap.wallCool)")
        #expect(abs(even.wallCool) < 0.005, "blue over red changed by \(even.wallCool) under the even blend")
    }
}
