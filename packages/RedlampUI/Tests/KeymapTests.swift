import AppKit
import Foundation
import Testing
@_spi(Harness) @testable import RedlampUI

/// The keys as customised (LIB-36): presets, changes kept by the action's ID, what a key collides with, and the
/// app reading the keymap a test stands in rather than the app's.
struct KeymapTests {
    @Test func `a key reads back from the form the preferences keep it in`() {
        let keys: [KeyCombo] = [
            .char("e", shift: true, command: true), .char("1", command: true, control: true), .char("\\"),
            .char("["), KeyCombo(.tab, shift: true), KeyCombo(.delete, option: true), KeyCombo(.function(12)),
            KeyCombo(.left, option: true, command: true), KeyCombo(.space), .char("é"),
        ]
        for key in keys {
            #expect(KeyCombo(stored: key.stored) == key, "\(key.display) as \(key.stored)")
        }
        #expect(KeyCombo(stored: "⌘") == .char("⌘"))
        #expect(KeyCombo(stored: "") == nil)
        #expect(KeyCombo(stored: "⌘enter") == nil)
    }

    @Test func `the standard keymap is Redlamp's own keys, Lightroom Classic's`() {
        for action in ShortcutAction.allCases {
            #expect(Keymap.standard.combos(for: action) == action.defaultCombos, "\(action)")
        }
        #expect(Keymap.standard.changes.isEmpty)
    }

    @Test(arguments: KeymapPreset.allCases)
    func `every preset gives each key to one action in each module`(preset: KeymapPreset) {
        let keymap = Keymap(preset: preset)
        let clashes = keymap.clashes.map { "\($0.0.display): \($0.1) and \($0.2)" }
        #expect(clashes.isEmpty, "\(preset.title): \(clashes)")
        for module in AppModule.allCases {
            for action in ShortcutAction.allCases where action.applies(in: module) {
                for combo in keymap.combos(for: action) {
                    #expect(keymap.resolve(combo, in: module)?.action == action, "\(combo.display) in \(module)")
                }
            }
        }
    }

    @Test(arguments: KeymapPreset.allCases)
    func `no preset takes a key the Mac or the app's own menus keep, and its ⌘ keys can be menu items`(
        preset: KeymapPreset,
    ) {
        let keymap = Keymap(preset: preset)
        for action in ShortcutAction.allCases {
            for combo in keymap.combos(for: action) {
                #expect(Keymap.reserved[combo] == nil, "\(preset.title) gives \(action) \(combo.display)")
                if combo.command {
                    #expect(combo.keyboardShortcut != nil, "\(combo.display) can't be a key equivalent")
                }
            }
        }
    }

    @Test func `Photo Mechanic's keys rate on ⌃0 to ⌃5, label on ⌘1 to ⌘5, and move the panels to ⌃⌘1 to ⌃⌘9`() {
        let keymap = Keymap(preset: .photoMechanic)
        #expect(keymap.resolve(.char("3", control: true), in: .library)?.action == .rating3)
        #expect(keymap.resolve(.char("3"), in: .library)?.action == .rating3, "with single keys on")
        #expect(keymap.resolve(.char("0", control: true), in: .develop)?.action == .rating0)
        #expect(keymap.resolve(.char("1", command: true), in: .develop)?.action == .labelRed)
        #expect(keymap.resolve(.char("5", command: true), in: .library)?.action == .labelPurple)
        #expect(keymap.resolve(.char("0", command: true), in: .library)?.action == .clearLabel)
        #expect(keymap.resolve(.char("1", command: true, control: true), in: .develop)?.action == .panelBasic)
        #expect(keymap.resolve(.char("t"), in: .library)?.action == .toggleMark)
        #expect(keymap.resolve(.char("g", command: true), in: .library)?.action == .importPhotos)
        #expect(keymap.resolve(.char("b", command: true), in: .library)?.action == .addToTargetCollection)
        #expect(keymap.resolve(.char("f", command: true), in: .library)?.action == .toggleFilterBar)
        #expect(keymap.resolve(.char("f", command: true), in: .develop)?.action == .findAdjustment)
        #expect(keymap.combos(for: .stackPhotos).isEmpty, "⌘G imports")
        #expect(keymap.resolve(.char("6"), in: .library) == nil, "6 to 9 are Lightroom's labels")
    }

