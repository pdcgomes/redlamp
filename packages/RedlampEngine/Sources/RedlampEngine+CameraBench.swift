import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampServices

/// Files are read where the engine decodes: the decode service in the Mac app, in this process
/// for the CLI and tests. The calls block, so never make them on the main thread.
extension RedlampEngine: RawFileInspecting {
    public func identify(_ url: URL) -> RawFileIdentity? {
        files.rawIdentities(of: [url]).first ?? nil
    }

    public func identify(_ urls: [URL]) -> [RawFileIdentity?] {
        files.rawIdentities(of: urls)
    }

    public func cameraPreview(of url: URL, maxLongEdge: Int) -> CGImage? {
        files.cameraPreviews(of: [url], maxLongEdge: maxLongEdge).first ?? nil
    }

    public var rawDecoderVersion: String {
        ImageDecoder.rawDecoderVersion
    }
}
