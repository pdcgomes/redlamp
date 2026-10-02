import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampMasking

struct GrayMaskTests {
    private func ramp(width: Int, height: Int) -> GrayMask {
        GrayMask(width: width, height: height, pixels: (0 ..< width * height).map { UInt8(($0 * 7) % 256) })
    }

    @Test func `round trips through PNG`() throws {
        let mask = ramp(width: 37, height: 21)
        let bitmap = try #require(mask.bitmap())
        #expect(bitmap.width == 37 && bitmap.height == 21)
        #expect(try bitmap.sha256 == MaskBitmap.hash(#require(bitmap.png)))
        #expect(try GrayMask.decode(#require(bitmap.png)) == mask)
    }

    /// A marker in the stored top-left corner lands where each EXIF orientation displays it.
    @Test(arguments: [(1, 0, 0), (3, 3, 1), (6, 1, 0), (8, 0, 3), (2, 3, 0), (4, 0, 1), (5, 0, 0), (7, 1, 3)])
    func `orients like EXIF`(orientation: Int, x: Int, y: Int) {
        var pixels = [UInt8](repeating: 0, count: 4 * 2)
        pixels[0] = 255
        let oriented = GrayMask(width: 4, height: 2, pixels: pixels).oriented(exif: orientation)
        #expect(oriented.width == (orientation >= 5 ? 2 : 4))
        #expect(oriented[x, y] == 255, "orientation \(orientation)")
    }

    /// Lightroom's Landscape classes don't overlap: where vegetation and natural ground both claim a
    /// pixel (a lawn), vegetation keeps it.
    @Test func `landscape classes are exclusive by precedence`() {
        let size = 2
        let classes = SAM3Concepts.exclusive([
            .naturalGround: [1, 1, 1, 0], .vegetation: [1, 0, 0, 0], .water: [0, 0, 0.5, 0],
        ], order: SAM3Concepts.precedence, size: size)
        #expect(classes[.vegetation]?.pixels == [255, 0, 0, 0])
        #expect(classes[.water]?.pixels == [0, 0, 128, 0])
        #expect(classes[.naturalGround]?.pixels == [0, 255, 128, 0])
        #expect(classes[.mountains] == nil)
    }

    /// A beard is facial hair, not hair, and a sleeve clothes, not skin.
    @Test func `people parts are exclusive by precedence`() {
        let parts = SAM3Concepts.exclusive([
            .hair: [1, 1, 0, 0], .facialHair: [0, 1, 0, 0], .bodySkin: [0, 0, 1, 1], .clothes: [0, 0, 0, 1],
        ], order: SAM3Concepts.partPrecedence, size: 2)
        #expect(parts[.facialHair]?.pixels == [0, 255, 0, 0])
        #expect(parts[.hair]?.pixels == [255, 0, 0, 0])
        #expect(parts[.clothes]?.pixels == [0, 0, 0, 255])
        #expect(parts[.bodySkin]?.pixels == [0, 0, 255, 0])
    }

