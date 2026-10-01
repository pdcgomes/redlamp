import CoreGraphics
import Foundation
import ImageIO
import Metal
import RedlampEngine
import RedlampEngineAPI
import Testing
import UniformTypeIdentifiers

/// The Base Look stage: tables render exactly as pinned, and cost next to nothing.
struct BaseLookTests {
    static let canRender = MTLCreateSystemDefaultDevice() != nil

    /// A 16-bit sRGB chart: a hue sweep over a brightness ramp.
    static func chart() throws -> URL {
        let width = 256, height = 128
        var words = [UInt16](repeating: 65535, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let h = Double(x) / Double(width) * 6
                let v = 0.1 + 0.85 * Double(y) / Double(height - 1)
                let f = h - floor(h)
                let rgb: (Double, Double, Double) = switch Int(h) % 6 {
                case 0: (1, f, 0)
                case 1: (1 - f, 1, 0)
                case 2: (0, 1, f)
                case 3: (0, 1 - f, 1)
                case 4: (f, 0, 1)
                default: (1, 0, 1 - f)
                }
                let o = (y * width + x) * 4
                words[o] = UInt16((0.3 + 0.7 * rgb.0) * v * 65535)
                words[o + 1] = UInt16((0.3 + 0.7 * rgb.1) * v * 65535)
                words[o + 2] = UInt16((0.3 + 0.7 * rgb.2) * v * 65535)
            }
        }
        let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGImageByteOrderInfo
                .order16Little.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent,
        ))
        let url = FileManager.default.temporaryDirectory.appending(path: "redlamp-lut-chart-\(UUID().uuidString).png")
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

    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    static func maxDifference(_ a: CGImage, _ b: CGImage) -> Int {
        zip(pixels(a), pixels(b)).enumerated().filter { $0.offset % 4 != 3 }
            .map { abs(Int($0.element.0) - Int($0.element.1)) }.max() ?? 0
    }

    private func render(_ engine: RedlampEngine, _ recipe: EditRecipe) async throws -> CGImage {
        try await engine.renderStill(StillRequest(recipe: recipe))
    }

    private func look(_ table: LookTable, id: String = "local/test/look") -> BaseLookDefinition {
        BaseLookDefinition(id: id, version: 1, name: "Test", parameters: .identity, table: table)
    }

    @Test(.enabled(if: canRender))
    func `an identity table changes nothing`() async throws {
        let url = try Self.chart()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let plain = try await render(engine, EditRecipe())
        let identity = look(LookTable.identity(size: 33))
        engine.registerBaseLook(identity)
        var recipe = EditRecipe()
        recipe.baseLook = identity.reference
        #expect(engine.canRender(recipe.baseLook))
        let looked = try await render(engine, recipe)
        #expect(Self.maxDifference(plain, looked) <= 2)
    }

    @Test(.enabled(if: canRender))
    func `a scene-referred table of Redlamp's own tone curve changes nothing, and Amount 0 turns it off`() async throws {
        let url = try Self.chart()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let plain = try await render(engine, EditRecipe())
        let table = try LookTable(size: 33, space: .sceneLog) { encoded in
            let display = RedlampToneCurve.apply(SceneLogEncoding.decode(encoded))
            return SIMD3(Self.srgbEncode(display.x), Self.srgbEncode(display.y), Self.srgbEncode(display.z))
        }
        let film = look(table, id: "local/test/scene")
        engine.registerBaseLook(film)
        var recipe = EditRecipe()
        recipe.baseLook = film.reference
        // Channels that land near zero at the edge of the sRGB gamut differ by a few levels:
        // the Rec.2020-to-sRGB step subtracts large values, magnifying interpolation error.
        let differences = try await zip(Self.pixels(plain), Self.pixels(render(engine, recipe))).enumerated()
            .filter { $0.offset % 4 != 3 }.map { abs(Int($0.element.0) - Int($0.element.1)) }.sorted()
        let mean = Double(differences.reduce(0, +)) / Double(differences.count)
        #expect(mean < 0.5)
        #expect(differences[differences.count * 99 / 100] <= 3)

        let dark = try look(LookTable(size: 9, space: .sceneLog) { _ in SIMD3(repeating: 0.2) }, id: "local/test/dark")
        engine.registerBaseLook(dark)
        recipe.baseLook = dark.reference
        let flat = try await Self.pixels(render(engine, recipe))
        #expect(flat.enumerated().filter { $0.offset % 4 != 3 }.allSatisfy { abs(Int($0.element) - 51) <= 3 })
        recipe.baseLook = dark.reference.withAmount(0)
        #expect(try await Self.maxDifference(plain, render(engine, recipe)) <= 1)
    }

    static func srgbEncode(_ x: Float) -> Float {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    @Test(.enabled(if: canRender))
    func `a table reaches every pixel, and Amount 0 turns it off`() async throws {
        let url = try Self.chart()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let grey = try look(LookTable(size: 9) { _ in SIMD3(repeating: 0.5) }, id: "local/test/grey")
        engine.registerBaseLook(grey)
        var recipe = EditRecipe()
        recipe.baseLook = grey.reference
        let flat = try await Self.pixels(render(engine, recipe))
        let channels = flat.enumerated().filter { $0.offset % 4 != 3 }.map { Int($0.element) }
        #expect(channels.allSatisfy { abs($0 - 128) <= 3 })

        recipe.baseLook = grey.reference.withAmount(0)
        let off = try await render(engine, recipe)
        #expect(try await Self.maxDifference(off, render(engine, EditRecipe())) <= 1)
    }

    @Test(.enabled(if: canRender))
    func `an unregistered or changed look renders without it`() async throws {
        let url = try Self.chart()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let grey = try look(LookTable(size: 9) { _ in SIMD3(repeating: 0.5) }, id: "local/test/grey")
        var recipe = EditRecipe()
        recipe.baseLook = grey.reference
        #expect(!engine.canRender(recipe.baseLook))
        let missing = try await render(engine, recipe)
        #expect(try await Self.maxDifference(missing, render(engine, EditRecipe())) <= 1)

        // The same id with a different table: the pinned hash no longer matches.
        engine.registerBaseLook(look(LookTable.identity(size: 9), id: "local/test/grey"))
        #expect(!engine.canRender(recipe.baseLook))
    }

    @Test(.enabled(if: canRender))
    func `camera recipe controls do what they say`() async throws {
        let url = try Self.chart()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        func means(_ recipe: EditRecipe) async throws -> (red: Double, luma: Double, top: Double) {
            let bytes = try await Self.pixels(render(engine, recipe))
            var red = 0.0, luma = 0.0
            var brightest: [Double] = []
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let l = 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
                red += Double(bytes[i])
                luma += l
                brightest.append(l)
            }
            let n = Double(bytes.count / 4)
            brightest.sort()
            let top = brightest.suffix(brightest.count / 10).reduce(0, +) / Double(brightest.count / 10)
            return (red / n, luma / n, top)
        }
        var bright = EditRecipe()
        bright[.exposure] = 2
        let base = try await means(bright)
        var headroom = bright
        headroom[.dynamicRange] = 400
        #expect(try await means(headroom).top < base.top - 2)

        var chrome = EditRecipe()
        chrome[.colorChrome] = 100
        #expect(try await means(chrome).luma < means(EditRecipe()).luma - 0.5)

        var warm = EditRecipe()
        warm[.wbShiftRed] = 100
        #expect(try await means(warm).red > means(EditRecipe()).red + 2)
    }

    /// Hosted CI runs on a virtual machine whose paravirtual GPU is several times slower.
    private static var isVirtualMachine: Bool {
        var present: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
    }

    @Test(.enabled(if: canRender))
    func `the table stage costs well under a millisecond`() async throws {
        // A real raw file at a Fit-sized render when one is downloaded; the chart otherwise.
        let chart = try Self.chart()
        defer { try? FileManager.default.removeItem(at: chart) }
        let engine = try RedlampEngine()
        _ = try await engine.open(EngineSmokeTests.fixtures.first ?? chart)
        let table = try LookTable(size: 33) { SIMD3($0.x * 0.9 + 0.05, $0.y * 0.95, $0.z) }
        let definition = look(table)
        engine.registerBaseLook(definition)
        var looked = EditRecipe()
        looked.baseLook = definition.reference

        func averageRender(_ recipe: EditRecipe) async throws -> Double {
            let frames = engine.frames()
            var iterator = frames.makeAsyncIterator()
            var total = 0.0
            let count = 30
            for i in 0 ..< count {
                var request = RenderRequest(
                    recipe: recipe,
                    targetSize: PixelSize(width: 1600, height: 1600),
                    generation: UInt64(i),
                )
                request.showClipping = false
                engine.render(request)
                let frame = try #require(await iterator.next())
                if i >= 5 {
                    total += Double(frame.renderDuration.components.attoseconds) / 1e15
                        + Double(frame.renderDuration.components.seconds) * 1000
                }
            }
            return total / Double(count - 5)
        }
        let without = try await averageRender(EditRecipe())
        let with = try await averageRender(looked)
        print(
            "Base Look table stage: \(String(format: "%.3f", without)) ms without, \(String(format: "%.3f", with)) ms with",
        )
        #expect(with - without < (Self.isVirtualMachine ? 5.0 : 1.0))
    }
}
