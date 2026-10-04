import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampServices

extension RedlampEngine: RawFileInspecting {
    public func identify(_ url: URL) -> RawFileIdentity? {
        ImageDecoder.identify(url)
    }

    public func cameraPreview(of url: URL, maxLongEdge: Int) -> CGImage? {
        Thumbnails.cameraPreview(of: url, maxPixelSize: maxLongEdge)
    }

    public var rawDecoderVersion: String {
        ImageDecoder.rawDecoderVersion
    }
}
