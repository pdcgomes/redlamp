import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampMasking

/// A removed thing's shadow and reflection (RM-13).
struct RemovalRegionTests {
    /// An sRGB image of `color(x, y)` (0...1 encoded).
    private func image(width: Int, height: Int, color: (Int, Int) -> SIMD3<Float>) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let c = color(x, y)
                for channel in 0 ..< 3 {
                    bytes[(y * width + x) * 4 + channel] = UInt8(min(max(c[channel], 0), 1) * 255)
                }
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        return try #require(context.makeImage())
    }

    private func mask(width: Int, height: Int, _ inside: (Int, Int) -> Bool) -> GrayMask {
        GrayMask(width: width, height: height, pixels: (0 ..< width * height).map {
            inside($0 % width, $0 / width) ? 255 : 0
        })
    }

    private func share(_ mask: GrayMask, where region: (Int, Int) -> Bool) -> Double {
        var (covered, total) = (0, 0)
        for y in 0 ..< mask.height {
            for x in 0 ..< mask.width where region(x, y) {
                total += 1
                covered += mask[x, y] > 127 ? 1 : 0
            }
        }
        return Double(covered) / Double(max(total, 1))
    }

    /// A thing as wide as a car, with its shadow on the ground beside its base, a quarter of its
    /// width beyond it.
    @Test func `a shadow beside the thing goes with it, and the ground around stays`() throws {
        let (width, height) = (120, 80)
        let thing = { (x: Int, y: Int) in (30 ... 69).contains(x) && (30 ... 49).contains(y) }
        let shade = { (x: Int, y: Int) in (70 ... 79).contains(x) && (44 ... 54).contains(y) }
        let photo = try image(width: width, height: height) { x, y in
            thing(x, y) ? SIMD3(0.9, 0.15, 0.1) : shade(x, y) ? SIMD3(repeating: 0.28) : SIMD3(repeating: 0.5)
        }
        let extended = RemovalRegion.extended(mask(width: width, height: height, thing), image: photo)
        #expect(extended.shadow && !extended.reflection)
        #expect(share(extended.mask, where: shade) > 0.8)
        #expect(share(extended.mask) { !thing($0, $1) && !shade($0, $1) } < 0.05)
        #expect(share(extended.mask, where: thing) == 1)
    }

    @Test func `a reflection below the thing on water goes with it, and plain water stays`() throws {
        let (width, height) = (100, 120)
        let boat = { (x: Int, y: Int) in (30 ... 70).contains(x) && (30 ... 59).contains(y) }
        let mirrored = { (x: Int, y: Int) in (30 ... 70).contains(x) && (60 ... 89).contains(y) }
        let stripe = { (x: Int, y: Int) -> Float in Float((x / 4 + y / 6) % 3) * 0.3 + 0.2 }
        func scene(reflected: Bool) throws -> CGImage {
            try image(width: width, height: height) { x, y in
                if boat(x, y) {
                    return SIMD3(repeating: stripe(x, y))
                }
                if y >= 60 {
                    if reflected, mirrored(x, y) {
                        return SIMD3(repeating: stripe(x, 119 - y) * 0.8) + SIMD3(0, 0.02, 0.04)
                    }
                    return SIMD3(0.12, 0.18, 0.24)
                }
                return SIMD3(0.55, 0.6, 0.65)
            }
        }
        let thing = mask(width: width, height: height, boat)
        let reflected = try RemovalRegion.extended(thing, image: scene(reflected: true))
        #expect(reflected.reflection)
        #expect(share(reflected.mask, where: mirrored) > 0.8)
        let plain = try RemovalRegion.extended(thing, image: scene(reflected: false))
        #expect(!plain.reflection)
        #expect(share(plain.mask, where: mirrored) < 0.05)
    }
}
