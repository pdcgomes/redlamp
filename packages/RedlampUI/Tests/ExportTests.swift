import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

@MainActor
struct ExportTests {
    /// An editor with a photo open in a temporary folder exports can be written to.
    private struct Fixture {
        let model: EditorModel
        let engine: StubEngine
        let folder: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func openEditor() async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = StubEngine()
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        return Fixture(model: model, engine: engine, folder: folder)
    }

    private func defaults() -> UserDefaults {
        let name = "ExportTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func `exporting renders the settings and writes the file`() async throws {
        let fixture = try await openEditor()
        defer { fixture.cleanup() }
        let (model, engine, folder) = (fixture.model, fixture.engine, fixture.folder)
        var settings = ExportSettings()
        settings.setFormat(.png)
        settings.bitDepth = 16
        settings.colorSpace = .displayP3
        settings.sizing = ExportSizing(mode: .longEdge)
        settings.sizing.longEdge = 300
        let url = try ExportDestination.url(for: #require(model.info).url, settings: settings, reading: engine.files)
        #expect(url.lastPathComponent == "IMG_0001-redlamp.png")

        try await model.export(settings, to: url)

        let request = try #require(engine.stills.last)
        #expect(request.maxLongEdge == 300)
        #expect(request.bitsPerComponent == 16)
        #expect(request.colorSpace == .displayP3)
        #expect(request.purpose == .export)
        #expect(request.source == folder.appending(path: "IMG_0001.ARW"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        #expect(model.exportStatus == "Exported IMG_0001-redlamp.png")
    }

    /// Answers one file's properties and records what it was asked.
    private final class SourceProperties: FileInspecting, @unchecked Sendable {
        let source: URL
        let properties: ImageProperties?
        private let lock = NSLock()
        private var urls: [URL] = []

        var asked: [URL] {
            lock.withLock { urls }
        }

        init(_ source: URL, _ properties: [CFString: Any]) {
            self.source = source
            self.properties = ImageProperties(properties)
        }

        func captures(of urls: [URL], concurrently _: Bool) -> [CaptureSettings?] {
            urls.map { _ in nil }
        }

        func focusThumbnails(of urls: [URL], concurrently _: Bool) -> [GreyThumbnail?] {
            urls.map { _ in nil }
        }

        func imageProperties(of urls: [URL]) -> [ImageProperties?] {
            lock.withLock { self.urls += urls }
            return urls.map { $0 == source ? properties : nil }
        }

        func haldImage(of _: URL) -> HaldImage? {
            nil
        }
    }

    @Test func `an export copies its source's metadata as the engine's reader reads it`() async throws {
        let fixture = try await openEditor()
        defer { fixture.cleanup() }
        let (model, engine, folder) = (fixture.model, fixture.engine, fixture.folder)
        let source = folder.appending(path: "IMG_0001.ARW")
        let files = SourceProperties(source, [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Lisbon"],
        ])
        engine.files = files
        var settings = ExportSettings()
        settings.metadata = .all
        let url = folder.appending(path: "IMG_0001-redlamp.jpg")

        try await model.export(settings, to: url)

        let written = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [CFString: Any]
        let iptc = properties?[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCCity] as? String == "Lisbon")
        #expect(files.asked == [source])
    }

