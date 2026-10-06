import CoreGraphics
import RedlampEngineAPI
import Testing
@testable import RedlampMasking

/// Face Skin from landmarks: its forehead grows up to the hairline through the face's own colour.
struct FacePartsTests {
    private static let width = 200
    private static let height = 300
    private static let skin = SIMD3<Float>(0.8, 0.6, 0.5)
    private static let hair = SIMD3<Float>(0.15, 0.12, 0.1)
    private static let background = SIMD3<Float>(0.2, 0.3, 0.6)

    /// A face in image points (bottom-left origin): temples at 130, brows' top at 145, the chin at 30,
    /// so the forehead's dome reaches 237 (63 from the top). The band the outline closes with ends
    /// at 163 (137 from the top).
    private let face = FaceParts.Face(
        size: PixelSize(width: width, height: height),
        contour: [
            CGPoint(x: 55, y: 130), CGPoint(x: 60, y: 90), CGPoint(x: 75, y: 55), CGPoint(x: 100, y: 30),
            CGPoint(x: 125, y: 55), CGPoint(x: 140, y: 90), CGPoint(x: 145, y: 130),
        ],
        eyes: [
            [CGPoint(x: 65, y: 125), CGPoint(x: 85, y: 125), CGPoint(x: 75, y: 130)],
            [CGPoint(x: 115, y: 125), CGPoint(x: 135, y: 125), CGPoint(x: 125, y: 130)],
        ],
        pupils: [],
        brows: [[CGPoint(x: 65, y: 140), CGPoint(x: 85, y: 145)], [CGPoint(x: 115, y: 145), CGPoint(x: 135, y: 140)]],
        outerLips: [CGPoint(x: 85, y: 60), CGPoint(x: 115, y: 60), CGPoint(x: 100, y: 50)],
        innerLips: [],
    )

    /// The head from 50 to 150 across, skin up to `hairline` (from the top) and `above` beyond it.
    private func photo(
        hairline: Int, above: SIMD3<Float> = hair, patch: (CGRect, SIMD3<Float>)? = nil,
    ) -> RGBImage {
        var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        for y in 0 ..< Self.height {
            for x in 0 ..< Self.width {
                var colour = (50 ..< 150).contains(x) && y < 290 ? (y < hairline ? above : Self.skin) : Self.background
                if let patch, patch.0.contains(CGPoint(x: x, y: y)) {
                    colour = patch.1
                }
                let index = (y * Self.width + x) * 4
                bytes[index] = UInt8(colour.x * 255)
                bytes[index + 1] = UInt8(colour.y * 255)
                bytes[index + 2] = UInt8(colour.z * 255)
            }
        }
        return RGBImage(width: Self.width, height: Self.height, pixels: bytes)
    }

    private func covered(_ mask: GrayMask, _ x: Int, _ top: Int) -> Bool {
        mask.pixels[top * Self.width + x] > 127
    }

    @Test func `the forehead reaches the hairline, and stops at the hair`() throws {
        let mask = try #require(face.skin(people: nil, pixels: photo(hairline: 100)))
        #expect(covered(mask, 100, 110), "the forehead above the band the outline closes with")
        #expect(covered(mask, 70, 102), "up to the hairline, across the forehead")
        #expect(!covered(mask, 100, 95), "not the hair")
        #expect(covered(mask, 100, 200), "and the face below the brows, as before")
        #expect(!covered(mask, 75, 174), "not the eyes")
    }

    @Test func `without the photo's pixels, the forehead is the band above the brows`() throws {
        let mask = try #require(face.skin(people: nil, pixels: nil))
        #expect(covered(mask, 100, 140))
        #expect(!covered(mask, 100, 120))
    }

    @Test func `a bald head's skin keeps going up to the dome`() throws {
        let mask = try #require(face.skin(people: nil, pixels: photo(hairline: 0)))
        #expect(covered(mask, 100, 70), "most of the way up")
        #expect(!covered(mask, 100, 55), "but not past the dome's top, four fifths of the brows' height")
    }

    @Test func `a highlight in the forehead leaves no hole, and skin beyond the hair isn't taken`() throws {
        let highlight = (CGRect(x: 95, y: 115, width: 8, height: 6), SIMD3<Float>(1, 1, 1))
        let mask = try #require(face.skin(people: nil, pixels: photo(hairline: 100, patch: highlight)))
        #expect(covered(mask, 98, 117), "the highlight is filled in")

        let hand = (CGRect(x: 90, y: 68, width: 20, height: 12), Self.skin)
        let apart = try #require(face.skin(people: nil, pixels: photo(hairline: 100, patch: hand)))
        #expect(!covered(apart, 100, 74), "a skin-coloured patch the hair cuts off")
    }
}
