import Testing
@_spi(Harness) @testable import RedlampUI

struct ShortcutRegistryTests {
    @Test func `every key combo belongs to exactly one action in each module`() {
        for module in AppModule.allCases {
            var owners: [KeyCombo: ShortcutAction] = [:]
            for action in ShortcutAction.allCases
                where module == .library ? !action.isDevelopOnly : !action.isLibraryOnly {
                for combo in action.combos {
                    #expect(
                        owners[combo] == nil,
                        "\(combo.display) is bound to both \(owners[combo].map { "\($0)" } ?? "") and \(action) in \(module)",
                    )
                    owners[combo] = action
                    #expect(
                        ShortcutAction.resolve(combo, in: module)?.action == action,
                        "\(combo.display) in \(module)",
                    )
                }
            }
        }
    }

    @Test func `the Library's J, = and - are its grid's, and Develop's are Develop's`() {
        #expect(ShortcutAction.resolve(.char("j"), in: .library)?.action == .cycleGridStyle)
        #expect(ShortcutAction.resolve(.char("="), in: .library)?.action == .largerThumbnails)
        #expect(ShortcutAction.resolve(.char("-"), in: .library)?.action == .smallerThumbnails)
        #expect(ShortcutAction.resolve(.char("j"), in: .develop)?.action == .clipping)
        #expect(ShortcutAction.resolve(.char("=", shift: true), in: .develop)?.action == .increaseSetting)
        #expect(ShortcutAction.resolve(.char("r", command: true), in: .library)?.action == .showInFinder)
        #expect(ShortcutAction.resolve(.char("z"), in: .library)?.action == .toggleZoom, "Z zooms the loupe")
    }

    @Test func `every action has a title`() {
        for action in ShortcutAction.allCases {
            #expect(!action.title.isEmpty)
        }
    }

    @Test func `the shortcuts sheet lists every action with a key, and only those`() {
        let listed = ShortcutAction.byCategory.flatMap(\.1)
        #expect(listed.count == Set(listed).count)
        #expect(Set(listed) == Set(ShortcutAction.allCases.filter { !$0.combos.isEmpty }))
    }

    @MainActor
    @Test func `an action without a key is in the command palette`() {
        for action in ShortcutAction.allCases where action.combos.isEmpty {
            #expect(!PaletteCatalog.keyOnlyActions.contains(action), "\(action) has no key and isn't in the palette")
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
        #expect(ShortcutAction.resolve(.char("y"))?.action == .nextCompareLayout)
        #expect(ShortcutAction.resolve(.char("y", shift: true))?.action == .previousCompareLayout)
        #expect(ShortcutAction.resolve(.char("j"))?.action == .clipping)
        #expect(ShortcutAction.resolve(KeyCombo(.tab))?.action == .toggleSidePanels)
        #expect(ShortcutAction.resolve(.char("c", shift: true, command: true))?.action == .copySettings)
        #expect(ShortcutAction.resolve(.char("u", command: true))?.action == .autoTone)
        #expect(ShortcutAction.resolve(.char("x"))?.action == .flagReject)
    }
}
