import CryptoKit
import Foundation
import Testing
@testable import RedlampLibrary

struct DuplicateFixtureTests {
    /// The SHA-256 of `LibraryFixture(spec: .init(photos: 2000, seed: 42))`'s manifest as written,
    /// and of its photos' records, recorded before fixtures could hold duplicates.
    static let manifestDigest = "d832b9e58b7d593e7e7bd88d11d98262905aacf8ec6250496a87d009909666c6"
    static let recordsDigest = "65d41dd84134e507ae50dd67afb63fc38e1d19bcfe2a2104fbb19c71c7115edb"

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A photo's record, every field written out.
    static func record(_ photo: FixturePhoto) -> String {
        func number(_ value: Double?) -> String {
            value.map { "\($0)" } ?? "-"
        }
        let sidecar = photo.sidecar.map {
            "\($0.rating) \($0.flag?.rawValue ?? "-") \($0.label?.rawValue ?? "-") \($0.edited)"
        } ?? "-"
        let xmp = photo.xmp.map {
            "\($0.rating) \($0.label?.rawValue ?? "-") \($0.keywords.joined(separator: ","))"
        } ?? "-"
        let location = photo.location.map { "\($0.latitude) \($0.longitude)" } ?? "-"
        return [
            "\(photo.index)", photo.folder, photo.name, photo.kind.rawValue, photo.make ?? "-", photo.model ?? "-",
            photo.lens ?? "-", photo.iso.map { "\($0)" } ?? "-", number(photo.aperture), number(photo.exposureTime),
            number(photo.focalLength), photo.captured.exif, location, photo.embeddedKeywords.joined(separator: ","),
            photo.caption ?? "-", sidecar, xmp, photo.source.map { "\($0)" } ?? "-",
        ].joined(separator: "|")
    }

    static func manifestData(_ manifest: FixtureManifest) throws -> Data {
        let folder = try TemporaryFolder()
        try manifest.write(to: folder.url)
        return try Data(contentsOf: folder.url.appending(path: FixtureManifest.fileName))
    }

    @Test func `a fixture without duplicates has the photos and manifest it had before them`() throws {
        let fixture = LibraryFixture(spec: .init(photos: 2000, seed: 42))
        let records = (0 ..< 2000).map { Self.record(fixture.photo(at: $0)) }.joined(separator: "\n")
        let manifest = try Self.manifestData(fixture.manifest())
        #expect(Self.digest(manifest) == Self.manifestDigest)
        #expect(Self.digest(Data(records.utf8)) == Self.recordsDigest)
        #expect(LibraryFixture.Spec(photos: 2000, seed: 42, duplicateShare: 0) == fixture.spec)
        #expect(fixture.manifest().totals.duplicates == nil && (0 ..< 2000)
            .allSatisfy { fixture.photo(at: $0).original == nil })
        let decoded = try JSONDecoder().decode(FixtureManifest.self, from: manifest)
        #expect(decoded.spec == fixture.spec && decoded.spec.duplicateShare == nil)
    }

    @Test func `turning duplicates on changes only the photos that become copies`() {
        let without = LibraryFixture(spec: .init(photos: 2000, seed: 42))
        let with = LibraryFixture(spec: .init(photos: 2000, seed: 42, duplicateShare: 0.02))
        let photos = (0 ..< 2000).map(with.photo(at:))
        let copies = photos.filter { $0.original != nil }
        #expect((20 ... 60).contains(copies.count))
        #expect(with.manifest().totals.duplicates == copies.count)
        for photo in photos {
            let before = without.photo(at: photo.index)
            guard let original = photo.original else {
                #expect(Self.record(photo) == Self.record(before))
                continue
            }
            let copied = with.photo(at: original)
            #expect(copied.original == nil && original < photo.index)
            #expect(photo.folder == before.folder && photo.sidecar == before.sidecar && photo.xmp == before.xmp)
            #expect((photo.name as NSString).pathExtension == (copied.name as NSString).pathExtension)
            #expect(photo.captured == copied.captured && photo.kind == copied.kind && photo.source == copied.source)
            #expect(photo.content == copied.index)
        }
    }
}
