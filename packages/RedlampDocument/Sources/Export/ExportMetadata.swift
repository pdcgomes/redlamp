import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI

/// The metadata an export carries: the camera's, from its source file, and the edit that made it.
public enum ExportMetadata {
    /// The TIFF Software tag every export carries, which tells an earlier export, safe to
    /// write over, from a photo.
    public static let software = "Redlamp"

    /// Whether the file at `url` is an image Redlamp wrote: its Software tag says so.
    public static func isExport(_ url: URL) -> Bool {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
        else { return false }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let tag = tiff?[kCGImagePropertyTIFFSoftware] ?? png?[kCGImagePropertyPNGSoftware]
        return (tag as? String)?.hasPrefix(software) == true
    }

    /// ImageIO properties to write into an export of `source`. Only an allowlist is copied:
    /// maker notes, thumbnails, raw-specific dictionaries and anything describing the source's
    /// pixels (size, orientation, colour space) stay behind. Unless `policy` is `.none`, they carry
    /// `recipe` too, for `addImage` to embed in the file's XMP (see `EmbeddedEdit`).
    public static func properties(
        from source: URL,
        policy: ExportMetadataPolicy,
        recipe: EditRecipe? = nil,
        software: String = software,
    ) -> [CFString: Any] {
        var result = copied(from: source, policy: policy, software: software)
        if policy != .none, let recipe, let edit = EmbeddedEdit.xmp(for: recipe) {
            result[EmbeddedEdit.propertyKey] = edit
        }
        return result
    }

    /// Adds `image` to `destination` with `properties`, and the edit they carry in its XMP.
    static func addImage(
        _ image: CGImage,
        to destination: CGImageDestination,
        properties: [CFString: Any],
        format: ExportFormat,
    ) {
        var properties = properties
        let edit = properties.removeValue(forKey: EmbeddedEdit.propertyKey) as? Data
        if let edit, let xmp = EmbeddedEdit.xmp(adding: edit, to: properties, format: format, like: image) {
            CGImageDestinationAddImageAndMetadata(destination, image, xmp, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
    }

    private static func copied(
        from source: URL,
        policy: ExportMetadataPolicy,
        software: String,
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
