#if DEBUG || REDLAMP_PROFILING
    import AppKit
    @_spi(Harness) import RedlampUI

    /// The menu bar's keys against what its items show (LIB-14). SwiftUI sets a top-level menu's items' targets, which
    /// AppKit enables them by, only as the menu opens, and AppKit's search for a key equivalent doesn't open it.
    enum MenuBarScenarios {
        static let all: [Scenario] = [keysAfterMenu]

        /// ⌘R (Show in Finder, in the Photo menu) and ⌘1 (Basic Panel, in a submenu of View), each after its menu was
        /// opened while a dialog held the items, as during an export: once the dialog is over, a moment before the
        /// key or in the key's own turn, the key runs it. The keys go in as the keyboard's do, through the app's event
        /// handling, with no menu opened for them.
        static let keysAfterMenu = Scenario(
            "menus.keys-after-menu",
            "A ⌘ key runs its item once its action can run, though its menu last showed the item disabled",
            tiers: [.smoke, .full], claims: [],
        ) { app in
            try app.open(app.workingPhoto())
            try app.main { $0.libraryViews.revealInFinder = { Revealed.photos.append(contentsOf: $0) } }
            defer { try? app.main { $0.libraryViews.revealInFinder = Revealed.finder } }
            let checks: [(ShortcutAction, @MainActor (EditorModel) -> String)] = [
                (.showInFinder, { _ in "\(Revealed.photos.count)" }),
                (.panelBasic, { "\($0.expandedPanels.contains(.basic))" }),
            ]
            for (action, observe) in checks {
                guard let combo = action.combos.first else { throw ScenarioFailure("\(action.title) has no key") }
                let title = Menus.title(of: action)
                for sameTurn in [false, true] {
                    try app.main { MenuBarProbe.shared.holdDialog(true, on: $0) }
                    app.pause(0.3)
                    try app.expect(
                        try !app.menuItem(title).enabled,
                        "\(title) is enabled while a dialog holds the items",
                    )
                    let before = try app.main(observe)
                    if sameTurn {
                        let key = try app.main { _ in try Keyboard.event(combo) }
                        try app.main { model in
                            MenuBarProbe.shared.holdDialog(false, on: model)
                            NSApp.sendEvent(key)
                        }
                    } else {
                        try app.main { MenuBarProbe.shared.holdDialog(false, on: $0) }
                        app.pause(0.3)
                        try app.press(combo)
                    }
                    try app.wait(
                        "\(combo.display) to run \(title)\(sameTurn ? ", pressed as the dialog ended" : "")",
                        timeout: 3,
                    ) { observe($0) != before }
                }
            }
        }
    }
#endif