    /// Beyond SAM 3's hair the person's matte is the hair's (stray strands), within reach and where
    /// SAM 3 sees none of the person's other parts.
    @Test func `a part's edge is the person's matte where it meets the background`() {
        func mask(_ values: [Range<Int>: UInt8]) -> GrayMask {
            GrayMask(
                width: 20,
                height: 1,
                pixels: (0 ..< 20).map { x in values.first { $0.key.contains(x) }?.value ?? 0 },
            )
        }
        let hair = mask([0 ..< 5: 255])
        let person = mask([0 ..< 5: 255, 5 ..< 14: 200])
        let skin = mask([7 ..< 8: 255])
        let edges = SAM3Concepts.edges(of: hair, others: skin, person: person, reach: 4)
        #expect(edges.pixels == [255, 255, 255, 255, 255, 200, 200, 0, 200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    /// Hair beyond either person's own mask goes to the nearer of the two, and only so far.
    @Test func `a part is cut between people by distance`() {
        let width = 10
        func person(_ columns: Range<Int>) -> GrayMask {
            GrayMask(width: width, height: 1, pixels: (0 ..< width).map { columns.contains($0) ? 255 : 0 })
        }
        let hair = GrayMask(width: width, height: 1, pixels: [UInt8](repeating: 200, count: width))
        let pieces = hair.split(among: [person(0 ..< 2), person(7 ..< 10)])
        #expect(pieces.count == 2)
        #expect(pieces[0].pixels == [200, 200, 200, 200, 200, 0, 0, 0, 0, 0])
        #expect(pieces[1].pixels == [0, 0, 0, 0, 0, 200, 200, 200, 200, 200])
        #expect(hair.split(among: [person(0 ..< 2)]) == [hair])
        // Someone else's beyond reach is no one's.
        #expect(hair.split(among: [person(0 ..< 2)], reach: 3)[0].pixels == [200, 200, 200, 200, 200, 0, 0, 0, 0, 0])
        let nobody = hair.split(among: [person(0 ..< 0), person(0 ..< 0)])
        #expect(nobody[0] == hair && nobody[1].coveredFraction == 0)
    }

    @Test func `combines like mask operations`() {
        let a = GrayMask(width: 2, height: 1, pixels: [255, 0])
        let b = GrayMask(width: 2, height: 1, pixels: [255, 255])
        #expect(a.union(b).pixels == [255, 255])
        #expect(a.intersection(b).pixels == [255, 0])
        #expect(b.subtracting(a).pixels == [0, 255])
        #expect(a.inverted.pixels == [0, 255])
    }

    @Test func `centroid and coverage`() {
        let mask = GrayMask(width: 4, height: 4, pixels: (0 ..< 16).map { $0 % 4 >= 2 ? 255 : 0 })
        #expect(abs(mask.coveredFraction - 0.5) < 1e-9)
        #expect(abs(mask.centroid.x - 0.75) < 1e-9)
        #expect(abs(mask.centroid.y - 0.5) < 1e-9)
    }

    @Test func `box blur keeps a constant and averages a step`() {
        let constant = [Float](repeating: 0.4, count: 50)
        #expect(BoxFilter.blur(constant, width: 10, height: 5, radius: 3).allSatisfy { abs($0 - 0.4) < 1e-5 })
        let step = (0 ..< 20).map { Float($0 < 10 ? 0 : 1) }
        let blurred = BoxFilter.blur(step, width: 20, height: 1, radius: 2)
        #expect(blurred[0] == 0 && blurred[19] == 1)
        #expect(abs(blurred[9] - 0.4) < 1e-5)
    }

    /// A blurry mask edge two pixels off the photo's edge snaps to it.
    @Test func `guided filter snaps edges to the guide`() {
        let width = 64
        let guide = (0 ..< width * 8).map { Float($0 % width < 32 ? 0.1 : 0.9) }
        let mask = (0 ..< width * 8).map { index -> Float in
            let x = Float(index % width)
            return min(max((x - 26) / 10, 0), 1)
        }
        let refined = GuidedFilter.filter(mask, guide: guide, width: width, height: 8, radius: 6, epsilon: 1e-4)
        let row = 4 * width
        #expect(refined[row + 28] < 0.25)
        #expect(refined[row + 35] > 0.75)
    }

    /// A sky with a bare crown (dark branches, open to the sky between them) that the mask cut
    /// around: the sky between the branches comes back, the branches and the ground don't. (Gaps
    /// branches close off completely stay out: the pass only grows from the sky.)
    @Test func `sky between bare branches comes back`() throws {
        let width = 400
        let height = 300
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var mask = [UInt8](repeating: 0, count: width * height)
        let crown = (x: 150 ..< 250, y: 60 ..< 180)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let ground = y >= 200
                let branch = crown.x.contains(x) && crown.y.contains(y) && x % 10 < 2
                let rgb: (UInt8, UInt8, UInt8) = ground ? (60, 110, 40) : branch ? (50, 40, 30) : (110, 160, 235)
                (pixels[index], pixels[index + 1], pixels[index + 2]) = rgb
                let insideCrown = crown.x.contains(x) && crown.y.contains(y)
                mask[y * width + x] = !ground && !insideCrown ? 255 : 0
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        ))
        let refined = SkyEstimator.refineBetweenBranches(
            GrayMask(width: width, height: height, pixels: mask),
            image: image,
        )
        #expect(refined[205, 125] > 200, "sky between branches")
        #expect(refined[200, 120] < 40, "a branch")
        #expect(refined[200, 250] < 40, "the ground")
    }

    /// Clear sky above, grass below: the estimate covers the sky and leaves the grass.
    @Test func `sky estimate finds a clear sky`() throws {
        let width = 600
        let height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 1
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                if y < 220 {
                    let t = Double(y) / 220
                    pixels[index] = UInt8(90 + 60 * t)
                    pixels[index + 1] = UInt8(150 + 50 * t)
                    pixels[index + 2] = UInt8(235)
                } else {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1
                    let noise = Int(seed >> 58)
                    pixels[index] = UInt8(40 + noise)
                    pixels[index + 1] = UInt8(110 + noise * 2)
                    pixels[index + 2] = UInt8(30 + noise)
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        ))
        let sky = try SkyEstimator.estimate(image).mask
        let skyRow = sky.height / 4
        let grassRow = sky.height * 7 / 8
        let mid = sky.width / 2
        #expect(sky[mid, skyRow] > 200)
        #expect(sky[mid, grassRow] < 40)
    }
}
