import CoreGraphics
import Foundation
import ImageIO
import RedlampEngine
import RedlampEngineAPI
import Testing
import UniformTypeIdentifiers

/// Halation, bloom and colour grain.
struct FilmEffectsTests {
    static let size = 256

    /// A 16-bit sRGB image: `background` everywhere, with a white disc of `radius` in the middle.
    static func image(background: Double, radius: Double) throws -> URL {
        var words = [UInt16](repeating: 65535, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let distance = hypot(Double(x) - Double(size) / 2, Double(y) - Double(size) / 2)
                let value = distance < radius ? 1.0 : background
                let o = (y * size + x) * 4
                for c in 0 ..< 3 {
                    words[o + c] = UInt16(value * 65535)
                }
            }
        }
        let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = try #require(CGImage(
            width: size, height: size, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: size * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGImageByteOrderInfo
                .order16Little.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent,
        ))
        let url = FileManager.default.temporaryDirectory.appending(path: "redlamp-glow-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil,
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func render(_ url: URL, _ values: [ParameterID: Double]) async throws -> [UInt8] {
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        var recipe = EditRecipe()
        for (parameter, value) in values {
            recipe[parameter] = value
        }
        return try await BaseLookTests.pixels(engine.renderStill(StillRequest(recipe: recipe)))
    }

    /// Mean red, green, blue over a ring of the image.
    static func ring(_ pixels: [UInt8], from inner: Double, to outer: Double) -> SIMD3<Double> {
        var sum = SIMD3<Double>.zero
        var count = 0.0
        for y in 0 ..< size {
            for x in 0 ..< size {
                let distance = hypot(Double(x) - Double(size) / 2, Double(y) - Double(size) / 2)
                guard distance >= inner, distance < outer else { continue }
                let o = (y * size + x) * 4
                sum += SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2]))
                count += 1
            }
        }
        return sum / count
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `halation glows red around a bright light, far less in green and blue`() async throws {
        let url = try Self.image(background: 0.03, radius: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try await Self.ring(Self.render(url, [:]), from: 12, to: 30)
        let glowing = try await Self.ring(Self.render(url, [.halationAmount: 80]), from: 12, to: 30)
        let lift = glowing - plain
        #expect(lift.x > 8, "red lifted by \(lift.x)")
        // Gamut mapping the glow's Rec. 2020 red into sRGB moves green and blue a little.
        #expect(abs(lift.y) < 0.3 * lift.x, "red \(lift.x) against green \(lift.y)")
        #expect(abs(lift.z) < 0.3 * lift.x, "red \(lift.x) against blue \(lift.z)")
        let far = try await Self.ring(Self.render(url, [.halationAmount: 80]), from: 110, to: 128)
            - Self.ring(Self.render(url, [:]), from: 110, to: 128)
        #expect(far.x < 0.25 * lift.x, "the glow reaches the edge: \(far)")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `bloom lifts every colour around a bright light`() async throws {
        let url = try Self.image(background: 0.03, radius: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try await Self.ring(Self.render(url, [:]), from: 12, to: 40)
        let lift = try await Self.ring(Self.render(url, [.bloomAmount: 80]), from: 12, to: 40) - plain
        #expect(lift.min() > 3, "lifted by \(lift)")
        #expect(lift.max() - lift.min() < 0.35 * lift.max(), "uneven lift \(lift)")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `an evenly bright frame keeps its colour under halation and bloom`() async throws {
        let url = try Self.image(background: 0.95, radius: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try await Self.ring(Self.render(url, [:]), from: 0, to: 100)
        let glowing = try await Self.ring(Self.render(url, [.halationAmount: 100, .bloomAmount: 100]), from: 0, to: 100)
        #expect(abs(glowing.x - glowing.z) < 2, "tinted \(glowing)")
        #expect(abs(glowing.y - plain.y) < 6, "brightness \(plain) → \(glowing)")
    }

    /// The standard deviation of the green channel, in 8-bit levels.
    static func noise(_ pixels: [UInt8]) -> Double {
        let values = stride(from: 1, to: pixels.count, by: 4).map { Double(pixels[$0]) }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    /// A flat grey frame `size` pixels square.
    static func flat(_ value: Double, size: Int) throws -> URL {
        var words = [UInt16](repeating: 65535, count: size * size * 4)
        for i in 0 ..< size * size {
            for c in 0 ..< 3 {
                words[i * 4 + c] = UInt16(value * 65535)
            }
        }
        let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = try #require(CGImage(
            width: size, height: size, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: size * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGImageByteOrderInfo
                .order16Little.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent,
        ))
        let url = FileManager.default.temporaryDirectory.appending(path: "redlamp-flat-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil,
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `a downscaled preview shows the grain a downscaled export has`() async throws {
        let url = try Self.flat(0.45, size: 2048)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        var recipe = EditRecipe()
        recipe[.grainAmount] = 80
        recipe[.grainSize] = 100
        func render(_ purpose: StillPurpose) async throws -> Double {
            let image = try await engine.renderStill(StillRequest(recipe: recipe, maxLongEdge: 256, purpose: purpose))
            return Self.noise(BaseLookTests.pixels(image))
        }
        let preview = try await render(.preview)
        let export = try await render(.export)
        #expect(export > 0.2, "the export has no grain: \(export)")
        #expect(abs(preview - export) < 0.5 * export, "preview \(preview) against export \(export)")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `process 2 grain shows most in the shadows; process 1's is even`() async throws {
        func noise(_ value: Double, process: Int) async throws -> Double {
            let url = try Self.flat(value, size: 256)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = try RedlampEngine()
            _ = try await engine.open(url)
            var recipe = EditRecipe()
            recipe.processVersion = process
            recipe[.grainAmount] = 60
            return try await Self.noise(BaseLookTests.pixels(engine.renderStill(StillRequest(recipe: recipe))))
        }
        let film = try await noise(0.25, process: 2) / noise(0.85, process: 2)
        let even = try await noise(0.25, process: 1) / noise(0.85, process: 1)
        #expect(film > 1.5 * even, "shadow to highlight grain: process 2 \(film), process 1 \(even)")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `process 3 shows a bitmap as the file at default settings; process 2 still tone-maps it`() async throws {
        let url = try BaseLookTests.chart()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        })
        let file = BaseLookTests.pixels(source)
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        func difference(process: Int) async throws -> (mean: Double, max: Int) {
            var recipe = EditRecipe()
            recipe.processVersion = process
            let rendered = try await BaseLookTests.pixels(engine.renderStill(StillRequest(recipe: recipe)))
            let differences = zip(file, rendered).enumerated().filter { $0.offset % 4 != 3 }
                .map { abs(Int($0.element.0) - Int($0.element.1)) }
            return (Double(differences.reduce(0, +)) / Double(differences.count), differences.max() ?? 0)
        }
        let asFile = try await difference(process: 3)
        let toneMapped = try await difference(process: 2)
        #expect(asFile.mean < 0.5 && asFile.max <= 3, "process 3 against the file: \(asFile)")
        #expect(toneMapped.mean > 3, "process 2 should still tone-map: \(toneMapped)")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `process 3 halation boosts a small light, not a clipped sky`() async throws {
        // A clipped band across the top (a sky) and, below it, a small clipped light.
        let size = Self.size
        var words = [UInt16](repeating: 65535, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let light = hypot(Double(x) - 128, Double(y) - 190) < 5
                let value = y < 90 || light ? 1.0 : 0.03
                for c in 0 ..< 3 {
                    words[(y * size + x) * 4 + c] = UInt16(value * 65535)
                }
            }
        }
        let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = try #require(CGImage(
            width: size, height: size, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: size * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGImageByteOrderInfo
                .order16Little.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent,
        ))
        let url = FileManager.default.temporaryDirectory.appending(path: "redlamp-sky-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        defer { try? FileManager.default.removeItem(at: url) }

        /// The red lift from halation in a band of rows.
        func lift(process: Int, rows: Range<Int>) async throws -> Double {
            let engine = try RedlampEngine()
            _ = try await engine.open(url)
            var plain = EditRecipe()
            plain.processVersion = process
            var glowing = plain
            glowing[.halationAmount] = 80
            let a = try await BaseLookTests.pixels(engine.renderStill(StillRequest(recipe: plain)))
            let b = try await BaseLookTests.pixels(engine.renderStill(StillRequest(recipe: glowing)))
            var total = 0.0
            for y in rows {
                for x in 40 ..< 216 where hypot(Double(x) - 128, Double(y) - 190) > 8 {
                    total += Double(b[(y * size + x) * 4]) - Double(a[(y * size + x) * 4])
                }
            }
            return total / Double(rows.count * 176)
        }
        let skyEdge = 92 ..< 110
        let skyBefore = try await lift(process: 2, rows: skyEdge)
        let skyNow = try await lift(process: 3, rows: skyEdge)
        let lightNow = try await lift(process: 3, rows: 180 ..< 200)
        #expect(skyNow < 0.5 * skyBefore, "red lift under the sky: process 2 \(skyBefore), process 3 \(skyNow)")
        #expect(lightNow > 2, "the small light still glows: \(lightNow)")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `mood effects: frames paint the edges, leaks warm them, dust adds a few specks`() async throws {
        let url = try Self.flat(0.45, size: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        func render(_ values: [ParameterID: Double]) async throws -> [UInt8] {
            var recipe = EditRecipe()
            for (parameter, value) in values {
                recipe[parameter] = value
            }
            return try await BaseLookTests.pixels(engine.renderStill(StillRequest(recipe: recipe)))
        }
        func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int) -> SIMD3<Int> {
            let o = (y * 600 + x) * 4
            return SIMD3(Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2]))
        }
        let plain = try await render([:])
        let centre = pixel(plain, 300, 300)

        let border = try await render([.frameStyle: Double(FrameStyle.printBorder.rawValue)])
        #expect(pixel(border, 3, 300).x > 230, "print border edge: \(pixel(border, 3, 300))")
        #expect(pixel(border, 300, 300) == centre)
        let rebate = try await render([.frameStyle: Double(FrameStyle.filmRebate.rawValue)])
        // The holes' centre row: half of the rebate band (0.13 of the frame's height) from the edge.
        let band = (0 ..< 600).map { pixel(rebate, $0, 39).x }
        #expect(band.min() ?? 255 < 20 && band.max() ?? 0 > 200, "rebate band has black film and lit sprocket holes")
        #expect(pixel(rebate, 300, 300) == centre)

        let leak = try await render([.leakAmount: 90, .leakWarmth: 100])
        var edge = SIMD3<Int>.zero
        for i in 0 ..< 600 {
            for sample in [pixel(leak, 4, i), pixel(leak, 595, i), pixel(leak, i, 4), pixel(leak, i, 595)]
                where sample.x - sample.z > edge.x - edge.z {
                edge = sample
            }
        }
        #expect(edge.x - edge.z > 40, "a warm leak at the edge: \(edge)")
        #expect(abs(pixel(leak, 300, 300).x - centre.x) < 25, "the middle barely changes: \(pixel(leak, 300, 300))")

        let dusty = try await render([.dustAmount: 100])
        let specks = zip(stride(from: 0, to: plain.count, by: 4), stride(from: 0, to: dusty.count, by: 4))
            .count { abs(Int(plain[$0.0 + 1]) - Int(dusty[$0.1 + 1])) > 30 }
        let share = Double(specks) / Double(600 * 600)
        #expect(share > 0.0005 && share < 0.05, "dust covers \(share) of the frame")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `colour grain differs between the layers; monochrome grain doesn't`() async throws {
        // Large enough that frame-sized grain is bigger than a pixel.
        let url = try Self.flat(0.45, size: 1536)
        defer { try? FileManager.default.removeItem(at: url) }
        func spread(_ pixels: [UInt8]) -> Double {
            var total = 0
            for o in stride(from: 0, to: pixels.count, by: 4) {
                total += abs(Int(pixels[o]) - Int(pixels[o + 2]))
            }
            return Double(total) / Double(pixels.count / 4)
        }
        let mono = try await spread(Self.render(url, [.grainAmount: 60, .grainSize: 100]))
        let color = try await spread(Self.render(url, [.grainAmount: 60, .grainSize: 100, .grainColor: 100]))
        #expect(mono < 1.5, "monochrome grain spread \(mono)")
        #expect(color > 3 * max(mono, 0.5), "colour grain spread \(color) against \(mono)")
    }
}
