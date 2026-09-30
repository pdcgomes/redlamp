import CoreGraphics
import Foundation
import simd

/// An image as encoded RGB floats in 0...1, for measuring renders and references.
public struct PixelImage: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major RGB triples.
    public private(set) var pixels: [SIMD3<Float>]

    public init(width: Int, height: Int, pixels: [SIMD3<Float>]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Draws `image` into 16-bit RGB in `colorSpace` (sRGB when nil), optionally scaled so
    /// its long edge is at most `maxLongEdge`.
    public init?(_ image: CGImage, colorSpace: CGColorSpace? = nil, maxLongEdge: Int? = nil) {
        var width = image.width
        var height = image.height
        if let maxLongEdge, max(width, height) > maxLongEdge {
            let scale = Double(maxLongEdge) / Double(max(width, height))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
        }
        guard let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order16Little.rawValue,
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let words = data.bindMemory(to: UInt16.self, capacity: width * height * 4)
        var pixels = [SIMD3<Float>](repeating: .zero, count: width * height)
        for i in 0 ..< width * height {
            pixels[i] = SIMD3(Float(words[i * 4]), Float(words[i * 4 + 1]), Float(words[i * 4 + 2])) / 65535
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    public subscript(x: Int, y: Int) -> SIMD3<Float> {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// A 16-bit sRGB image of the pixels.
    public func cgImage() -> CGImage? {
        var words = [UInt16](repeating: 65535, count: width * height * 4)
        for (i, p) in pixels.enumerated() {
            let c = simd_clamp(p, .zero, SIMD3(repeating: 1)) * 65535
            words[i * 4] = UInt16(c.x.rounded())
            words[i * 4 + 1] = UInt16(c.y.rounded())
            words[i * 4 + 2] = UInt16(c.z.rounded())
        }
        return Self.makeImage16(words, width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func makeImage16(_ words: [UInt16], width: Int, height: Int, colorSpace: CGColorSpace?) -> CGImage? {
        guard let colorSpace else { return nil }
        let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGImageByteOrderInfo
                .order16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        )
    }
}
