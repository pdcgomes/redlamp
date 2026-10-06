import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Photos with capture times as cameras record them, for the capture-time tests (LIB-22).
extension KeywordSandbox {
    /// A small JPEG at `path` that `model` took at `time` by its clock (EXIF's `2024:06:01 08:30:00`, with
    /// `subsec`'s digits), recording the zone `offset` (`+01:00`) when it's given, at `shutter` seconds.
    @discardableResult
    func shot(
        _ path: String, at time: String, subsec: String? = nil, offset: String? = nil, model: String = "NIKON Z 8",
        shutter: Double = 1.0 / 250,
    ) throws -> URL {
        var exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: time, kCGImagePropertyExifExposureTime: shutter,
        ]
        exif[kCGImagePropertyExifSubsecTimeOriginal] = subsec
        exif[kCGImagePropertyExifOffsetTimeOriginal] = offset
        let jpeg = try PhotoMetadataReaderTests.encode(
            PhotoMetadataReaderTests.image(width: 16, height: 12),
            properties: [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: model,
                ],
                kCGImagePropertyExifDictionary: exif,
            ],
        )
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: file.path,
        )
        return file
    }

    func row(_ path: String) async throws -> PhotoRecord {
        let id = try await id(path)
        return try #require(try await index.read { try $0.photo(id: id) })
    }

    /// The photos `query` finds, by name, in capture order.
    func inCaptureOrder(_ query: String = "") async throws -> [String] {
        let engine = QueryEngine(index: index)
        try await engine.load()
        var ids: [Int64] = []
        for try await result in try engine.search(LibraryQuery(parsing: query), sort: QuerySort(.captured)) {
            ids = Array(result.ids)
        }
        let found = ids
        return try await index.read { reader in try found.compactMap { try reader.photo(id: $0)?.name } }
    }

    /// The photo's name, without its extension, as `template` makes it from what the index holds.
    func named(_ path: String, _ template: String) async throws -> String {
        let id = try await id(path)
        let job = try await NamingJob.renaming([id], in: index).job
        return try #require(job.names(NamingTemplate(parsing: template)).results.first?.base)
    }
}

/// `2024-06-01 09:30:00` as the library keeps a time by the camera's clock: read as UTC.
func cameraClock(_ text: String, plus fraction: TimeInterval = 0) -> Date {
    PhotoMetadataReaderTests.utc(text, plus: fraction)
}
