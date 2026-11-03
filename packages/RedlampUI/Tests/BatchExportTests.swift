import AppKit
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
@testable import RedlampUI

/// Batch export (EDT-16): photos that aren't open rendered in an engine of the batch's own, one at a time, each
/// with its edit as it was when Export was clicked.
@MainActor
struct BatchExportTests {
    private struct Fixture {
        let model: EditorModel
        let worker: StubEngine
        let folder: URL
        let photos: [URL]

        func cleanup() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// An editor with `count` photos in a folder, each with an edit of its own Exposure (0.1, 0.2…), and an engine
    /// for the batch.
    private func fixture(_ count: Int = 3) throws -> Fixture {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var photos: [URL] = []
        for number in 1 ... count {
            let photo = folder.appending(path: String(format: "IMG_%04d.ARW", number))
            try Data("raw".utf8).write(to: photo)
            var recipe = EditRecipe()
            recipe[.exposure] = Double(number) / 10
            try SidecarStore().save(Sidecar(recipe: recipe), for: photo)
            photos.append(photo)
        }
        let model = EditorModel(engine: StubEngine())
        let worker = StubEngine()
        model.makeWorkerEngine = { worker }
        return Fixture(model: model, worker: worker, folder: folder, photos: photos)
    }

    private func targets(
        _ fixture: Fixture,
        settings: ExportSettings = ExportSettings(),
    ) throws -> [ExportNames.Target] {
        try ExportNames(
            fixture.photos.map { ExportNames.Photo(url: $0) },
            settings: settings,
            reading: UnreadableFiles(),
        )
        .targets
    }

    /// Runs `targets` and returns the report once the batch is done.
    private func export(
        _ fixture: Fixture, _ targets: [ExportNames.Target], photos: [PhotoAddress] = [],
        open: (url: URL, recipe: EditRecipe)? = nil, while running: () async throws -> Void = {},
    ) async throws -> BatchExport.Report {
        var report: BatchExport.Report?
        var settings = ExportSettings()
        settings.revealInFinder = false
        let open = open.map { BatchExport.Open(photo: PhotoAddress(url: $0.url), recipe: $0.recipe) }
        fixture.model.batchExport.run(BatchExport.Job(
            targets: targets, photos: photos, settings: settings, open: open,
        ) { report = $0 })
        try await running()
        let deadline = ContinuousClock.now + .seconds(30)
        while report == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(report)
    }

    @Test func `every photo exports with its own edit, one at a time, each let go before the next opens`() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let targets = try targets(fixture)
        let report = try await export(fixture, targets)

