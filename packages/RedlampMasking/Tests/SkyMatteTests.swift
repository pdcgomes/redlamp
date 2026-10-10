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

    /// A leaning trunk 20 px wide, its edges blurred as a lens blurs them (sigma 0.8 px), so the
    /// pixels just inside it hold a little sky. The trunk's colour learnt from those holds some
    /// too, and every pixel at its edge would come out less sky than it is.
    @Test func `pixels at a trunk's blurred edge are as much sky as they are`() throws {
        let (width, height, ground) = (400, 300, 220)
        func trunk(_ x: Int, _ y: Int) -> Float {
            guard y < ground else { return 1 }
            guard y >= 40 else { return 0 }
            let left = 178 + 0.02 * Double(y)
            let spread = 0.8 * 2.squareRoot()
            let share = (0 ..< 8).map { sample in
                let u = Double(x) + (Double(sample) + 0.5) / 8
                return (erf((u - left) / spread) - erf((u - left - 20) / spread)) / 2
            }
            return Float(share.reduce(0, +) / 8)
        }
        let photo = try image(width: width, height: height) { x, y in mix(Self.bark, Self.sky, trunk(x, y)) }
        let coarse = GrayMask(width: width / 4, height: height / 4, pixels: (0 ..< width * height / 16).map { index in
            trunk(index % (width / 4) * 4 + 2, index / (width / 4) * 4 + 2) > 0.5 ? 0 : 255
        })
        let matte = SkyMatte.refine(coarse, image: photo)
        var errors: [Float] = []
        for y in 60 ..< 200 {
            for x in 170 ..< 210 {
                let sky = 1 - trunk(x, y)
                if sky > 0.15, sky < 0.5 {
                    errors.append(Float(matte[x, y]) / 255 - sky)
                }
            }
        }
        let bias = errors.reduce(0, +) / Float(errors.count)
        #expect(abs(bias) < 0.015, "pixels mostly trunk come out \(bias) off in sky, over \(errors.count)")
    }

    /// A soft coarse mask leaves a few percent of sky over the ground, which a sky edit would
    /// darken. Far from the edge, dark ground loses it; ground the colour of the sky, which the
    /// colour can't tell from it, keeps it.
    @Test func `the coarse mask's few percent of sky leave dark ground but stay on ground like the sky`() throws {
        let (width, height, horizon) = (400, 300, 100)
        let photo = try image(width: width, height: height) { x, y in
            y < horizon || x >= 200 ? Self.sky : Self.bark
        }
        let coarse = GrayMask(width: width / 4, height: height / 4, pixels: (0 ..< width * height / 16).map {
            $0 / (width / 4) < horizon / 4 ? 255 : 10
        })
        let matte = SkyMatte.refine(coarse, image: photo)
        #expect(matte[100, 280] == 0, "dark ground far below the sky: \(matte[100, 280])")
        #expect(matte[300, 280] == 10, "ground like the sky: \(matte[300, 280])")
        #expect(matte[100, 20] == 255 && matte[300, 20] == 255, "the sky: \(matte[100, 20]), \(matte[300, 20])")
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
