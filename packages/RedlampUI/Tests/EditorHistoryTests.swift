import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// History steps, sessions saved with the photo, and the sidebar list that shows them.
@MainActor
struct EditorHistoryTests {
    @MainActor private struct Editor {
        let model = EditorModel(engine: StubEngine())
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        var photo: URL {
            folder.appending(path: "IMG_0001.ARW")
        }

        var other: URL {
            folder.appending(path: "IMG_0002.ARW")
        }

        var historyDirectory: URL {
            SidecarStore().url(for: photo).appending(path: SidecarStore.historyDirectory)
        }

        var savedSessions: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: historyDirectory.path)) ?? []
        }
    }

    private func openEditor() async throws -> (Editor, () -> Void) {
        let editor = Editor()
        try FileManager.default.createDirectory(at: editor.folder, withIntermediateDirectories: true)
        try await open(editor.photo, in: editor.model)
        return (editor, { try? FileManager.default.removeItem(at: editor.folder) })
    }

    private func open(_ url: URL, in model: EditorModel) async throws {
        model.select(url)
        try await eventually { model.info?.url == url }
        try #require(model.info?.url == url)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Edits the photo, leaves it until its session is saved, and comes back.
    private func reopenAfterEditing(_ editor: Editor) async throws {
        editor.model.setValue(.exposure, 0.5)
        editor.model.setValue(.contrast, 20)
        try await open(editor.other, in: editor.model)
        try await eventually { !editor.savedSessions.isEmpty }
        try await open(editor.photo, in: editor.model)
        try await eventually { !editor.model.earlierSessions.isEmpty }
    }

    // MARK: - Steps

    @Test func `a slider step shows its value before and after`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        editor.model.setValue(.exposure, 0.5)
        let step = try #require(editor.model.history.last)
        #expect(step.action == .adjustment(.exposure))
        #expect(step.title == "Exposure")
        #expect(step.before == "0.00" && step.after == "+0.50")
    }

    @Test func `a drag is one step from the value it started at`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        let steps = model.history.count
        model.beginEdit(.contrast)
        model.setValue(.contrast, 10)
        model.setValue(.contrast, 30)
        model.endEdit()
        #expect(model.history.count == steps + 1)
        #expect(model.history.last?.name == "Contrast: 0 → +30")
    }

    @Test func `choices show what they changed from and to`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        model.setTreatment(.blackAndWhite)
        #expect(model.history.last?.action == .treatment)
        #expect(model.history.last?.name == "Treatment: Color → B&W")

        model.setValue(.exposure, 0.5)
        model.reset(.exposure)
        #expect(model.history.last?.action == .reset)
        #expect(model.history.last?.name == "Reset Exposure: +0.50 → 0.00")

        model.createSnapshot()
        let snapshot = try #require(model.snapshots.last)
        model.setValue(.contrast, 20)
        model.applySnapshot(snapshot)
        #expect(model.history.last?.action == .snapshot)
        #expect(model.history.last?.before == nil)
        #expect(model.history.last?.name == "Snapshot: \(snapshot.name)")
    }

    // MARK: - Sessions

    @Test func `reopening a photo starts a new session and lists the last one`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        #expect(model.history.map(\.title) == ["Import"])
        model.setValue(.exposure, 0.5)
        model.setValue(.contrast, 20)
        let steps = model.history.map(\.id)
        try await open(editor.other, in: model)
        try await eventually { !editor.savedSessions.isEmpty }
        try await open(editor.photo, in: model)
        try await eventually { !model.earlierSessions.isEmpty }

        #expect(model.history.map(\.title) == ["Opened"])
        #expect(model.history.first?.action == .open)
        #expect(model.earlierSessions.first?.steps.map(\.id) == steps)
        #expect(!model.canUndo, "undo stops at the session's first step")
    }

    @Test func `bringing back an earlier step adds it to this session`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        try await reopenAfterEditing(editor)
        let session = try #require(model.earlierSessions.first)
        let exposureStep = session.steps[1]

        model.restoreHistory(exposureStep, from: session)
        #expect(model.history.last?.action == .restore)
        #expect(model.value(.exposure) == 0.5 && model.value(.contrast) == 0)
        #expect(model.earlierSessions.first == session, "earlier sessions never change")
        model.undo()
        #expect(model.value(.exposure) == 0.5 && model.value(.contrast) == 20)
    }

    @Test func `only the steps up to the current one are saved`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        model.setValue(.exposure, 0.5)
        model.setValue(.contrast, 20)
        model.undo()
        model.saveNow()
        try await eventually { SidecarStore().loadHistory(for: editor.photo).first?.steps.count == 2 }
        #expect(SidecarStore().loadHistory(for: editor.photo).first?.steps.map(\.title) == ["Import", "Exposure"])
    }

    @Test func `a photo that was only looked at gets no sidecar`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        try await open(editor.other, in: editor.model)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!FileManager.default.fileExists(atPath: SidecarStore().url(for: editor.photo).path))
    }

    @Test func `clearing history removes the earlier sessions too`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        try await reopenAfterEditing(editor)

        model.clearHistory()
        #expect(model.earlierSessions.isEmpty)
        #expect(model.history.map(\.action) == [.clear])
        try await eventually { editor.savedSessions.isEmpty }
        #expect(editor.savedSessions.isEmpty)
    }

    @Test func `history keeps the sidecar of a photo whose edit is back to defaults`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        model.setValue(.exposure, 0.5)
        model.resetAll()
        try await open(editor.other, in: model)
        try await eventually { !editor.savedSessions.isEmpty }
        try await open(editor.photo, in: model)
        try await eventually { !model.earlierSessions.isEmpty }

        try await open(editor.other, in: model)
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.savedSessions.count == 1)
        #expect(SidecarStore().load(for: editor.photo)?.recipe.isPristine == true)
    }

    // MARK: - The sidebar's panels

    private func showLists(_ model: EditorModel) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let list = SidebarListView(model: model)
        window.contentView = list
        list.layoutSubtreeIfNeeded()
        return (list, window)
    }

    @Test func `choosing a history step keeps the column's scroll position`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        for value in 1 ... 40 {
            model.setValue(.contrast, Double(value))
        }
        let (list, window) = showLists(model)
        defer { window.contentView = nil }
        let clip = list.scrollView.contentView
        let document = try #require(list.scrollView.documentView)
        clip.scroll(to: CGPoint(x: 0, y: document.frame.height - clip.bounds.height))
        let scrolled = clip.bounds.origin.y
        #expect(scrolled > 0)

        model.goToHistory(10)
        let history = list.history
        let current = { (0 ..< history.numberOfRows).contains { row in
            guard let node = history.item(atRow: row) as? SidebarNode,
                  case let .history(_, index, isCurrent, _) = node.kind else { return false }
            return index == 10 && isCurrent
        } }
        try await eventually { current() }
        #expect(current(), "the list reloaded")
        #expect(clip.bounds.origin.y == scrolled)
    }

    @Test func `the recipes reloading with their groups open keeps the column's scroll position`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        for value in 1 ... 40 {
            model.setValue(.contrast, Double(value))
        }
        let (list, window) = showLists(model)
        defer { window.contentView = nil }
        let clip = list.scrollView.contentView
        let document = try #require(list.scrollView.documentView)
        clip.scroll(to: CGPoint(x: 0, y: document.frame.height - clip.bounds.height))
        let scrolled = clip.bounds.origin.y

        try model.applyRecipe(#require(model.recipes.all.first))
        let recipes = list.recipes
        let amount = { (0 ..< recipes.numberOfRows).contains { row in
            guard let node = recipes.item(atRow: row) as? SidebarNode,
                  case .recipeAmount = node.kind else { return false }
            return true
        } }
        try await eventually { amount() }
        #expect(amount(), "the recipes reloaded")
        #expect(clip.bounds.origin.y == scrolled)
    }

    @Test func `the left column's panels collapse, and Option-click shows only one`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        let (list, window) = showLists(model)
        defer { window.contentView = nil }
        #expect(list.history.window != nil)

        model.toggleSidebarSection(.history, solo: false)
        try await eventually { list.history.window == nil }
        #expect(list.history.window == nil, "a collapsed panel's rows leave the window")

        model.toggleSidebarSection(.recipes, solo: true)
        #expect(model.expandedSidebarSections == [.recipes])
        try await eventually { list.snapshots.window == nil }
        #expect(list.recipes.window != nil && list.snapshots.window == nil)
    }

    @Test func `recipe groups and earlier sessions collapse again`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        try await reopenAfterEditing(editor)
        let (list, window) = showLists(model)
        defer { window.contentView = nil }

        func node(in outline: SidebarOutlineView, where matches: (SidebarNode.Kind) -> Bool) -> SidebarNode? {
            (0 ..< outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? SidebarNode }
                .first { matches($0.kind) }
        }
        func isGroup(_ kind: SidebarNode.Kind) -> Bool {
            if case .group = kind {
                return true
            }
            return false
        }
        func isSession(_ kind: SidebarNode.Kind) -> Bool {
            if case .session = kind {
                return true
            }
            return false
        }
        for (outline, matches) in [(list.recipes, isGroup), (list.history, isSession)] {
            try await eventually { node(in: outline, where: matches) != nil }
            let row = try #require(node(in: outline, where: matches))
            outline.expandItem(row)
            #expect(outline.isItemExpanded(row))
            outline.collapseItem(row)
            #expect(!outline.isItemExpanded(row))
        }
    }

    @Test func `typing a recipe search keeps the field's focus as the list updates`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let (list, window) = showLists(editor.model)
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let field = try #require(descendants(list).compactMap { $0 as? NSSearchField }.first)
        #expect(window.makeFirstResponder(field))

        field.stringValue = "zzzz"
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(list.recipes.numberOfRows == 1, "only “No matching recipes”")
        #expect((window.firstResponder as? NSText)?.delegate === field)
    }

    // MARK: - Nudges

    /// Waits out the pause that ends a run of nudges.
    private func pause() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    @Test func `a run of nudges is one history step, from the value before it to the last`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        let steps = model.history.count
        let spec = ParameterID.exposure.spec
        let before = spec.formatted(model.recipe[.exposure])
        model.focusedParameter = .exposure
        for _ in 0 ..< 10 {
            model.perform(.increaseSetting)
        }
        let after = model.recipe[.exposure]
        try await pause()
        withKnownIssue("RESP-09: each nudge is a step of its own") {
            #expect(model.history.count == steps + 1)
            #expect(model.history.last?.before == before)
        }
        #expect(model.history.last?.after == spec.formatted(after))
        #expect(model.history.last?.recipe[.exposure] == after)
    }

    @Test func `undo during a run of nudges undoes all of it`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        let start = model.recipe[.exposure]
        model.focusedParameter = .exposure
        for _ in 0 ..< 3 {
            model.perform(.increaseSetting)
        }
        #expect(model.canPerform(.undo))
        model.perform(.undo)
        withKnownIssue("RESP-09: undo takes back only the last nudge") {
            #expect(model.recipe[.exposure] == start)
        }
        try await pause()
        withKnownIssue("RESP-09: undo takes back only the last nudge") {
            #expect(model.recipe[.exposure] == start, "the run's end records nothing after the undo")
        }
        #expect(model.canRedo)
    }

    @Test func `a nudge after a pause or on another setting starts a new step`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        let steps = model.history.count
        model.focusedParameter = .exposure
        model.perform(.increaseSetting)
        model.perform(.increaseSetting)
        model.perform(.nextSetting)
        #expect(model.focusedParameter == .contrast)
        model.perform(.increaseSetting)
        model.perform(.increaseSetting)
        try await pause()
        model.perform(.increaseSetting)
        try await pause()
        withKnownIssue("RESP-09: each nudge is a step of its own") {
            #expect(model.history.count == steps + 3)
            #expect(model.history.suffix(3).map(\.title) == ["Exposure", "Contrast", "Contrast"])
        }
    }

    @Test func `a run of nudges cut short by another photo is saved in its own photo's history`() async throws {
        let (editor, cleanup) = try await openEditor()
        defer { cleanup() }
        let model = editor.model
        let spec = ParameterID.exposure.spec
        let before = spec.formatted(model.recipe[.exposure])
        model.focusedParameter = .exposure
        for _ in 0 ..< 3 {
            model.perform(.increaseSetting)
        }
        let after = spec.formatted(model.recipe[.exposure])
        model.select(editor.other)
        try await eventually { model.info?.url == editor.other }
        try await eventually { !editor.savedSessions.isEmpty }
        try await open(editor.photo, in: model)
        try await eventually { !model.earlierSessions.isEmpty }
        #expect(spec.formatted(model.recipe[.exposure]) == after, "the run's values are saved either way")
        withKnownIssue("RESP-09: a run open when another photo is selected is dropped from the history") {
            let step = model.earlierSessions.first?.steps.last
            #expect(step?.title == "Exposure")
            #expect(step?.before == before)
            #expect(step?.after == after)
        }
    }
}
