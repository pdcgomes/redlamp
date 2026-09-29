import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI

/// Decodes JPEG, HEIC, PNG and TIFF files into linear sRGB float16 through ImageIO.
enum BitmapDecoder {
    static func decode(_ url: URL) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw EngineError.unsupportedFile(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exifOrientation = properties[kCGImagePropertyOrientation] as? Int ?? 1

        let width = image.width
        let height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 16,
                  bytesPerRow: width * 8,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.floatComponents.rawValue
                      | CGImageByteOrderInfo.order16Little.rawValue,
              )
        else {
            throw EngineError.decodeFailed("could not allocate a float bitmap")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw EngineError.decodeFailed("empty bitmap") }
        let samples = [UInt16](UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt16.self),
            count: width * height * 4,
        ))

        let orientation = switch exifOrientation {
        case 3: 3
        case 6: 6
        case 8: 5
        default: 0
        }
        let orientedSize = orientation == 5 || orientation == 6
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)

        let info = ImageInfo(
            url: url,
            pixelSize: orientedSize,
            isRaw: false,
            sensorDescription: url.pathExtension.uppercased(),
            make: tiff[kCGImagePropertyTIFFMake] as? String,
            model: tiff[kCGImagePropertyTIFFModel] as? String,
            lens: exif[kCGImagePropertyExifLensModel] as? String,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first,
            exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
            aperture: exif[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
        )

        return DecodedImage(
            width: width,
            height: height,
            layout: .linearSRGBHalf,
            samples: samples,
            blackLevels: [0, 0, 0],
            whiteLevel: 1,
            asShotMultipliers: SIMD3(1, 1, 1),
            cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil,
            orientation: orientation,
            baselineExposure: 0,
            info: info,
        )
    }
}
