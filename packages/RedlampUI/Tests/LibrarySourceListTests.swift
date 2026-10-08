import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization
import Testing
@_spi(Harness) @testable import RedlampUI

/// A Library entry's list (`LibrarySourceList`) as photos change, arrive and leave: each update after the first is
/// taken from the photos its diff names, and what it hands over is what a list opened afresh hands over.
@MainActor
struct LibrarySourceListTests {
    /// The last change a list handed over: its photos' ratings by path, and how many changes it has handed.
    private final class Handed: Sendable {
        private let state = Mutex<(photos: [String: Int]?, changes: Int)>((nil, 0))

        var photos: [String: Int]? {
            state.withLock { $0.photos }
        }

        var changes: Int {
            state.withLock { $0.changes }
        }

        func take(_ change: LibrarySourceList.Change) {
            let photos = Dictionary(change.items.map { ($0.url.path, $0.metadata.rating) }) { first, _ in first }
            state.withLock { $0 = (photos, $0.changes + 1) }
        }
    }

    private static func open(_ core: LibraryCore) -> (LibrarySourceList, Handed) {
        let handed = Handed()
        let list = LibrarySourceList(core: core, source: .allPhotographs) { change in handed.take(change) }
        return (list, handed)
    }

    /// What a list opened afresh hands over first.
    private static func afresh(_ core: LibraryCore, _ sandbox: SourcesSandbox) async throws -> [String: Int] {
        let (list, handed) = open(core)
        defer { list.close() }
        try await sandbox.eventually { handed.photos != nil }
        return try #require(handed.photos)
    }

    @Test func `a list follows photos changed, added and taken out as a list opened afresh has them`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg", "B.jpg", "C.jpg"])
        let model = try await sandbox.open()
        let service = try #require(sandbox.service)
        let core = try #require(service.core)
        let (list, handed) = Self.open(core)
        defer { list.close() }
        try await sandbox.eventually { handed.photos?.count == 3 }
        let b = sandbox.photo("B.jpg").path

        // B rated: one photo changed in place.
        model.showFolder(sandbox.root)
        try await sandbox.eventually { model.items.count == 3 }
        try await sandbox.cull(.rating3, [sandbox.photo("B.jpg")])
        try await sandbox.eventually { handed.photos?[b] == 3 }
        let rated = try #require(handed.photos)
        #expect(try await rated == Self.afresh(core, sandbox))

        // Trip added: its photos arrive among the others.
        let trip = try FolderRemovalTests.trip(in: sandbox)
        try await FolderRemovalTests.add(trip, to: model.library, service: service)
        try await sandbox.eventually { handed.photos?.count == 6 }
        let added = try #require(handed.photos)
        #expect(added.count == 6 && added[b] == 3, "\(added)")
        #expect(try await added == Self.afresh(core, sandbox))

        // Trip taken out: its photos leave, the others stay as they were.
        let changes = handed.changes
        try model.library.remove(#require(model.library.root(containing: trip)))
        try await sandbox.eventually { handed.photos?.count == 3 }
        let left = try #require(handed.photos)
        let expected = ["A.jpg": 0, "B.jpg": 3, "C.jpg": 0].reduce(into: [String: Int]()) { photos, photo in
            photos[sandbox.photo(photo.key).path] = photo.value
        }
        #expect(left == expected)
        #expect(try await left == Self.afresh(core, sandbox))
        #expect(handed.changes > changes)
    }
}
