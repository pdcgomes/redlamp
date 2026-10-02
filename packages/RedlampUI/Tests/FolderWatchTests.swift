import Foundation
import RedlampDocument
import Testing
@testable import RedlampUI

/// The filmstrip following the disk: files added, removed, renamed and rewritten in a temporary
/// tree arrive as row changes, never a reload.
@MainActor
struct FolderWatchTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")

    private func write(_ path: String, bytes: Int = 1, age: TimeInterval = 60) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path,
        )
    }

    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func open(_ folder: String, subfolders: Bool = false) async throws -> (EditorModel, Diffs) {
        let model = EditorModel(engine: StubEngine())
        let diffs = Diffs()
        diffs.observation = model.library.observe { diffs.all.append($0) }
        if subfolders {
            model.setIncludesSubfolders(true)
        }
        model.open([root.appending(path: folder)])
        try await eventually { model.selection != nil }
        // FSEvents reports changes from when the stream starts.
        try await Task.sleep(for: .milliseconds(300))
        diffs.all = []
        return (model, diffs)
    }

    @MainActor
    final class Diffs {
        var all: [LibraryDiff] = []
        var observation: LibraryObservation?
    }

    @Test func `added, removed and renamed photos change rows, and the selection survives`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Trip/A.ARW")
        try write("Trip/C.ARW")
        try write("Trip/E.ARW")
        let (model, diffs) = try await open("Trip")
        model.selectNext()
        #expect(model.selection?.lastPathComponent == "C.ARW")

        try write("Trip/B.ARW")
        try await eventually { model.items.count == 4 }
        #expect(model.items.map(\.name) == ["A.ARW", "B.ARW", "C.ARW", "E.ARW"])
        let reloaded = diffs.all.contains { $0.reset }
        #expect(!reloaded, "rows changed, the strip didn't reload")
        #expect(model.selection?.lastPathComponent == "C.ARW")

        try FileManager.default.moveItem(at: root.appending(path: "Trip/E.ARW"), to: root.appending(path: "Trip/D.ARW"))
        try await eventually { model.items.map(\.name) == ["A.ARW", "B.ARW", "C.ARW", "D.ARW"] }
        #expect(model.items.map(\.name) == ["A.ARW", "B.ARW", "C.ARW", "D.ARW"])

        try FileManager.default.removeItem(at: root.appending(path: "Trip/C.ARW"))
        try await eventually { model.items.count == 3 && model.selection?.lastPathComponent == "D.ARW" }
        #expect(model.selection?.lastPathComponent == "D.ARW", "its neighbour took its place")
    }

    @Test func `a rewritten photo updates its row, and a copy in progress waits to settle`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Trip/A.ARW")
        let (model, diffs) = try await open("Trip")

        try write("Trip/A.ARW", bytes: 50, age: 30)
        try await eventually { model.items.first?.size == 50 }
        let rewrote = diffs.all.contains { $0.updated == [0] }
        #expect(rewrote)

        try write("Trip/B.ARW", bytes: 10, age: 0)
        try await eventually { model.items.count == 2 }
        #expect(model.items.last?.isSettling == true)
        try await eventually(6) { model.items.last?.isSettling == false }
        #expect(model.items.last?.isSettling == false, "settled once its date was older than the delay")
    }

    @Test func `with subfolders, a new subfolder's photos arrive in order`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Trip/a.ARW")
        try write("Trip/Day 3/c.ARW")
        let (model, _) = try await open("Trip", subfolders: true)
        try await eventually { model.items.count == 2 }

        try write("Trip/Day 2/b.ARW")
        try await eventually { model.items.count == 3 }
        #expect(model.items.map(\.name) == ["a.ARW", "b.ARW", "c.ARW"])

        try FileManager.default.removeItem(at: root.appending(path: "Trip/Day 3"))
        try await eventually { model.items.count == 2 }
        #expect(model.items.map(\.name) == ["a.ARW", "b.ARW"])
    }

    @Test func `the folder tree's counts follow the disk`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Trip/a.ARW")
        let (model, _) = try await open("Trip")
        let trip = root.appending(path: "Trip")
        model.library.listTree(trip)
        try await eventually { model.library.node(for: trip)?.count == 1 }
        try write("Trip/b.ARW")
        try await eventually { model.library.node(for: trip)?.count == 2 }
        #expect(model.library.node(for: trip)?.count == 2)
    }
}
