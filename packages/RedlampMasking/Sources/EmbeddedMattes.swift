import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import RedlampEngineAPI

/// Mattes and depth some files carry, written by the camera at capture: iPhone Portrait mattes,
/// semantic mattes (hair, skin, teeth, glasses, sky) and depth or disparity. When a file has
/// one, the matching mask is free and capture-accurate.
public enum EmbeddedMatte: String, CaseIterable, Sendable {
    case portrait, hair, skin, teeth, glasses, sky, depth

    var auxiliaryType: CFString {
        switch self {
        case .portrait: kCGImageAuxiliaryDataTypePortraitEffectsMatte
        case .hair: kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte
        case .skin: kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte
        case .teeth: kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte
        case .glasses: kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte
        case .sky: kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte
        case .depth: kCGImageAuxiliaryDataTypeDisparity
        }
    }
}

public enum EmbeddedMattes {
    /// The mattes `url` carries.
    public static func available(in url: URL) -> Set<EmbeddedMatte> {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return Set(EmbeddedMatte.allCases.filter { matte in
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, matte.auxiliaryType) != nil
                || (matte == .depth && CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                    source,
                    0,
                    kCGImageAuxiliaryDataTypeDepth,
                ) != nil)
        })
    }

    /// A matte in the oriented frame. Depth comes back as disparity scaled to 0...1 (near is 1).
    public static func read(_ matte: EmbeddedMatte, from url: URL) -> GrayMask? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[
            kCGImagePropertyOrientation,
        ] as? Int ?? 1
        var info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, matte.auxiliaryType) as? [CFString: Any]
        var isDepth = false
        if info == nil, matte == .depth {
            info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source,
                0,
                kCGImageAuxiliaryDataTypeDepth,
            ) as? [CFString: Any]
            isDepth = true
        }
        guard let info,
              let data = info[kCGImageAuxiliaryDataInfoData] as? Data,
              let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
              let width = description["Width" as CFString] as? Int,
              let height = description["Height" as CFString] as? Int,
              let rowBytes = description["BytesPerRow" as CFString] as? Int
        else { return nil }
        let format = description["PixelFormat" as CFString] as? UInt32 ?? kCVPixelFormatType_OneComponent8
        let values = decode(data, width: width, height: height, rowBytes: rowBytes, format: format)
        guard values.count == width * height else { return nil }
        var coverage = values
        if matte == .depth {
            // Disparity is 1 / distance; depth is distance. Either way, near ends up at 1.
            let finite = values.filter(\.isFinite)
            let low = finite.min() ?? 0
            let high = finite.max() ?? 1
            let span = max(high - low, 1e-6)
            coverage = values.map { value in
                guard value.isFinite else { return 0 }
                let t = (value - low) / span
                return isDepth ? 1 - t : t
            }
        }
        return GrayMask(width: width, height: height, coverage: coverage).oriented(exif: orientation)
    }

    private static func decode(_ data: Data, width: Int, height: Int, rowBytes: Int, format: UInt32) -> [Float] {
        var values = [Float](repeating: 0, count: width * height)
        data.withUnsafeBytes { bytes in
            for y in 0 ..< height {
                let row = bytes.baseAddress!.advanced(by: y * rowBytes)
                for x in 0 ..< width {
                    let value: Float = switch format {
                    case kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DepthFloat16,
                         kCVPixelFormatType_OneComponent16Half:
                        Float(row.loadUnaligned(fromByteOffset: x * 2, as: Float16.self))
                    case kCVPixelFormatType_DisparityFloat32, kCVPixelFormatType_DepthFloat32,
                         kCVPixelFormatType_OneComponent32Float:
                        row.loadUnaligned(fromByteOffset: x * 4, as: Float.self)
                    default:
                        Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255
                    }
                    values[y * width + x] = value
                }
            }
        }
        return values
    }
}
