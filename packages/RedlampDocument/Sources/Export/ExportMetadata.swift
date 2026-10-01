import Foundation
import ImageIO
import RedlampEngineAPI

/// The camera metadata an export carries over from its source file.
public enum ExportMetadata {
    /// ImageIO properties to write into an export of `source`. Only an allowlist is copied:
    /// maker notes, thumbnails, raw-specific dictionaries and anything describing the source's
    /// pixels (size, orientation, colour space) stay behind.
    public static func properties(
        from source: URL,
        policy: ExportMetadataPolicy,
        software: String = "Redlamp",
    ) -> [CFString: Any] {
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFSoftware: software]
        var result: [CFString: Any] = [:]
        guard policy != .none, !SupportedFormats.isStack(source),
              let image = CGImageSourceCreateWithURL(
                  source as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary,
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
        else { return [kCGImagePropertyTIFFDictionary: tiff] }

        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for key in [
                kCGImagePropertyExifPixelXDimension,
                kCGImagePropertyExifPixelYDimension,
                kCGImagePropertyExifColorSpace,
            ] {
                exif[key] = nil
            }
            result[kCGImagePropertyExifDictionary] = exif
        }
        if let aux = properties[kCGImagePropertyExifAuxDictionary] {
            result[kCGImagePropertyExifAuxDictionary] = aux
        }
        let sourceTIFF = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        for key in [
            kCGImagePropertyTIFFMake,
            kCGImagePropertyTIFFModel,
            kCGImagePropertyTIFFDateTime,
            kCGImagePropertyTIFFArtist,
            kCGImagePropertyTIFFCopyright,
            kCGImagePropertyTIFFImageDescription,
        ] where sourceTIFF[key] != nil {
            tiff[key] = sourceTIFF[key]
        }
        if var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            if policy == .allExceptLocation {
                for key in locationIPTCKeys {
                    iptc[key] = nil
                }
            }
            result[kCGImagePropertyIPTCDictionary] = iptc
        }
        if policy == .all, let gps = properties[kCGImagePropertyGPSDictionary] {
            result[kCGImagePropertyGPSDictionary] = gps
        }
        result[kCGImagePropertyTIFFDictionary] = tiff
        return result
    }

    private static var locationIPTCKeys: [CFString] {
        [
            kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
            kCGImagePropertyIPTCContentLocationName, kCGImagePropertyIPTCContentLocationCode,
        ]
    }
}
