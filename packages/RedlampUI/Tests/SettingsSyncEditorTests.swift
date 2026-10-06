import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// A batch of Settings Sync reaching the photo open in the editor changes it there, as a step of
/// its history, rather than writing its sidecar behind the editor (CONC-06); a photo edited
/// between the batch's read and its write is left as it was edited.
@MainActor
struct SettingsSyncEditorTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private let a: URL
    private let b: URL
    private let c: URL
    private let store = SidecarStore()
    private let engine = StubEngine()
    private let worker = StubEngine()
    private let model: EditorModel

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        (a, b, c) = (folder.appending(path: "A.ARW"), folder.appending(path: "B.ARW"), folder.appending(path: "C.ARW"))
        model = EditorModel(engine: engine)
        model.makeWorkerEngine = { [worker] in worker }
        [a, b, c].forEach { model.library.insert(LibraryItem(url: $0)) }
        model.copySelection = .default
    }

    private func open(_ url: URL) async throws {
        model.select(url, keepingSelection: true)
        for _ in 0 ..< 2000 where model.info?.url != url || model.isLoading {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == url)
    }

    /// A open with Exposure 1, and A, B and C selected.
    private func start() async throws {
        try await open(a)
        model.setValue(.exposure, 1)
        model.selectAllPhotos()
    }

    private func subject(_ hash: String) -> AIMask {
        AIMask(
            kind: .subject, provider: "stub", revision: 1, analysisHash: hash,
            center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: hash, width: 4, height: 4),
        )
    }

    /// Opens `url` in the editor, gives it Exposure 3 and goes back to A, its save landed.
    private func edit(_ url: URL) async {
        try? await open(url)
        model.setValue(.exposure, 3)
        try? await open(a)
        model.saveNow()
        await model.saves.wait(for: url)
    }

    private let damaged = Data(#"{"format":"app.redlamp.edit","recipe":{"version":3,"#.utf8)

    private func damage(_ url: URL) {
        try? damaged.write(to: store.editURL(for: url))
    }

    @Test func `a sync reaches a photo opened while its edit is worked out as a step of the editor's history`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await start()
        model.settingsSync.beforeWriting = { [self] url in
            if url == b {
                try? await open(b)
            }
        }
        model.syncSettings()
        await model.settingsSync.idle()

        #expect(model.info?.url == b)
        withKnownIssue {
            #expect(model.recipe[.exposure] == 1, "the editor shows the sync")
            #expect(model.history.last?.name == "Sync Settings")
        }
        #expect(store.load(for: c)?.recipe[.exposure] == 1, "C, in the background")
        model.undo()
        #expect(model.recipe[.exposure] == 0, "the editor's Undo takes it back")
    }

    @Test func `a sync reaches a photo opened before the batch gets to it as a step of the editor's history`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await start()
        model.settingsSync.beforeWriting = { [self] url in
            if url == b {
                try? await open(c)
            }
        }
        model.syncSettings()
        await model.settingsSync.idle()

        #expect(model.info?.url == c)
        withKnownIssue {
            #expect(model.recipe[.exposure] == 1)
            #expect(model.history.last?.name == "Sync Settings")
        }
        #expect(store.load(for: b)?.recipe[.exposure] == 1)
    }

    @Test func `Update AI Masks across the selection updates a photo opened meanwhile in the editor`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        engine.computed = [subject("editor")]
        worker.computed = [subject("worker")]
        try await start()
        await model.createAIMask(.subject)
        model.syncSettings()
        await model.settingsSync.idle()
        engine.computed = [subject("editor, updated")]
        worker.computed = [subject("worker, updated")]
        model.settingsSync.beforeWriting = { [self] url in
            if url == b {
                try? await open(b)
            }
        }
        await model.updateAIMasksInSelection()
        await model.settingsSync.idle()

        #expect(model.info?.url == b)
        withKnownIssue {
            #expect(model.history.last?.name == "Update AI Masks")
            guard case let .ai(mask)? = model.recipe.masks.first?.components.first?.shape else {
                Issue.record("B has no AI mask")
                return
            }
            #expect(mask.analysisHash == "editor, updated", "computed by the editor for B")
        }
    }

    @Test func `Undo Sync puts the open photo back as a step of the editor's history`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await start()
        model.syncSettings()
        await model.settingsSync.idle()
        try await open(b)
        try #require(model.recipe[.exposure] == 1)

        model.undoSync()
        await model.settingsSync.idle()
        withKnownIssue {
            #expect(model.recipe[.exposure] == 0, "the editor shows B put back")
            #expect(model.history.last?.name == "Undo Sync Settings")
        }
        #expect(store.load(for: c) == nil, "C, in the background")
    }

    @Test func `Undo Sync leaves a photo edited between its read and its write as it was edited`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await start()
        model.syncSettings()
        await model.settingsSync.idle()
        model.settingsSync.beforeWriting = { [self] url in
            if url == b {
                await edit(b)
            }
        }
        model.undoSync()
        await model.settingsSync.idle()

        withKnownIssue {
            #expect(store.load(for: b)?.recipe[.exposure] == 3)
        }
        #expect(store.load(for: c) == nil)
    }

    @Test func `a sync leaves a photo edited between its read and its write as it was edited`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await start()
        model.copySelection = SettingsSelection(items: ["basic.contrast"], masks: false)
        model.setValue(.contrast, 20)
        model.settingsSync.beforeWriting = { [self] url in
            if url == b {
                await edit(b)
            }
        }
        model.syncSettings()
        await model.settingsSync.idle()

        withKnownIssue {
            #expect(store.load(for: b)?.recipe[.exposure] == 3, "the edit made meanwhile is kept")
            #expect(model.settingsSync.report?.contains("edited while") == true)
        }
        #expect(store.load(for: c)?.recipe[.contrast] == 20)
        model.copySelection = .default
    }

    /// DATA-18: nothing ever writes over a sidecar that can't be read, even one damaged after the
    /// batch read it.
    @Test func `neither a sync nor its undo writes over a sidecar that stopped reading after the batch read it`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await start()
        model.syncSettings()
        await model.settingsSync.idle()
        model.settingsSync.beforeWriting = { [self] url in
            if url == b {
                damage(b)
            }
        }
        model.undoSync()
        await model.settingsSync.idle()
        #expect(try Data(contentsOf: store.editURL(for: b)) == damaged, "Undo Sync")
        withKnownIssue {
            #expect(model.settingsSync.report?.contains("can't be read") == true)
        }

        try? FileManager.default.removeItem(at: store.url(for: b))
        model.setValue(.exposure, 2)
        model.syncSettings()
        await model.settingsSync.idle()
        #expect(try Data(contentsOf: store.editURL(for: b)) == damaged, "Sync Settings")
        withKnownIssue {
            #expect(model.settingsSync.report?.contains("can't be read") == true)
        }
        #expect(store.load(for: c)?.recipe[.exposure] == 2)
    }
}
