import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The open folder's photos: listed without reading sidecars, badged by probes, changed row by row.
@MainActor
struct FolderLibraryTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString)")

    private func makeFolder(_ names: [String]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            try Data([1]).write(to: folder.appending(path: name))
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `opening a folder lists its photos, then badges those with a sidecar`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeFolder(["IMG_2.ARW", "IMG_10.ARW", "IMG_1.ARW"])
        var recipe = EditRecipe()
        recipe[.exposure] = 1
        try SidecarStore().save(
            Sidecar(recipe: recipe, metadata: PhotoMetadata(rating: 4)), for: folder.appending(path: "IMG_10.ARW"),
        )
        let library = FolderLibrary()
        var diffs: [LibraryDiff] = []
        let observation = library.observe { diffs.append($0) }
        defer { observation.invalidate() }

        var opened: [String] = []
        library.open(folder) { opened = $0.map(\.name) }
        try await eventually { !opened.isEmpty }
        #expect(opened == ["IMG_1.ARW", "IMG_2.ARW", "IMG_10.ARW"])
        #expect(library.count == 3)
        #expect(library.index(of: folder.appending(path: "IMG_10.ARW")) == 2)
        #expect(library.items.map(\.hasSidecar) == [false, false, true])

        try await eventually { library.items[2].hasEdits }
        #expect(library.items[2].metadata.rating == 4)
        #expect(diffs.last == LibraryDiff(updated: [2]), "the badge changes only its row")
    }

    @Test func `opening a folder removes what interrupted saves left, once a minute old`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeFolder(["IMG_1.ARW"])
        let stale = folder.appending(path: ".IMG_1.ARW.redlamp.\(UUID().uuidString)")
        let recent = folder.appending(path: ".IMG_1.ARW.redlamp.\(UUID().uuidString)")
        for directory in [stale, recent] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("{}".utf8).write(to: directory.appending(path: "edit.json"))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: stale.path,
        )

        let library = FolderLibrary()
        var opened = false
        var listedBeforeSweeping = false
        library.open(folder) { _ in
            opened = true
            listedBeforeSweeping = FileManager.default.fileExists(atPath: stale.path)
        }
        try await eventually { opened }
        #expect(listedBeforeSweeping, "the sweep runs in the background, after the listing")
        try await eventually { !FileManager.default.fileExists(atPath: stale.path) }
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: recent.path), "it may still be being written")
    }

    @Test func `a photo added or updated changes only its row`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeFolder(["A.ARW", "C.ARW"])
        let library = FolderLibrary()
        var diffs: [LibraryDiff] = []
        let observation = library.observe { diffs.append($0) }
        defer { observation.invalidate() }
        var opened = false
        library.open(folder) { _ in opened = true }
        try await eventually { opened }

        library.insert(LibraryItem(url: folder.appending(path: "B.ARW")))
        #expect(library.items.map(\.name) == ["A.ARW", "B.ARW", "C.ARW"])
        #expect(library.index(of: folder.appending(path: "C.ARW")) == 2)
        #expect(diffs.last == LibraryDiff(inserted: [1]))

        library.update(folder.appending(path: "C.ARW")) { $0.metadata.rating = 2 }
        #expect(diffs.last == LibraryDiff(updated: [2]))
        let count = diffs.count
        library.update(folder.appending(path: "C.ARW")) { $0.metadata.rating = 2 }
        #expect(diffs.count == count, "an unchanged row isn't republished")
    }

    @Test func `libraries sharing a scheduler each look for their own focus stacks`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let scheduler = WorkScheduler(
            widths: .init(onScreen: 1, lookAhead: 1, background: 1), canRunBackground: { true },
        )
        // Both libraries' detections wait behind this until both have asked for one.
        let busy = DispatchSemaphore(value: 0)
        scheduler.submit(.background) { busy.wait() }
        var libraries: [FolderLibrary] = []
        var readers: [ThreadRecordingFiles] = []
        for name in ["A", "B"] {
            let photos = folder.appending(path: name)
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            try Data([1]).write(to: photos.appending(path: "IMG_1.ARW"))
            let library = FolderLibrary(scheduler: scheduler)
            let files = ThreadRecordingFiles()
            library.files = files
            var opened = false
            library.open(photos) { _ in opened = true }
            try await eventually { opened }
            libraries.append(library)
            readers.append(files)
        }
        busy.signal()
        try await eventually { readers.allSatisfy { !$0.asked.isEmpty } }
        #expect(readers.map { $0.asked.map(\.lastPathComponent) } == [["IMG_1.ARW"], ["IMG_1.ARW"]])
        #expect(libraries.map(\.count) == [1, 1])
    }

    @Test func `a photo opened from outside the folder keeps its rating when saved`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeFolder(["IMG_1.ARW"])
        let photo = folder.appending(path: "IMG_1.ARW")
        try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 3)), for: photo)
        let model = EditorModel(engine: StubEngine())
        model.select(photo)
        try await eventually { model.info != nil }
        #expect(model.items.isEmpty, "no folder is open")
        #expect(model.photoMetadata.rating == 3)

        model.setValue(.exposure, 0.5)
        model.saveNow()
        try await eventually { SidecarStore().load(for: photo)?.recipe[.exposure] == 0.5 }
        #expect(SidecarStore().load(for: photo)?.metadata?.rating == 3)
    }

    @Test func `rating a photo updates its row and its sidecar`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeFolder(["IMG_1.ARW", "IMG_2.ARW"])
        let model = EditorModel(engine: StubEngine())
        model.open([folder])
        try await eventually { model.info != nil }
        let photo = folder.appending(path: "IMG_1.ARW")
        #expect(model.selection == photo)

        model.perform(.rating4)
        #expect(model.photoMetadata.rating == 4)
        #expect(model.library.item(for: photo)?.metadata.rating == 4)
        try await eventually { SidecarStore().load(for: photo)?.metadata?.rating == 4 }
        #expect(SidecarStore().load(for: photo)?.metadata?.rating == 4)
    }

    @Test func `a change's rows make the index set they name, in any order, with gaps and repeats`() {
        let cases: [[Int]] = [[], [4], [0, 1, 2, 3], [0, 1, 5, 6, 7, 9], [9, 3, 4, 3, 0, 8, 8], Array(0 ..< 20000)]
        for rows in cases {
            #expect(IndexSet(rows: rows) == rows.reduce(into: IndexSet()) { $0.insert($1) })
        }
        #expect(IndexSet(rows: Array(0 ..< 20000)).rangeView.count == 1, "a whole selection is one range")
    }

    @Test func `a culling change to thousands of rows is one diff of those rows`() {
        let model = EditorModel(engine: StubEngine())
        let photos = (0 ..< 5000).map { folder.appending(path: String(format: "IMG_%04d.ARW", $0)) }
        model.library.replace(with: photos.map { LibraryItem(url: $0) })
        var diffs: [LibraryDiff] = []
        let observation = model.library.observe { diffs.append($0) }
        defer { observation.invalidate() }

        let rows = Array(stride(from: 1, to: 5000, by: 2))
        model.library.setMetadata(rows) { place, metadata in metadata.rating = place % 5 + 1 }
        #expect(diffs == [LibraryDiff(updated: IndexSet(rows))])
        #expect(rows.indices.allSatisfy { model.items[rows[$0]].metadata.rating == $0 % 5 + 1 })
        #expect(model.items[0].metadata.rating == 0, "rows not named keep their badges")

        diffs = []
        model.library.updateMetadata([0, 1, 3]) { _, metadata in metadata.rating = 1 }
        #expect(diffs == [LibraryDiff(updated: [0, 3])], "only the rows whose badges changed")
    }
}
