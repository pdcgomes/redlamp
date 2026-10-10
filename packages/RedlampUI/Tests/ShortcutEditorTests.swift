import Foundation
import Testing
@testable import RedlampUI

/// Settings › Shortcuts (LIB-36): a key recorded by pressing it, saved at once when it collides with nothing, and
/// held with what it collides with until it's taken or cancelled; each test with a keymap of its own.
@MainActor
struct ShortcutEditorTests {
    private func editor(_ keymap: Keymap = .standard) -> ShortcutEditor {
        let store = ShortcutKeymap(defaults: nil)
        store.keymap = keymap
        return ShortcutEditor(store: store)
    }

    @Test func `a key that collides with nothing is saved as it's pressed, in place of the first key`() {
        let editor = editor()
        editor.record(.toggleZoom)
        editor.press(.char(";"))
        #expect(editor.pending == nil)
        #expect(editor.recording == nil)
        #expect(editor.keymap.combos(for: .toggleZoom) == [.char(";"), KeyCombo(.space)], "Space stays")
        #expect(editor.changeCount == 1)
    }

    @Test func `a key another action has waits with it, and is taken from it only when confirmed`() {
        let editor = editor()
        editor.record(.flagPick)
        editor.press(.char("x"))
        #expect(editor.pending?.conflicts == [.taken(by: .flagReject)])
        #expect(editor.keymap.combos(for: .flagPick) == [.char("p")], "nothing saved before it's settled")
        #expect(editor.keymap.combos(for: .flagReject) == [.char("x")])

        editor.confirm()
        #expect(editor.pending == nil)
        #expect(editor.keymap.combos(for: .flagPick) == [.char("x")])
        #expect(editor.keymap.combos(for: .flagReject).isEmpty)
        #expect(editor.keymap.resolve(.char("x"), in: .library)?.action == .flagPick)
    }

    @Test func `cancelling a key that collides leaves every key as it was`() {
        let editor = editor()
        editor.record(.flagPick)
        editor.press(.char("x"))
        editor.cancel()
        #expect(editor.pending == nil)
        #expect(editor.keymap == .standard)
    }

    @Test func `a key the Mac keeps can't be taken`() {
        let editor = editor()
        editor.record(.flagPick)
        editor.press(.char("w", command: true))
        #expect(editor.pending?.isReserved == true)
        editor.confirm()
        #expect(editor.pending != nil, "still waiting")
        #expect(editor.keymap == .standard)
    }

    @Test func `pressing the key the action already has changes nothing`() {
        let editor = editor()
        editor.record(.flagPick)
        editor.press(.char("p"))
        #expect(editor.recording == nil)
        #expect(editor.pending == nil)
        #expect(editor.keymap == .standard)
    }

    @Test func `another key is added beside the others, and one is removed leaving the rest`() {
        let editor = editor()
        editor.record(.flagPick, adding: true)
        editor.press(.char("k", option: true))
        #expect(editor.keymap.combos(for: .flagPick) == [.char("p"), .char("k", option: true)])
        editor.remove(.char("p"), from: .flagPick)
        #expect(editor.keymap.combos(for: .flagPick) == [.char("k", option: true)])
    }

    @Test func `an action given its preset's keys again takes them back from whoever has them`() {
        let editor = editor()
        editor.record(.flagReject)
        editor.press(.char("p"))
        editor.confirm()
        #expect(editor.keymap.combos(for: .flagPick).isEmpty)
        editor.reset(.flagPick)
        #expect(editor.keymap.combos(for: .flagPick) == [.char("p")])
        #expect(editor.keymap.combos(for: .flagReject).isEmpty, "it gives P back; its X went when P took its place")
    }

    @Test func `choosing a preset gives its keys, the changes going with the last one`() {
        let editor = editor()
        editor.record(.flagPick)
        editor.press(.char(";"))
        editor.choose(.photoMechanic)
        #expect(editor.keymap == Keymap(preset: .photoMechanic))
        #expect(editor.keymap.combos(for: .flagPick) == [.char("p")])
        editor.record(.flagPick)
        editor.press(.char(";"))
        editor.resetAll()
        #expect(editor.keymap == Keymap(preset: .photoMechanic))
    }

    @Test func `the search finds actions by their titles, the palette's words for them, and a key`() {
        let editor = editor()
        editor.search = "reject"
        #expect(editor.sections.flatMap(\.1).contains(.flagReject))
        editor.search = "quick collection"
        #expect(editor.sections.flatMap(\.1).contains(.toggleMark))
        editor.search = "f2"
        #expect(editor.sections.flatMap(\.1) == [.renamePhotos])
        editor.search = ""
        #expect(editor.sections.flatMap(\.1).count == ShortcutAction.allCases.count, "every action, keys or not")
    }

    @Test func `a planned action's key isn't recorded`() {
        let editor = editor()
        editor.record(.virtualCopy)
        #expect(editor.recording == nil)
    }
}
