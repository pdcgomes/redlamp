import Foundation
import RedlampDocument
import Testing
@testable import RedlampUI

/// The working set: folders added and remembered, missing roots, subfolders, the last photo.
@MainActor
struct WorkingSetTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "working-\(UUID().uuidString)")
    private let suite = "working-set-tests-\(UUID().uuidString)"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suite)!
    }

    private func photos(_ paths: [String]) throws {
        for path in paths {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try Data([1]).write(to: url)
        }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `added folders are remembered, without nesting a folder already in a root`() async throws {
        defer { cleanUp() }
        try photos(["Trips/Rome/a.ARW", "Family/b.ARW"])
        let library = FolderLibrary(defaults: defaults)
        library.add([root.appending(path: "Trips"), root.appending(path: "Family")])
        library.add([root.appending(path: "Trips/Rome")])
        #expect(library.roots.map(\.name) == ["Trips", "Family"])
        try await eventually { library.roots.allSatisfy { $0.bookmark != nil } }

        let relaunched = FolderLibrary(defaults: defaults)
        #expect(relaunched.roots == library.roots)
        #expect(relaunched.root(containing: root.appending(path: "Trips/Rome/a.ARW"))?.name == "Trips")
    }

    @Test func `the folder earlier versions remembered becomes the first root`() {
        defer { cleanUp() }
        defaults.set(root.path, forKey: "lastFolder")
        let library = FolderLibrary(defaults: defaults)
        #expect(library.roots.map(\.path) == [root.standardizedFileURL.path])
        #expect(library.openFolder?.path == root.path)
    }

    @Test func `a root that's gone is flagged, and comes back when located`() async throws {
        defer { cleanUp() }
        try photos(["Old/a.ARW", "New/a.ARW"])
        let library = FolderLibrary(defaults: defaults)
        library.add([root.appending(path: "Old")])
        try FileManager.default.removeItem(at: root.appending(path: "Old"))

        var restored = false
        FolderLibrary(defaults: defaults).restore { _, _ in }
        library.restore { _, _ in restored = true }
        try await eventually { restored }
        let old = try #require(library.roots.first)
        #expect(library.missing == [old.id])

        library.locate(old, at: root.appending(path: "New"))
        #expect(library.missing.isEmpty)
        #expect(library.roots.first?.name == "New")
        #expect(library.roots.first?.id == old.id)
    }

    @Test func `removing a root closes its folder; nothing on disk changes`() async throws {
        defer { cleanUp() }
        try photos(["Trip/a.ARW"])
        let model = EditorModel(engine: StubEngine(), library: FolderLibrary(defaults: defaults))
        model.open([root.appending(path: "Trip")])
        try await eventually { model.library.count == 1 }
        let trip = try #require(model.library.roots.first)

        model.library.remove(trip)
        #expect(model.library.roots.isEmpty)
        #expect(model.folder == nil)
        #expect(model.library.count == 0)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Trip/a.ARW").path))
    }

    @Test func `with subfolders, every photo beneath the folder arrives in order`() async throws {
        defer { cleanUp() }
        try photos(["Trip/a.ARW", "Trip/Day 10/c.ARW", "Trip/Day 2/b.ARW", "Trip/Day 2/Picks/b2.ARW"])
        let model = EditorModel(engine: StubEngine(), library: FolderLibrary(defaults: defaults))
        model.open([root.appending(path: "Trip")])
        try await eventually { model.library.count == 1 }

        model.setIncludesSubfolders(true)
        try await eventually { model.library.count == 4 }
        #expect(model.items.map(\.name) == ["a.ARW", "b.ARW", "b2.ARW", "c.ARW"])
        #expect(FolderLibrary(defaults: defaults).includesSubfolders, "remembered")
    }

    @Test func `each folder reopens on the photo last shown in it`() async throws {
        defer { cleanUp() }
        try photos(["A/1.ARW", "A/2.ARW", "B/1.ARW"])
        let model = EditorModel(engine: StubEngine(), library: FolderLibrary(defaults: defaults))
        model.open([root.appending(path: "A")])
        try await eventually { model.selection != nil }
        model.selectNext()
        let second = root.appending(path: "A/2.ARW")
        #expect(model.selection == second)

        model.open([root.appending(path: "B")])
        try await eventually { model.selection?.lastPathComponent == "1.ARW" && model.folder?.lastPathComponent == "B" }
        model.showFolder(root.appending(path: "A"))
        try await eventually { model.selection == second }
        #expect(model.selection == second)
        #expect(model.library.roots.map(\.name) == ["A", "B"])
    }
}
