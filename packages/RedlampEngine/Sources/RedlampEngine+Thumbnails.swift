import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampServices

public extension RedlampEngine {
    func decodeThumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        let source = SupportedFormats.isStack(url) ? stacks.thumbnailFrame(for: url) : url
        return source.flatMap { Thumbnails.thumbnail(for: $0, maxPixelSize: maxPixelSize) }
    }
}