    @Test func `Bridge's keys rate on ⌘0 to ⌘5, label on ⌘6 to ⌘9, reject on ⌥⌫ and open Develop on ⌘R`() {
        let keymap = Keymap(preset: .bridge)
        #expect(keymap.resolve(.char("4", command: true), in: .library)?.action == .rating4)
        #expect(keymap.resolve(.char("4"), in: .library)?.action == .rating4)
        #expect(keymap.resolve(.char("6", command: true), in: .develop)?.action == .labelRed)
        #expect(keymap.resolve(.char("9", command: true), in: .library)?.action == .labelBlue)
        #expect(keymap.resolve(KeyCombo(.delete, option: true), in: .library)?.action == .flagReject)
        #expect(keymap.resolve(.char("r", command: true), in: .library)?.action == .developModule)
        #expect(keymap.resolve(.char("r", shift: true, command: true), in: .library)?.action == .renamePhotos)
        #expect(keymap.resolve(KeyCombo(.space), in: .library)?.action == .fullScreenPreview)
        #expect(keymap.resolve(.char("=", command: true), in: .library)?.action == .largerThumbnails)
        #expect(keymap.resolve(.char("=", command: true), in: .develop)?.action == .zoomIn)
        #expect(keymap.combos(for: .labelPurple).isEmpty, "Bridge has no key for purple")
    }

    @Test func `keys changed back to the preset's are no change`() {
        var keymap = Keymap(preset: .bridge)
        keymap.setCombos([.char("k")], for: .flagPick)
        #expect(keymap.isChanged(.flagPick))
        #expect(keymap.combos(for: .flagPick) == [.char("k")])
        keymap.setCombos(KeymapPreset.bridge.combos(for: .flagPick), for: .flagPick)
        #expect(keymap.changes.isEmpty)
        keymap.setCombos([.char("k"), .char("k"), .char("p")], for: .flagPick)
        #expect(keymap.combos(for: .flagPick) == [.char("k"), .char("p")], "once each")
        keymap.reset(.flagPick)
        #expect(!keymap.isChanged(.flagPick))
    }