        #expect(report.written == targets.map(\.url))
        #expect(report.failures.isEmpty)
        #expect(targets.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        #expect(targets.map(\.url.lastPathComponent) == [
            "IMG_0001-redlamp.jpg",
            "IMG_0002-redlamp.jpg",
            "IMG_0003-redlamp.jpg",
        ])
        #expect(fixture.worker.opened.withLock { $0 } == fixture.photos)
        #expect(fixture.worker.stills.map { $0.recipe[.exposure] } == [0.1, 0.2, 0.3])
        #expect(fixture.worker.stills.allSatisfy { $0.purpose == .export })
        #expect(fixture.worker.releases.withLock { $0 } == 3)
        #expect(fixture.model.batchExport.progress == nil)
        #expect(fixture.model.batchExport.summary == "Exported 3 photos")
    }

    @Test func `a file and its versions export each with its own edit and metadata, its sidecar read once`(
    ) async throws {
        let fixture = try fixture(2)
        defer { fixture.cleanup() }
        let (photo, copy) = (fixture.photos[1], UUID())
        var recipe = EditRecipe()
        recipe[.exposure] = 0.9
        var sidecar = try #require(SidecarStore().load(for: photo))
        sidecar.versions = [PhotoVersion(id: copy, name: "Copy 1", recipe: recipe, metadata: PhotoMetadata(rating: 4))]
        try SidecarStore().save(sidecar, for: photo)
        var version = ExportNames.Photo(url: photo)
        version.fields.version = "Copy 1"
        var settings = ExportSettings()
        settings.naming = ExportNaming(template: "{name} {version}")
        let targets = try ExportNames(
            [ExportNames.Photo(url: fixture.photos[0]), ExportNames.Photo(url: photo), version],
            settings: settings, reading: UnreadableFiles(),
        ).targets
        var fields: [PhotoMetadata?] = []
        fixture.model.batchExport.fields = { _, metadata in
            fields.append(metadata)
            return nil
        }

        let report = try await export(
            fixture, targets,
            photos: [
                PhotoAddress(url: fixture.photos[0]),
                PhotoAddress(url: photo),
                PhotoAddress(url: photo, version: copy),
            ],
        )
        #expect(report.written.count == 3 && Set(report.written).count == 3)
        #expect(report.written.last?.lastPathComponent.hasPrefix("IMG_0002 Copy 1") == true)
        #expect(fixture.worker.stills.map { $0.recipe[.exposure] } == [0.1, 0.2, 0.9])
        #expect(fields.map { $0?.rating } == [nil, nil, 4], "the version's own metadata, the files' the library's")
    }

    @Test func `each photo is built at its own edit's raw revision before it opens`() async throws {
        let fixture = try fixture(2)
        defer { fixture.cleanup() }
        var older = EditRecipe()
        older.processVersion = 14
        try SidecarStore().save(Sidecar(recipe: older), for: fixture.photos[0])
        let report = try await export(fixture, targets(fixture))
        #expect(report.written.count == 2)
        let expected = fixture.worker.expected.withLock { $0 }
        #expect(expected.map(\.url) == fixture.photos)
        #expect(expected.map(\.revision) == [.first, .current])
    }

    @Test func `the open photo exports as it was on screen when Export was clicked, not as it's changed after`(
    ) async throws {
        let fixture = try fixture(2)
        defer { fixture.cleanup() }
        var onScreen = EditRecipe()
        onScreen[.exposure] = 0.7
        let report = try await export(fixture, targets(fixture), open: (fixture.photos[0], onScreen)) {
            onScreen[.exposure] = 1.5
        }
        #expect(report.written.count == 2)
        #expect(fixture.worker.stills.map { $0.recipe[.exposure] } == [0.7, 0.2])
    }

    @Test func `a photo of the batch opens only once its edit is taken, so an edit made then isn't in its file`(
    ) async throws {
        let fixture = try fixture(2)
        defer { fixture.cleanup() }
        let gate = Gate()
        gate.hold()
        fixture.model.batchExport.saved = { _ in await gate.pass() }
        let report = try await export(fixture, targets(fixture)) {
            fixture.model.select(fixture.photos[1])
            try await Task.sleep(for: .milliseconds(200))
            #expect(fixture.model.info == nil, "it opened before the batch took its edit")
            gate.release()
            for _ in 0 ..< 400 where fixture.model.info == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            fixture.model.beginEdit(.exposure)
            fixture.model.setSliderValue(.exposure, 2)
            fixture.model.endEdit()
            fixture.model.saveNow()
        }
        #expect(report.written.count == 2)
        #expect(fixture.worker.stills.map { $0.recipe[.exposure] } == [0.1, 0.2])
    }

    @Test func `Cancel finishes the photo under way, keeps what's written and leaves the rest`() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let targets = try targets(fixture)
        let gate = Gate()
        gate.hold()
        fixture.model.batchExport.beforeExporting = { url in
            if url == fixture.photos[1] {
                await gate.pass()
            }
        }
        let report = try await export(fixture, targets) {
            for _ in 0 ..< 400 where gate.arrived == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            fixture.model.batchExport.cancel()
            gate.release()
        }
        #expect(report.written == Array(targets.prefix(2).map(\.url)))
        #expect(report.cancelled == 1)
        #expect(!FileManager.default.fileExists(atPath: targets[2].url.path))
        #expect(fixture.model.batchExport.summary == "Export cancelled: 2 of 3 photos exported")
    }

    @Test func `a photo that fails is named with why, and the rest go on`() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let targets = try targets(fixture)
        try FileManager.default.removeItem(at: fixture.photos[1])
        let report = try await export(fixture, targets)
        #expect(report.written == [targets[0].url, targets[2].url])
        #expect(report.failures.map(\.photo) == [fixture.photos[1]])
        #expect(report.failures.first?.reason.contains("isn't there any more") == true)
        #expect(fixture.model.batchExport.summary == "Exported 2 of 3 photos")
        #expect(ExportActions.failureList(report.failures).hasPrefix("IMG_0002.ARW: It isn't there any more"))
    }

    @Test func `a photo whose edit is damaged fails, named, rather than exporting as shot`() async throws {
        let fixture = try fixture(2)
        defer { fixture.cleanup() }
        try Data("not an edit".utf8).write(to: SidecarStore().editURL(for: fixture.photos[0]))
        let report = try await export(fixture, targets(fixture))
        #expect(report.failures.map(\.photo) == [fixture.photos[0]])
        #expect(report.failures.first?.reason.contains("damaged") == true)
        #expect(fixture.worker.opened.withLock { $0 } == [fixture.photos[1]])
    }

    @Test func `photos to skip aren't opened, and a file that doesn't open fails alone`() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        var targets = try targets(fixture)
        targets[0].existing = .skipped
        fixture.worker.openError = EngineError.noImageOpen
        let report = try await export(fixture, targets)
        #expect(report.skipped == 1)
        #expect(report.failures.count == 2)
        #expect(fixture.worker.opened.withLock { $0 } == Array(fixture.photos.dropFirst()))
    }

    // MARK: - From the Library

    /// The Library lets go of the photo open in Develop once another is chosen in the grid (#526).
    @Test func `photos chosen in the Library's grid export without opening, from the toolbar, the menu and its keys`(
    ) async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 4)
        let model = fixture.model
        let worker = StubEngine()
        model.makeWorkerEngine = { worker }
        let controller = EditorWindowController(
            model: model, theme: ThemeSettings(), onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let export = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "export" })
        model.showLibrary(.grid)
        model.click(fixture.photos[1])
        model.click(fixture.photos[3], toggling: true)
        try await fixture.settle()
        #expect(model.info == nil && model.selectedCount == 2, "chosen in the grid, neither open")
        #expect(export.isEnabled, "the toolbar's Export")
        #expect(model.canPerform(.export) && model.canPerform(.exportWithPrevious), "the File menu's items")

        let suite = "BatchExportTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExportPresetStore(defaults: defaults)
        var settings = ExportSettings()
        settings.revealInFinder = false
        store.recordExport(settings, presetID: nil)
        ExportActions.exportWithPrevious(model: model, store: store)
        try await fixture.eventually { model.batchExport.summary != nil }
        #expect(model.batchExport.summary == "Exported 2 photos")
        let exports = [1, 3].map { fixture.folder.appending(path: String(format: "IMG_%05d-redlamp.jpg", $0)) }
        #expect(exports.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(worker.opened.withLock { $0 } == [fixture.photos[1], fixture.photos[3]])
        #expect(model.info == nil, "neither opened in Develop")
    }

    @Test func `the Library's active photo exports when no photo has been opened in Develop`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.showLibrary(.grid)
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        let photo = fixture.folder.appending(path: "IMG_00001.ARW")
        FileManager.default.createFile(atPath: photo.path, contents: Data([1]))
        model.open([fixture.folder])
        try await fixture.eventually { model.library.count == 1 && model.selection == photo }
        #expect(model.selection == photo && model.info == nil)
        #expect(model.canPerform(.export) && model.canPerform(.exportWithPrevious))
    }
}
