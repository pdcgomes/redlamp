import CoreGraphics
import CoreVideo
import Testing
@testable import RedlampMasking

/// Things named in words (RM-08): the parts of OWLv2's detector that need no model.
struct OWLv2DetectorTests {
    @Test func `boxes overlapping a more certain one go, and boxes elsewhere stay`() {
        let car = OWLv2Detector.Detection(
            thing: "car",
            score: 0.8,
            box: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
        )
        let again = OWLv2Detector.Detection(
            thing: "car", score: 0.5, box: CGRect(x: 0.12, y: 0.1, width: 0.4, height: 0.42),
        )
        let other = OWLv2Detector.Detection(
            thing: "car", score: 0.6, box: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2),
        )
        #expect(OWLv2Detector.distinct([again, car, other], overlap: OWLv2Detector.sameThing) == [car, other])
    }

    @Test func `overlap is the intersection over the union`() {
        let box = CGRect(x: 0, y: 0, width: 2, height: 1)
        #expect(OWLv2Detector.intersectionOverUnion(box, box) == 1)
        #expect(OWLv2Detector.intersectionOverUnion(box, CGRect(x: 3, y: 0, width: 1, height: 1)) == 0)
        #expect(abs(OWLv2Detector.intersectionOverUnion(box, CGRect(x: 1, y: 0, width: 2, height: 1)) - 1 / 3) < 1e-12)
    }

    @Test func `the photo sits at the top left of a grey square, filling its width`() throws {
        let (width, height) = (200, 100)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = try OWLv2Detector.square(#require(context.makeImage()))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        /// Red, green and blue at (x, y).
        func pixel(_ x: Int, _ y: Int) -> SIMD3<Int> {
            let at = y * row + x * 4
            return SIMD3(Int(base[at + 2]), Int(base[at + 1]), Int(base[at]))
        }
        let size = OWLv2Detector.inputSize
        #expect(CVPixelBufferGetWidth(buffer) == size && CVPixelBufferGetHeight(buffer) == size)
        let photo = pixel(size / 2, size / 4)
        #expect(photo.x > 250 && photo.y < 5 && photo.z < 5, "\(photo)")
        let padding = pixel(size / 2, size * 3 / 4)
        #expect(padding.min() >= 127 && padding.max() <= 129, "\(padding)")
    }
}
