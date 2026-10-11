import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RedlampLibrary

/// The lens's widest aperture and the 35 mm focal length in the index (LIB-06, schema version 12): filled from what
/// an index of version 11 keeps, read again by the indexer for the photos read before, and journaled for Put Back.
struct IndexLensTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "redlamp-lens-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A small JPEG with a camera, a lens and an exposure in its EXIF; the 35 mm focal length only where given.
    static func jpeg(
        make: String, model: String, lens: String, focal: Double, focal35: Int?, aperture: Double,
    ) throws -> Data {
        var exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:00:00", kCGImagePropertyExifLensModel: lens,
            kCGImagePropertyExifFocalLength: focal, kCGImagePropertyExifFNumber: aperture,
        ]
        if let focal35 {
            exif[kCGImagePropertyExifFocalLenIn35mmFilm] = focal35
        }
        return try PhotoMetadataReaderTests.encode(PhotoMetadataReaderTests.image(), properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: model],
            kCGImagePropertyExifDictionary: exif,
        ])
    }

    @Test func `version 12 fills the fields from lens names and cameras, and marks the photos read to read again`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Index.sqlite")
        let older = try await LibraryIndex.open(at: url, migrations: Array(LibraryIndex.migrations.prefix(11)))
        try await older.write { writer in
            try writer.database.execute("""
            INSERT INTO cameras (id, make, model, name) VALUES (1, 'SONY', 'ILCE-7M4', 'Sony ILCE-7M4'),
              (2, 'Canon', 'Canon EOS 90D', 'Canon EOS 90D');
            INSERT INTO lenses (id, name) VALUES (1, 'FE 85mm F1.8'), (2, 'EF-S18-55mm f/3.5-5.6 IS STM'),
              (3, '24-70mm');
            INSERT INTO photos (id, folder, name, kind, size, modified, camera, lens, aperture, focal, indexed, state)
            VALUES (1, 1, 'A.ARW', 1, 1, 0, 1, 1, 1.8, 85, 1, 0), (2, 1, 'B.CR3', 1, 1, 0, 2, 2, 5.6, 55, 1, 0),
              (3, 1, 'C.CR3', 1, 1, 0, 2, 3, 2.8, 40, 1, 0), (4, 2, 'D.JPG', 2, 1, 0, NULL, NULL, NULL, NULL, 0, 0),
              (5, 2, 'E.ARW', 1, 1, 0, 1, 1, 1.8, 85, 1, 1);
            """)
        }
        await older.close()

        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }
        let (photos, folders, version) = try await index.read { reader in
            try (
                (1 ... 5).map { try reader.photo(id: $0) },
                reader.foldersWithLensesToRead(),
                reader.database.userVersion,
            )
        }
        #expect(version == LibraryIndex.migrations.count)
        let sony = try #require(photos[0])
        #expect(sony.widestAperture == 1.8 && sony.focal35 == nil && sony.indexed == PhotoRecord.lensToRead)
        let kit = try #require(photos[1])
        #expect(kit.widestAperture == 5.6 && kit.focal35 == 88 && kit.indexed == PhotoRecord.lensToRead)
        let unnamed = try #require(photos[2])
        #expect(unnamed.widestAperture == nil && unnamed.focal35 == 64)
        let unread = try #require(photos[3])
        #expect(unread.widestAperture == nil && unread.focal35 == nil && unread.indexed == 0)
        let missing = try #require(photos[4])
        #expect(missing.widestAperture == 1.8 && missing.indexed == PhotoRecord.lensToRead)
        #expect(folders == [1], "a missing photo's folder isn't listed for them, nor an unread one's")
    }

    @Test func `the indexer reads the lens's fields of photos read before them, changing nothing else, once`(
    ) async throws {
        let folder = try TemporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.jpeg(
            make: "SONY", model: "ILCE-7M4", lens: "FE 70-200mm F2.8 GM OSS II", focal: 200, focal35: 200,
            aperture: 2.8,
        ).write(to: folder.url.appending(path: "Tele.jpg"))
        try Self.jpeg(
            make: "Canon", model: "Canon EOS 90D", lens: "EF50mm f/1.8 STM", focal: 50, focal35: nil, aperture: 4,
        ).write(to: folder.url.appending(path: "Crop.jpg"))
        let index = try await LibraryIndex.open(at: directory.appending(path: "Index.sqlite"), readers: 2)
        defer { index.closeAndWait() }
        let files = CountingFileSystem()
        let indexer = LibraryIndexer(index: index, fileSystem: files, configuration: .testing())
        let paths = ["Tele.jpg", "Crop.jpg"].map { LibraryIndexer.path(folder.url.appending(path: $0)) }
        func rows() async throws -> [PhotoRecord] {
            try await index.read { reader in try paths.compactMap { try reader.photo(path: $0) } }
        }

        var run = await IndexerRun.collect(indexer.index([folder.url]))
        #expect(run.failures.isEmpty)
        var found = try await rows()
        #expect(found.map(\.widestAperture) == [2.8, 1.8] && found.map(\.focal35) == [200, 80])
        #expect(found.allSatisfy { $0.indexed == 1 })

        // As version 12's migration leaves the photos read before it, rated since.
        try await index.write { writer in
            try writer.database.execute("""
            UPDATE photos SET indexed = \(PhotoRecord.lensToRead), widest_aperture = NULL, focal35 = NULL, rating = 4
            """)
        }
        files.reset()
        run = await IndexerRun.collect(indexer.index([folder.url]))
        #expect(run.failures.isEmpty && files.counts.heads == 2)
        found = try await rows()
        #expect(found.map(\.widestAperture) == [2.8, 1.8] && found.map(\.focal35) == [200, 80])
        #expect(found.allSatisfy { $0.indexed == 1 && $0.rating == 4 })
        #expect(try await index.read { try $0.foldersWithLensesToRead() }.isEmpty)

        files.reset()
        run = await IndexerRun.collect(indexer.index([folder.url]))
        #expect(files.counts.heads == 0 && run.summary?.photosUpdated == 0)
    }

    @Test func `a photo's lens's fields are journaled with its row, for Put Back`() {
        let photo = PhotoRecord(
            id: 7, folder: 1, name: "A.JPG", aperture: 1.8, focal: 85, widestAperture: 1.8, focal35: 85,
        )
        let restored = IndexedPhoto(photo).record(inFolder: 1)
        #expect(restored.widestAperture == 1.8 && restored.focal35 == 85)
    }
}
