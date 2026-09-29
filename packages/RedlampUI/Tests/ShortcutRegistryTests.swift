import RedlampUI
import Testing

struct ShortcutRegistryTests {
    @Test func `every key combo belongs to exactly one action`() {
        var owners: [KeyCombo: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            for combo in action.combos {
                #expect(owners[combo] == nil, "\(combo.display) is bound to both \(owners[combo]!) and \(action)")
                owners[combo] = action
            }
        }
    }

    @Test func `every action has a key and a title`() {
        for action in ShortcutAction.allCases {
            #expect(!action.combos.isEmpty, "\(action) has no key")
            #expect(!action.title.isEmpty)
        }
    }

    @Test func `command shortcuts can be menu items`() {
        for action in ShortcutAction.allCases where action.isMenuShortcut {
            #expect(action.combos.first?.keyboardShortcut != nil, "\(action) cannot be a menu key equivalent")
        }
    }

    @Test func `shift variants resolve exactly before shift-accepting fallbacks`() {
        #expect(ShortcutAction.resolve(.char("w"))?.action == .whiteBalanceSelector)
        #expect(ShortcutAction.resolve(.char("w", shift: true))?.action == .maskingTool)
        #expect(ShortcutAction.resolve(.char("m", shift: true))?.action == .radialMask)
        #expect(ShortcutAction.resolve(.char("z", shift: true))?.action == .depthRangeMask)
    }

    @Test func `shift with a rating key advances`() {
        let resolved = ShortcutAction.resolve(.char("3", shift: true))
        #expect(resolved?.action == .rating3)
        #expect(resolved?.shifted == true)
        #expect(ShortcutAction.resolve(.char("3"))?.shifted == false)
    }

    @Test func `lightroom classics are bound`() {
        #expect(ShortcutAction.resolve(.char("\\"))?.action == .beforeAfter)
        #expect(ShortcutAction.resolve(.char("j"))?.action == .clipping)
        #expect(ShortcutAction.resolve(KeyCombo(.tab))?.action == .toggleSidePanels)
        #expect(ShortcutAction.resolve(.char("c", shift: true, command: true))?.action == .copySettings)
        #expect(ShortcutAction.resolve(.char("u", command: true))?.action == .autoTone)
        #expect(ShortcutAction.resolve(.char("x"))?.action == .flagReject)
    }
}
