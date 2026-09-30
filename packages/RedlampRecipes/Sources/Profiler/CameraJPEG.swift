import CoreGraphics
import Foundation
import ImageIO

/// The camera's own rendering of a raw file, for fitting looks to it.
public enum CameraJPEG {
    public enum Failure: Error, CustomStringConvertible {
        case notSupported(String)
        case unreadable

        public var description: String {
            switch self {
            case let .notSupported(name): "\(name) has no camera JPEG the profiler can read (Fujifilm RAF only)"
            case .unreadable: "the embedded JPEG can't be decoded"
            }
        }
    }

    /// The full-size JPEG a Fujifilm RAF carries, oriented, at most `maxLongEdge` pixels.
    public static func extract(from url: URL, maxLongEdge: Int) throws -> CGImage {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 100) ?? Data()
        guard header.count >= 92, header.prefix(16) == Data("FUJIFILMCCD-RAW ".utf8) else {
            throw Failure.notSupported(url.lastPathComponent)
        }
        func bigEndian(_ offset: Int) -> UInt64 {
            header[offset ..< offset + 4].reduce(0) { $0 << 8 | UInt64($1) }
        }
        try handle.seek(toOffset: bigEndian(84))
        guard let jpeg = try handle.read(upToCount: Int(bigEndian(88))),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
              ] as CFDictionary)
        else { throw Failure.unreadable }
        return image
    }
}
