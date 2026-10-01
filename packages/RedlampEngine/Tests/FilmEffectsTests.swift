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

    @Test(.enabled(if: BaseLookTests.canRender))
    func `colour grain differs between the layers; monochrome grain doesn't`() async throws {
        let url = try Self.image(background: 0.45, radius: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        func spread(_ pixels: [UInt8]) -> Double {
            var total = 0
            for o in stride(from: 0, to: pixels.count, by: 4) {
                total += abs(Int(pixels[o]) - Int(pixels[o + 2]))
            }
            return Double(total) / Double(pixels.count / 4)
        }
        let mono = try await spread(Self.render(url, [.grainAmount: 60]))
        let color = try await spread(Self.render(url, [.grainAmount: 60, .grainColor: 100]))
        #expect(mono < 1.5, "monochrome grain spread \(mono)")
        #expect(color > 3 * max(mono, 0.5), "colour grain spread \(color) against \(mono)")
    }
}
