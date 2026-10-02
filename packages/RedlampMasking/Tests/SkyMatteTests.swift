import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampMasking

struct SkyMatteTests {
    static let sky: (UInt8, UInt8, UInt8) = (110, 160, 235)
    static let bark: (UInt8, UInt8, UInt8) = (45, 38, 30)

    private func image(width: Int, height: Int, _ colour: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                (pixels[index], pixels[index + 1], pixels[index + 2]) = colour(x, y)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        ))
    }

    /// Mixed in linear light, encoded back to sRGB, as a lens would mix a thin twig with the sky.
    private func mix(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), _ share: Float) -> (UInt8, UInt8, UInt8) {
        func linear(_ v: UInt8) -> Float {
            let x = Float(v) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        func encoded(_ v: Float) -> UInt8 {
            UInt8((v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
        }
        func channel(_ x: UInt8, _ y: UInt8) -> UInt8 {
            encoded(share * linear(x) + (1 - share) * linear(y))
        }
        return (channel(a.0, b.0), channel(a.1, b.1), channel(a.2, b.2))
    }

    /// Ground below, sky above; a one-pixel twig and a column half covered by a thinner one,
    /// rising out of the ground. The coarse mask, as a model at a quarter of the size would give
    /// it, knows neither.
    @Test func `a one pixel twig keeps out of the sky; a half covered pixel is half sky`() throws {
        let width = 400
        let height = 300
        let photo = try image(width: width, height: height) { x, y in
            if y >= 220 {
                return Self.bark
            }
            if x == 200, y >= 100 {
                return Self.bark
            }
            if x == 240, y >= 100 {
                return mix(Self.bark, Self.sky, 0.5)
            }
            return Self.sky
        }
        let coarse = GrayMask(width: width / 4, height: height / 4, pixels: (0 ..< width * height / 16).map {
            $0 / (width / 4) < 55 ? 255 : 0
        })
        let matte = SkyMatte.refine(coarse, image: photo)
        #expect(matte.width == width && matte.height == height)
        #expect(matte[200, 180] < 60, "the twig: \(matte[200, 180])")
        #expect(matte[203, 180] > 220, "the sky beside it: \(matte[203, 180])")
        #expect(abs(Int(matte[240, 180]) - 128) < 40, "half covered: \(matte[240, 180])")
        #expect(matte[200, 260] < 20, "the ground: \(matte[200, 260])")
    }

    /// The coarse mask cut a whole crown out; inside it, branches every 8 px with sky between.
    @Test func `sky comes back inside a crown the coarse mask cut out`() throws {
        let width = 400
        let height = 300
        let crown = (x: 185 ..< 215, y: 110 ..< 140)
        let photo = try image(width: width, height: height) { x, y in
            if y >= 230 {
                return Self.bark
            }
            if crown.x.contains(x), crown.y.contains(y), x % 8 == 0 || y == 139 {
                return Self.bark
            }
            return Self.sky
        }
        let coarse = GrayMask(width: width, height: height, pixels: (0 ..< width * height).map { index in
            let x = index % width
            let y = index / width
            return y < 230 && !(crown.x.contains(x) && crown.y.contains(y)) ? 255 : 0
        })
        let matte = SkyMatte.refine(coarse, image: photo)
        #expect(matte[196, 125] > 200, "sky between branches: \(matte[196, 125])")
        #expect(matte[200, 125] < 60, "a branch: \(matte[200, 125])")
        #expect(matte[200, 260] < 20, "the ground: \(matte[200, 260])")
    }

    /// A foreground the colour of the sky can't be told from it: the coarse mask stays.
    @Test func `where sky and foreground look alike, the coarse mask stays`() throws {
        let width = 200
        let height = 150
        let photo = try image(width: width, height: height) { _, _ in Self.sky }
        let coarse = GrayMask(width: width, height: height, pixels: (0 ..< width * height).map {
            $0 / width < 75 ? 255 : 0
        })
        let matte = SkyMatte.refine(coarse, image: photo)
        #expect(matte == coarse)
    }

    @Test func `arbitration averages agreeing skies and drops one that missed`() {
        func mask(rows: Int) -> GrayMask {
            GrayMask(width: 10, height: 10, pixels: (0 ..< 100).map { $0 / 10 < rows ? 255 : 0 })
        }
        let mean = SkyEstimator.arbitrate(mask(rows: 4), mask(rows: 6))
        #expect(mean[0, 3] == 255 && mean[0, 4] == 127 && mean[0, 6] == 0)
        #expect(SkyEstimator.arbitrate(mask(rows: 6), mask(rows: 1)) == mask(rows: 6))
        #expect(SkyEstimator.arbitrate(mask(rows: 1), mask(rows: 6)) == mask(rows: 6))
    }
}
