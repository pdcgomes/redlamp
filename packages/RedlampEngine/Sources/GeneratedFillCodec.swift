import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import UniformTypeIdentifiers

/// A generative fill's pixels as the edit keeps them (`GeneratedFill.bitmap`): the photo's linear
/// camera RGB divided by its peak and square-rooted, so 16 bits keep the shadows' precision, in a
/// 16-bit RGB PNG. Both ways skip colour management: the values aren't colours in any space it knows.
enum GeneratedFillCodec {
    /// The PNG of `rgb` (`width` × `height` × 3, linear camera RGB) and the peak it's scaled by.
    static func encode(_ rgb: [Float], width: Int, height: Int) throws -> (png: Data, peak: Double) {
        let peak = max(Double(rgb.max() ?? 0) * 1.0001, 1e-6)
        var words = [UInt16](repeating: 0, count: width * height * 4)
        for index in 0 ..< width * height {
            for channel in 0 ..< 3 {
                let value = Double(max(rgb[index * 3 + channel], 0)) / peak
                words[index * 4 + channel] = UInt16((value.squareRoot() * 65535).rounded())
            }
            words[index * 4 + 3] = 65535
        }
        let data = words.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.genericRGBLinear),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                  space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                      | CGBitmapInfo.byteOrder16Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
              )
        else { throw EngineError.renderFailed("a generated fill couldn't be encoded") }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { throw EngineError.renderFailed("a generated fill couldn't be encoded") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw EngineError.renderFailed("a generated fill couldn't be encoded")
        }
        return (out as Data, peak)
    }

    /// The stored values (0…1, before squaring and scaling by the peak), RGBA, row by row.
    static func decode(_ png: Data) -> (values: [Float], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let (width, height) = (image.width, image.height)
        // The context takes the image's own colour space, so drawing converts nothing.
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.genericRGBLinear),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue,
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { return nil }
        let words = pixels.bindMemory(to: UInt16.self, capacity: width * height * 4)
        var values = [Float](repeating: 1, count: width * height * 4)
        for index in 0 ..< width * height * 4 where index % 4 != 3 {
            values[index] = Float(words[index]) / 65535
        }
        return (values, width, height)
    }
}
