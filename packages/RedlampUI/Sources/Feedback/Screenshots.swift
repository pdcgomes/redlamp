import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshots for a report, as JPEGs no larger than `maxPixels` on the long edge and with no
/// metadata, so a pasted photo can't carry its location along.
enum Screenshots {
    static let maxPixels = 2560
    /// Keeps a report with three screenshots well under the relay's 4.5 MB request limit.
    static let maxBytes = 1_100_000

    /// Redlamp's window as it is on screen, including the photo (which a window's own snapshot
    /// misses, being Metal). `SCShareableContent.currentProcess` lists only this app's windows and
    /// needs no Screen Recording permission.
    static func capture(windowNumber: Int) async -> FeedbackReport.Screenshot? {
        guard let content = try? await SCShareableContent.currentProcess,
              let window = content.windows.first(where: { $0.windowID == CGWindowID(windowNumber) })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let size = fitted(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration,
        )
        else { return nil }
        return screenshot(image, source: "Redlamp's window")
    }

    /// An image someone pasted, dropped or chose, as a screenshot.
    static func screenshot(data: Data, source: String) -> FeedbackReport.Screenshot? {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return screenshot(source: image, name: source)
    }

    static func screenshot(url: URL) -> FeedbackReport.Screenshot? {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return screenshot(source: image, name: url.lastPathComponent)
    }

    /// The image on the pasteboard, if there is one.
    @MainActor
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> FeedbackReport.Screenshot? {
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = pasteboard.data(forType: type) {
                return screenshot(data: data, source: "Pasted")
            }
        }
        return nil
    }

    private static func screenshot(source: CGImageSource, name: String) -> FeedbackReport.Screenshot? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return screenshot(image, source: name)
    }

    private static func screenshot(_ image: CGImage, source: String) -> FeedbackReport.Screenshot? {
        var image = image
        for quality in [0.82, 0.7, 0.55] {
            if let data = jpeg(image, quality: quality), data.count <= maxBytes || quality == 0.55 {
                if data.count <= maxBytes {
                    return FeedbackReport.Screenshot(
                        jpeg: data,
                        width: image.width,
                        height: image.height,
                        source: source,
                    )
                }
                // Still too large: halve it once and try again.
                guard let smaller = scaled(image, by: 0.5) else { return nil }
                image = smaller
                return jpeg(image, quality: 0.7).map {
                    FeedbackReport.Screenshot(jpeg: $0, width: image.width, height: image.height, source: source)
                }
            }
        }
        return nil
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        )
        else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary,
        )
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func fitted(width: Double, height: Double) -> (width: Int, height: Int) {
        let scale = min(1, Double(maxPixels) / max(width, height, 1))
        return (max(1, Int(width * scale)), max(1, Int(height * scale)))
    }
}
