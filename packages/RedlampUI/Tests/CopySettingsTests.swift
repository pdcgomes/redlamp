import AppKit
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Copy Settings, Paste and Previous by the checklist.
@MainActor
struct CopySettingsTests {
    private func open(_ model: EditorModel, _ url: URL) async throws {
        model.select(url)
        for _ in 0 ..< 200 where model.info?.url != url {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info?.url == url)
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The first choice carries tone and presence but not the crop; a slider the source left
    /// alone resets the target's.
    @Test func `paste takes what the last choice ticked`() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        model.copySelection = .default
        try await open(model, folder.appending(path: "A.ARW"))
        model.setValue(.exposure, 1)
        var cropped = model.recipe
        cropped.crop = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9)
        model.commit(cropped, .crop, "Crop")
        model.copySettings()

        try await open(model, folder.appending(path: "B.ARW"))
        model.setValue(.clarity, 15)
        model.pasteSettings()
        #expect(model.recipe[.exposure] == 1)
        #expect(model.recipe[.clarity] == 0, "the source's untouched clarity resets this photo's")
        #expect(model.recipe.crop.isFull, "crop is off the first time")
        #expect(model.history.last?.name == "Paste Settings")
    }

    /// The checklist opens with the last choice, and what it ticks is copied and remembered.
    @Test func `the checklist chooses what is copied, and is remembered`() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        model.copySelection = .default
        try await open(model, folder.appending(path: "A.ARW"))
        model.setValue(.exposure, 1)
        model.setValue(.contrast, 25)
        model.chooseSettingsToCopy()
        var chosen = try #require(model.settingsChooser).selection
        #expect(chosen == SettingsSelection.default)
        chosen.items.remove("basic.exposure")
        model.confirmSettingsChoice(chosen)
        #expect(model.settingsChooser == nil)
        #expect(!model.copySelection.items.contains("basic.exposure"))
        #expect(SettingsSelection.saved().items == model.copySelection.items)

        try await open(model, folder.appending(path: "B.ARW"))
        model.setValue(.exposure, -1)
        model.pasteSettings()
        #expect(model.recipe[.exposure] == -1, "exposure was left out")
        #expect(model.recipe[.contrast] == 25)
        model.copySelection = .default
    }

    /// Pasting the same masks twice leaves one of each; the photo's own AI masks aren't
    /// recomputed, only the pasted ones.
    @Test func `pasted masks merge, and only pasted AI masks are recomputed`() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.computed = [AIMask(
            kind: .subject, provider: "stub", revision: 1, analysisHash: "h", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(sha256: "s", width: 4, height: 4),
        )]
        let model = EditorModel(engine: engine)
        model.copySelection = .default
        try await open(model, folder.appending(path: "A.ARW"))
        await model.createAIMask(.subject)
        model.copySettings()

        try await open(model, folder.appending(path: "B.ARW"))
        await model.createAIMask(.sky)
        let before = engine.requests.count
        model.pasteSettings()
        model.pasteSettings()
        for _ in 0 ..< 200 where engine.requests.count < before + 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.recipe.masks.count == 2, "the photo's own sky and the pasted subject, once")
        #expect(engine.requests.dropFirst(before).allSatisfy { $0.kind == .subject })
    }

    /// The checklist is taller than the editor window at its smallest (#290): it fits below the
    /// toolbar, its buttons on the window, and the groups scroll.
    @Test func `the checklist fits on the editor window at its smallest`() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        let controller = EditorWindowController(
            model: model, theme: ThemeSettings(), onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        defer {
            model.settingsChooser = nil
            window.orderOut(nil)
        }
        window.setContentSize(window.contentMinSize)
        window.orderFront(nil)
        try await open(model, folder.appending(path: "A.ARW"))
        model.chooseSettingsToCopy()
        for _ in 0 ..< 400 where window.attachedSheet?.frame.height ?? 0 < 100 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        let sheet = try #require(window.attachedSheet)
        #expect(window.frame.contains(sheet.frame), "\(sheet.frame) hangs past \(window.frame)")
        #expect(sheet.frame.height >= 400)
    }
}
