import Foundation
import Testing
@testable import RedlampLibrary

struct DuplicateCandidateTests {
    static func key(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 16)
    }

    @Test func `candidates are the photos whose content keys and sizes both agree, offline ones included`(
    ) async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["A", "B"])
        let (a, b) = try (#require(folders["A"]), #require(folders["B"]))
        let ids = try await sandbox.upsert([
            PhotoRecord(folder: a, name: "IMG_0001.JPG", size: 100, contentKey: Self.key(1)),
            PhotoRecord(folder: b, name: "IMG_0001.JPG", size: 100, contentKey: Self.key(1)),
            PhotoRecord(folder: b, name: "IMG_0001 copy.JPG", size: 100, contentKey: Self.key(1)),
            PhotoRecord(folder: a, name: "IMG_0002.JPG", size: 200, contentKey: Self.key(1)),
            PhotoRecord(folder: a, name: "IMG_0003.JPG", size: 100, contentKey: Self.key(3)),
            PhotoRecord(folder: a, name: "IMG_0004.JPG", size: 300, contentKey: Self.key(4)),
            PhotoRecord(folder: b, name: "IMG_0004.JPG", size: 300, contentKey: Self.key(4), state: .offline),
            PhotoRecord(folder: b, name: "IMG_0005.JPG", size: 300),
        ])
        let candidates = try await DuplicateFinder(index: sandbox.index).candidates()
        #expect(candidates.photosGrouped == 7)
        #expect(try candidates.groups == [
            DuplicateCandidateGroup(
                contentKey: #require(ContentKey(data: Self.key(4))),
                size: 300,
                photos: [ids[5], ids[6]],
            ),
            DuplicateCandidateGroup(
                contentKey: #require(ContentKey(data: Self.key(1))), size: 100, photos: [ids[0], ids[1], ids[2]],
            ),
        ])
        #expect(candidates.photoCount == 5 && candidates.copyCount == 3)
    }

    @Test func `a raw and its JPEG aren't duplicates, though they share a name, a size and a date`() async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let jpeg = duplicateBytes(200_000, seed: 2)
        try sandbox.write("Shoot/DSCF0001.RAF", duplicateBytes(200_000, seed: 1), modified: 60)
        try sandbox.write("Shoot/DSCF0001.JPG", jpeg, modified: 60)
        try sandbox.write("Backup/DSCF0001.JPG", jpeg, modified: 60)
        try await sandbox.indexAll()
        let finder = sandbox.finder()
        let candidates = try await finder.candidates()
        let copies = try await [sandbox.id("Backup/DSCF0001.JPG"), sandbox.id("Shoot/DSCF0001.JPG")].sorted()
        #expect(candidates.groups.map(\.photos) == [copies])
        let confirmation = try await finder.confirm(candidates)
        #expect(confirmation.duplicates.map(\.photos) == [copies])
    }
}