    @Test func `a key collides with the actions that have it where both run, and not one in the other module`() {
        let keymap = Keymap.standard
        #expect(Set(keymap.conflicts(assigning: .char("j"), to: .flagPick)) == [
            .taken(by: .clipping), .taken(by: .cycleGridStyle),
        ])
        #expect(keymap.conflicts(assigning: .char("j"), to: .zoomIn) == [.taken(by: .clipping)], "Develop's only")
        #expect(keymap.conflicts(assigning: .char(";"), to: .flagPick).isEmpty)
        #expect(keymap.conflicts(assigning: .char("p"), to: .flagPick).isEmpty, "its own key")
    }

    @Test func `a key another action answers with ⇧ as a variant is shown, and doesn't block`() {
        let conflicts = Keymap.standard.conflicts(assigning: .char("1", shift: true), to: .toggleMark)
        #expect(conflicts == [.shiftVariant(of: .rating1)])
        #expect(conflicts.allSatisfy { !$0.blocks })
    }

    @Test func `the Mac's and the app's own keys can't be taken`() {
        let conflicts = Keymap.standard.conflicts(assigning: .char("q", command: true), to: .flagPick)
        #expect(conflicts == [.reserved("Quit Redlamp")])
        let blocks = conflicts.allSatisfy(\.blocks)
        #expect(blocks)
    }

    @Test func `the keymap is kept by the actions' IDs, and what this version doesn't know is passed over`() throws {
        var keymap = Keymap(preset: .photoMechanic)
        keymap.setCombos([.char("3", option: true, control: true)], for: .panelColorMixer)
        let data = try JSONEncoder().encode(keymap)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("panelColorMixer"))
        #expect(text.contains("photoMechanic"))
        #expect(try JSONDecoder().decode(Keymap.self, from: data) == keymap)

        let later = Data(#"{"preset":"capture","keys":{"flagPick":["k"],"someLaterAction":["⌘j"]}}"#.utf8)
        let read = try JSONDecoder().decode(Keymap.self, from: later)
        #expect(read.preset == .lightroomClassic)
        #expect(read.changes == [.flagPick: [.char("k")]])
    }

    @Test func `the app's keymap is saved as it changes and read back at the next launch`() throws {
        let suite = "app.redlamp.tests.keymap.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutKeymap(defaults: defaults)
        #expect(store.keymap == .standard)
        store.update { $0.preset = .bridge }
        store.update { $0.setCombos([.char("k")], for: .flagPick) }
        let relaunched = ShortcutKeymap(defaults: defaults)
        #expect(relaunched.keymap.preset == .bridge)
        #expect(relaunched.keymap.combos(for: .flagPick) == [.char("k")])
    }

    @Test func `the actions, the sheet and the key monitor follow the keymap a task stands in`() {
        var keymap = Keymap(preset: .bridge)
        keymap.setCombos([.char("k", command: true)], for: .flagPick)
        ShortcutKeymap.$override.withValue(keymap) {
            #expect(ShortcutAction.rating1.combos.first == .char("1", command: true))
            #expect(ShortcutAction.resolve(.char("k", command: true), in: .library)?.action == .flagPick)
            #expect(ShortcutAction.flagPick.isMenuShortcut)
            #expect(!ShortcutAction.byCategory.flatMap(\.1).contains(.showInFinder), "Bridge gives ⌘R to Develop")
        }
        #expect(ShortcutAction.rating1.combos.first == .char("1"))
    }

    @Test func `⌘N is New Collection's item's key in Library and New Snapshot's in Develop`() {
        let keymap = Keymap.standard
        #expect(keymap.menuCarriesKey(of: .newCollection, in: .library))
        #expect(!keymap.menuCarriesKey(of: .newCollection, in: .develop))
        #expect(keymap.menuCarriesKey(of: .newSnapshot, in: .develop))
        #expect(!keymap.menuCarriesKey(of: .newSnapshot, in: .library))
        #expect(keymap.menuCarriesKey(of: .stackPhotos, in: .develop), "the item keeps a key no other action has")
        #expect(!keymap.menuCarriesKey(of: .flagPick, in: .library), "a single key is shown in the title")
        #expect(Set(keymap.moduleKeyedActions) == [.newCollection, .newSnapshot])

        let bridge = Keymap(preset: .bridge)
        #expect(bridge.menuCarriesKey(of: .largerThumbnails, in: .library))
        #expect(!bridge.menuCarriesKey(of: .largerThumbnails, in: .develop))
        #expect(bridge.menuCarriesKey(of: .zoomIn, in: .develop))
        #expect(!bridge.menuCarriesKey(of: .zoomIn, in: .library))
    }

    @MainActor
    @Test func `a key comes from a key press as the key monitor reads it`() throws {
        func press(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> KeyCombo? {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code,
            ))
            return KeyCombo(event: event)
        }
        #expect(try press(48, "\t", .shift) == KeyCombo(.tab, shift: true))
        #expect(try press(99, "\u{F706}", .function) == KeyCombo(.function(3)))
        #expect(try press(51, "\u{7F}", .option) == KeyCombo(.delete, option: true))
        #expect(try press(36, "\r") == nil, "Return")
        #expect(try press(115, "\u{F729}") == nil, "Home")
        #expect(try press(99, "\u{F706}")?.isMonitored == false, "F3 isn't the key monitor's")
        #expect(try press(96, "\u{F708}")?.isMonitored == true, "F5 is")
    }
}