    @Test func `a failed export clears the status and throws`() async throws {
        let fixture = try await openEditor()
        defer { fixture.cleanup() }
        let (model, folder) = (fixture.model, fixture.folder)
        let url = folder.appending(path: "missing").appending(path: "out.jpg")
        await #expect(throws: ExportError.self) {
            try await model.export(ExportSettings(), to: url)
        }
        #expect(model.exportStatus == nil)
    }

    @Test func `nothing in the editor runs while the dialog is open`() async throws {
        let fixture = try await openEditor()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.canPerform(.export))
        model.isModalDialogOpen = true
        let runnable = ShortcutAction.allCases.filter { model.canPerform($0) }
        #expect(runnable.isEmpty, "\(runnable)")
        #expect(!model.perform(.toggleBlackAndWhite))
        #expect(model.recipe.treatment == EditRecipe().treatment)
        model.isModalDialogOpen = false
        #expect(model.perform(.toggleBlackAndWhite))
    }

    @Test func `the store remembers the last export and the user's presets`() {
        let defaults = defaults()
        let store = ExportPresetStore(defaults: defaults)
        #expect(store.previous == nil)
        #expect(store.initialSettings == ExportPreset.builtIns[0].settings)

        var settings = ExportSettings()
        settings.setFormat(.heic)
        let saved = store.savePreset(named: "Phone", settings: settings)
        store.recordExport(settings, presetID: saved.id)
        settings.quality = 40
        store.savePreset(named: " phone ", settings: settings)

        let reopened = ExportPresetStore(defaults: defaults)
        #expect(reopened.previous?.format == .heic)
        #expect(reopened.initialPresetID == saved.id)
        #expect(reopened.userPresets.count == 1)
        #expect(reopened.userPresets.first?.settings.quality == 40)
        #expect(reopened.presets.count == ExportPreset.builtIns.count + 1)

        reopened.deletePreset(saved.id)
        #expect(ExportPresetStore(defaults: defaults).userPresets.isEmpty)
        #expect(ExportPresetStore(defaults: defaults).previousPresetID == nil)
    }

    @Test func `export with previous needs a previous export`() async throws {
        let fixture = try await openEditor()
        defer { fixture.cleanup() }
        let (model, engine, folder) = (fixture.model, fixture.engine, fixture.folder)
        let store = ExportPresetStore(defaults: defaults())
        #expect(await ExportActions.previousExport(model: model, store: store) == .needsDialog)

        var settings = ExportSettings()
        settings.existingFiles = .addNumber
        store.recordExport(settings, presetID: nil)
        guard case let .ready(url, _) = await ExportActions.previousExport(model: model, store: store) else {
            Issue.record("expected a destination")
            return
        }
        #expect(url == folder.appending(path: "IMG_0001-redlamp.jpg"))
        try Data().write(to: url)
        guard case let .ready(numbered, _) = await ExportActions.previousExport(model: model, store: store) else {
            Issue.record("expected a destination")
            return
        }
        #expect(numbered.lastPathComponent == "IMG_0001-redlamp-2.jpg")
        #expect(engine.stills.isEmpty)
    }

    @Test func `Export with Previous works out where the export goes off the main thread`() async throws {
        let fixture = try await openEditor()
        defer { fixture.cleanup() }
        let (model, engine, folder) = (fixture.model, fixture.engine, fixture.folder)
        let files = ThreadRecordingFiles(delay: .milliseconds(100))
        engine.files = files
        // Not an export, as the reader reads it, so the export takes the next number.
        try Data("photo".utf8).write(to: folder.appending(path: "IMG_0001-redlamp.jpg"))
        let store = ExportPresetStore(defaults: defaults())
        store.recordExport(ExportSettings(), presetID: nil)

        ExportActions.exportWithPrevious(model: model, store: store)

        let numbered = folder.appending(path: "IMG_0001-redlamp-2.jpg")
        for _ in 0 ..< 500 where !FileManager.default.fileExists(atPath: numbered.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: numbered.path))
        #expect(!files.asked.isEmpty)
        #expect(files.mainThreadCalls.isEmpty, "\(files.mainThreadCalls) read on the main thread")
    }

    @Test(arguments: ExistingFilePolicy.allCases)
    func `no rule for existing files replaces the photo itself`(policy: ExistingFilePolicy) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appending(path: "IMG_0001.JPG")
        try Data("original".utf8).write(to: photo)
        var settings = ExportSettings()
        settings.naming = ExportNaming(suffix: "")
        settings.existingFiles = policy
        #expect(ExportActions.step(for: settings, photo: photo, reading: UnreadableFiles()) == .ready(
            folder.appending(path: "IMG_0001-2.jpg"), settings,
        ))
    }
}
