import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampMasking

struct ClosedFormMatteTests {
    private func image(width: Int, height: Int, _ colour: (Int, Int) -> SIMD3<Float>) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let value = colour(x, y)
                pixels[index] = UInt8(value.x * 255 + 0.5)
                pixels[index + 1] = UInt8(value.y * 255 + 0.5)
                pixels[index + 2] = UInt8(value.z * 255 + 0.5)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        ))
    }

    static let hair = SIMD3<Float>(0.15, 0.1, 0.08)
    static let wall = SIMD3<Float>(0.75, 0.8, 0.85)

    /// A dark subject on the left, a light wall on the right, one column half and half; the
    /// coarse mask is a soft ramp across the edge, as Vision gives it.
    @Test func `a mixed column comes out half covered, and the sides sure`() throws {
        let width = 400
        let height = 200
        let photo = try image(width: width, height: height) { x, _ in
            x < 200 ? Self.hair : x == 200 ? (Self.hair + Self.wall) / 2 : Self.wall
        }
        let coarse = GrayMask(width: width, height: height, coverage: (0 ..< width * height).map { index in
            min(max(Float(215 - index % width) / 30, 0), 1)
        })
        let matte = ClosedFormMatte.refine(coarse, image: photo)
        #expect(matte[190, 100] > 240, "subject: \(matte[190, 100])")
        #expect(matte[210, 100] < 15, "wall: \(matte[210, 100])")
        #expect(abs(Int(matte[200, 100]) - 128) < 30, "half: \(matte[200, 100])")
        #expect(matte[20, 100] == 255 && matte[380, 100] == 0, "sure pixels stay")
    }

    /// A coarse mask that is nowhere sure (a thin object Segment Anything is never confident of)
    /// has nothing to solve against, and stays as it was.
    @Test func `a mask sure of nothing stays as it was`() throws {
        let width = 200
        let height = 100
        let photo = try image(width: width, height: height) { x, _ in x < 100 ? Self.hair : Self.wall }
        let coarse = GrayMask(width: width, height: height, coverage: (0 ..< width * height).map { index in
            index % width < 100 ? 0.6 : 0.3
        })
        #expect(ClosedFormMatte.refine(coarse, image: photo) == coarse)
    }

    /// A dark head with a one-pixel strand reaching out over the wall, which the coarse mask
    /// doesn't have: the strand joins the subject; the wall beside it doesn't.
    @Test func `a strand the coarse mask missed comes back`() throws {
        let width = 400
        let height = 300
        let photo = try image(width: width, height: height) { x, y in
            let head = hypot(Float(x - 200), Float(y - 200)) < 80
            let strand = x == 200 && y >= 108 && y < 125
            return head || strand ? Self.hair : Self.wall
        }
        let coarse = GrayMask(width: width, height: height, coverage: (0 ..< width * height).map { index in
            let distance = hypot(Float(index % width - 200), Float(index / width - 200))
            return min(max((84 - distance) / 8, 0), 1)
        })
        let matte = ClosedFormMatte.refine(coarse, image: photo)
        // A one-pixel line in 3×3 windows comes out partly covered: well over half here.
        #expect(matte[200, 115] > 120, "the strand: \(matte[200, 115])")
        #expect(matte[204, 115] < 40, "the wall beside it: \(matte[204, 115])")
        #expect(matte[200, 200] == 255, "inside the head")
    }

    /// The Refine Edge brush: a mask whose edge is 30 pixels off the subject's is solved again
    /// under a stroke along the edge, and left as it was elsewhere. Where the stroke ends the old
    /// edge still holds, so a flat subject (no texture to stop it) is surest away from the end.
    @Test func `the refine edge brush solves the edge where it paints`() throws {
        let width = 300
        let height = 300
        let photo = try image(width: width, height: height) { x, _ in x < 150 ? Self.hair : Self.wall }
        let coarse = GrayMask(width: width, height: height, coverage: (0 ..< width * height).map { index in
            index % width < 120 ? 1 : 0
        })
        // Down the edge from above the photo to its middle.
        let stroke = BrushStroke(
            points: [ImagePoint(x: 0.45, y: -0.2), ImagePoint(x: 0.45, y: 0.5)], size: 0.1, feather: 0,
        )
        let matte = ClosedFormMatte.refine(coarse, image: photo, along: [stroke])
        #expect(matte[140, 20] > 230, "the subject under the stroke: \(matte[140, 20])")
        #expect(matte[160, 20] < 15, "the wall under the stroke: \(matte[160, 20])")
        #expect(matte[140, 280] == 0, "the same column below the stroke stays as it was")
        #expect(matte[20, 20] == 255 && matte[280, 20] == 0)
    }
}
