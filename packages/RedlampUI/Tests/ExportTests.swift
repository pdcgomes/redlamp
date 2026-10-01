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
        let url = try ExportDestination.url(for: #require(model.info).url, settings: settings)
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
        #expect(ExportActions.previousExport(model: model, store: store) == .needsDialog)

        var settings = ExportSettings()
        settings.existingFiles = .addNumber
        store.recordExport(settings, presetID: nil)
        guard case let .ready(url, _) = ExportActions.previousExport(model: model, store: store) else {
            Issue.record("expected a destination")
            return
        }
        #expect(url == folder.appending(path: "IMG_0001-redlamp.jpg"))
        try Data().write(to: url)
        guard case let .ready(numbered, _) = ExportActions.previousExport(model: model, store: store) else {
            Issue.record("expected a destination")
            return
        }
        #expect(numbered.lastPathComponent == "IMG_0001-redlamp-2.jpg")
        #expect(engine.stills.isEmpty)
    }
}
