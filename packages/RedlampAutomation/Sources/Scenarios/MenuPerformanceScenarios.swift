#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampDesign
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The menu bar's cost (LIB-14): SwiftUI asks every item what it shows again whenever anything the menus read
    /// changes. A rebuild timed by itself in Develop, in the grid of a copy of lib-20k (or of `REDLAMP_MENU_FIXTURE`)
    /// and with all its photos selected, the menus' checks timed alone, and the rebuilds counted while → is held in the
    /// grid, while stacks open and close, and as a dialog starts and ends, the main thread watched through each. Held
    /// arrows that rebuild the menus once in ten presses or more fail it. With `REDLAMP_MENU_PROFILE` set, the main
    /// thread is sampled through each phase too. The copy is the scenario's own, a clone in the external disk's scratch
    /// folder, removed afterwards; nothing of the fixture's is touched.
    enum MenuPerformanceScenarios {
        static let all: [Scenario] = [menuBar]

        static let fixture = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["REDLAMP_MENU_FIXTURE"]
                ?? "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-20k",
            isDirectory: true,
        )

        static let menuBar = Scenario(
            "performance.menu-bar",
            "The menu bar's rebuilds timed by themselves in Develop and in the grid of a copy of lib-20k (or of "
                + "REDLAMP_MENU_FIXTURE), and counted through held arrow keys, stacks opened and closed, and dialogs",
            tiers: [.performance], claims: [],
        ) { app in
            var lines: [String] = []
            defer {
                try? (lines.joined(separator: "\n") + "\n").write(
                    to: app.runDirectory.appending(path: "menu-performance.txt"), atomically: true, encoding: .utf8,
                )
            }
            let mainThread = try app.main { _ in mach_thread_self() }
            let profiling = ProcessInfo.processInfo.environment["REDLAMP_MENU_PROFILE"] != nil
            func watched(_ name: String, _ body: () throws -> Void) throws -> String {
                app.step(name)
                let profile = profiling ? StackPerformanceScenarios.StackCallProfile(thread: mainThread) : nil
                defer {
                    for marker in ["Commands", "makeMainMenu"] {
                        profile?.write(
                            to: app.runDirectory.appending(path: "menu-profile-\(name)-\(marker).txt"), inside: marker,
                        )
                    }
                }
                let mark = try app.menuMark()
                let phase = try app.watchingMainThread(name, body)
                return try String(
                    format: "%@: %.2f s, main thread p99 %.2f ms, max %.1f ms, %d of %d turns over 8.3 ms; ", name,
                    phase.seconds, phase.summary?.p99 ?? -1, phase.summary?.max ?? -1, phase.summary?.overFrame ?? -1,
                    phase.summary?.iterations ?? -1,
                ) + Self.describe(app.menuRebuilds(since: mark))
            }

            // The first dialog of the launch, then a rebuild by itself and the checks alone, in Develop.
            try app.settle(timeout: 60)
            try app.main { _ in
                try? Self.anatomy().joined(separator: "\n").write(
                    to: app.runDirectory.appending(path: "menu-anatomy.txt"), atomically: true, encoding: .utf8,
                )
                _ = Menus.allTitles()
                try? Self.anatomy().joined(separator: "\n").write(
                    to: app.runDirectory.appending(path: "menu-anatomy-opened.txt"), atomically: true, encoding: .utf8,
                )
            }
            try lines.append(watched("first-dialog") {
                try app.main { MenuBarProbe.shared.holdDialog(true, on: $0) }
                app.pause(0.3)
                try app.main { MenuBarProbe.shared.holdDialog(false, on: $0) }
                app.pause(0.3)
            })
            try lines.append(timedRebuilds("develop", app))
            try lines.append(timedChecks("develop", app))
            try lines.append(timedKeys("develop", app))

            guard FileManager.default.fileExists(atPath: fixture.path) else {
                throw ScenarioSkip("\(fixture.path) isn't on this Mac")
            }
            // The run's supervisor stops a launch that reports nothing for 300 s: the copy is made, shown and removed
            // in about 4 minutes on a busy Mac.
            app.step("copying \(fixture.lastPathComponent)")
            let scratch = try DragBudgetScratch(cloning: fixture)
            defer {
                app.step("removing the copy")
                scratch.remove(app)
            }
            app.step("showing the copy")
            let count = try scratch.show(app)
            app.step("the copy shown")
            try app.main { model in
                model.setGroupKey(.ungrouped)
                model.setCellStyle(.compact)
                model.setThumbnailSize(GridSize.standard)
                model.gridStacks.closeAll()
            }
            lines
                .append("\(fixture.lastPathComponent): \(count) photos shown, load average \(DragBudgetScratch.load())")
            try app.main { model in
                if let first = model.gridStacks.list?.first ?? model.library.photoList.first,
                   let url = model.library.url(ofPhoto: first) {
                    model.select(url)
                }
            }
            try app.press(.gridView)
            try app.wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }
            app.pause(2)
            try lines.append(timedRebuilds("grid", app))
            try lines.append(timedChecks("grid", app))

            // → held in the grid, a key every 30 ms as key repeat sends them.
            let presses = 200
            let arrowsMark = try app.menuMark()
            try lines.append(watched("arrows") {
                let right = UnicodeScalar(NSRightArrowFunctionKey).map(String.init) ?? ""
                for _ in 0 ..< presses {
                    try app.pressGridKey(kVK_RightArrow, characters: right)
                    app.pause(1.0 / 30)
                }
            } + ", over \(presses) presses")
            let arrowRebuilds = try app.menuRebuilds(since: arrowsMark).rebuilds

            // Stacks opened and closed one at a time, each in a turn of its own.
            let tops = try app.main { model -> [Int64] in
                guard let list = model.gridStacks.list else { return [] }
                return Array(list.lazy.filter { list.badges(of: $0).stack?.isOpen == false }.prefix(20))
            }
            if tops.isEmpty {
                lines.append("stacks: none closed to open")
            } else {
                try lines.append(watched("stack-toggles") {
                    for top in tops {
                        try app.main { $0.gridStacks.toggle(top) }
                        app.pause(0.05)
                        try app.main { $0.gridStacks.toggle(top) }
                        app.pause(0.05)
                    }
                } + ", over \(2 * tops.count) toggles")
            }

            // A dialog's start and end, as a sheet's, which holds every item.
            try lines.append(watched("dialogs") {
                for _ in 0 ..< 20 {
                    try app.main { MenuBarProbe.shared.holdDialog(true, on: $0) }
                    app.pause(0.1)
                    try app.main { MenuBarProbe.shared.holdDialog(false, on: $0) }
                    app.pause(0.1)
                }
            } + ", over 20 dialogs")

            // Every photo selected.
            try app.main { $0.selectAllPhotos() }
            app.pause(2)
            try lines.append(timedRebuilds("grid-all-selected", app))
            try lines.append(timedChecks("grid-all-selected", app))
            try app.main { $0.deselectOtherPhotos() }
            app.pause(1)

            // A selection's move changes what an item shows only now and then, as at the folder's first photo.
            try app.expect(
                arrowRebuilds < presses / 10,
                "held arrows rebuilt the menu bar \(arrowRebuilds) times in \(presses) presses",
            )
        }

        /// The menu bar as AppKit has it: each menu's class, delegate and auto-enabling, and each item's class, target,
        /// action, state and key.
        @MainActor static func anatomy() -> [String] {
            func walk(_ menu: NSMenu, _ path: String) -> [String] {
                let delegate = menu.delegate as? NSObject
                let answers = [
                    #selector(NSMenuDelegate.menuNeedsUpdate(_:)), #selector(NSMenuDelegate.menuWillOpen(_:)),
                    #selector(NSMenuDelegate.menuHasKeyEquivalent(_:for:target:action:)),
                    #selector(NSMenuDelegate.numberOfItems(in:)),
                ].filter { delegate?.responds(to: $0) == true }.map(NSStringFromSelector)
                var lines = [
                    "\(path) [\(type(of: menu)), delegate \(menu.delegate.map { "\(type(of: $0))" } ?? "none") "
                        + "answering \(answers), autoenables \(menu.autoenablesItems), \(menu.items.count) items]",
                ]
                for item in menu.items where !item.isSeparatorItem {
                    let validates = (item.target as? NSObject)?
                        .responds(to: #selector(NSMenuItemValidation.validateMenuItem(_:)))
                    let target = item.target.map { "\(type(of: $0))\(validates == true ? " (validates)" : "")" } ?? "nil"
                    lines.append(
                        "  \(path) › \(item.title) [\(type(of: item)), target \(target), action "
                            + "\(item.action.map(NSStringFromSelector) ?? "nil"), enabled \(item.isEnabled), state "
                            +
                            "\(item.state.rawValue), key '\(item.keyEquivalent)' \(item.keyEquivalentModifierMask.rawValue)]",
                    )
                    if let submenu = item.submenu {
                        lines += walk(submenu, "\(path) › \(item.title)")
                    }
                }
                return lines
            }
            return NSApp.mainMenu.map { walk($0, "") } ?? []
        }

        /// Rebuilds the menus 30 times, each in a turn of its own, and says what each took.
        static func timedRebuilds(_ label: String, _ app: RunningApp) throws -> String {
            let mark = try app.menuMark()
            for _ in 0 ..< 30 {
                try app.main { _ in MenuBarProbe.shared.tick += 1 }
                app.pause(0.05)
            }
            return try "\(label), a rebuild by itself, 30 times: " + describe(app.menuRebuilds(since: mark))
        }

        /// What the menus' checks take alone: every action's, 30 times.
        static func timedChecks(_ label: String, _ app: RunningApp) throws -> String {
            let times = try app.main { model -> [Double] in
                (0 ..< 30).map { _ in
                    StackPerformanceScenarios.timed {
                        for action in ShortcutAction.allCases {
                            _ = model.canPerform(action)
                        }
                    }
                }
            }.sorted()
            return String(
                format: "%@, every action's check, 30 times: median %.3f ms, max %.3f ms", label,
                times[times.count / 2],
                times.last ?? 0,
            )
        }

        /// ⌘1 and ⌘2 (the Basic and Tone Curve panels) 20 times each, as the keyboard sends them: what bringing each
        /// key's item up to date before AppKit looks for it took.
        static func timedKeys(_ label: String, _ app: RunningApp) throws -> String {
            let mark = try app.main { _ in MenuBarProbe.shared.keys.count }
            for _ in 0 ..< 20 {
                for action in [ShortcutAction.panelBasic, .panelToneCurve] {
                    guard let combo = action.combos.first else { continue }
                    try app.press(combo)
                    app.pause(0.05)
                }
            }
            let times = try app.main { _ in Array(MenuBarProbe.shared.keys.dropFirst(mark)) }.sorted()
            guard let last = times.last else { return "\(label), ⌘1 and ⌘2: no key's item brought up to date" }
            return String(
                format: "%@, ⌘1 and ⌘2 40 times, each key's item brought up to date: median %.3f ms, max %.3f ms",
                label, times[times.count / 2], last,
            )
        }

        static func describe(_ work: MenuWork) -> String {
            let turns = work.turns.sorted()
            let bodies = work.bodies.sorted()
            let refreshes = work.refreshes.sorted()
            let checks = refreshes.isEmpty ? "" : String(
                format: "; %d runs of the checks, %.1f ms in all, median %.3f ms, max %.3f ms", refreshes.count,
                refreshes.reduce(0, +), refreshes[refreshes.count / 2], refreshes.last ?? 0,
            )
            guard !turns.isEmpty else { return "\(work.rebuilds) menu rebuilds" + checks }
            return String(
                format: "%d menu rebuilds in %d turns, %.1f ms in all, a turn's median %.2f ms, p95 %.2f ms, max "
                    + "%.2f ms; the body's median %.2f ms",
                work.rebuilds, turns.count, turns.reduce(0, +), turns[turns.count / 2],
                turns[min(turns.count - 1, Int(Double(turns.count) * 0.95))], turns.last ?? 0,
                bodies.isEmpty ? 0 : bodies[bodies.count / 2],
            ) + checks
        }
    }

    /// The menu bar's work since a mark: how many rebuilds, the milliseconds of each turn holding one and of each body,
    /// and of each run of `MenuBarState`'s checks.
    struct MenuWork: Sendable {
        var rebuilds: Int
        var turns: [Double]
        var bodies: [Double]
        var refreshes: [Double]
    }

    extension RunningApp {
        /// Where the menu bar's work stands, for `menuRebuilds(since:)`.
        struct MenuMark: Sendable {
            let rebuilds: Int
            let turns: Int
            let bodies: Int
            let refreshes: Int
        }

        func menuMark() throws -> MenuMark {
            try main { _ in
                let probe = MenuBarProbe.shared
                return MenuMark(
                    rebuilds: probe.rebuilds, turns: probe.turns.count, bodies: probe.bodies.count,
                    refreshes: probe.refreshes.count,
                )
            }
        }

        func menuRebuilds(since mark: MenuMark) throws -> MenuWork {
            try main { _ in
                let probe = MenuBarProbe.shared
                return MenuWork(
                    rebuilds: probe.rebuilds - mark.rebuilds, turns: Array(probe.turns.dropFirst(mark.turns)),
                    bodies: Array(probe.bodies.dropFirst(mark.bodies)),
                    refreshes: Array(probe.refreshes.dropFirst(mark.refreshes)),
                )
            }
        }

        /// Adds the menu bar's rebuilds since `mark` in a phase to the run's `menu-bar.txt`.
        func noteMenus(_ phase: String, since mark: MenuMark) {
            guard let rebuilds = try? menuRebuilds(since: mark) else { return }
            let url = runDirectory.appending(path: "menu-bar.txt")
            let line = "\(recorder.currentScenario ?? "") \(phase): \(MenuPerformanceScenarios.describe(rebuilds))\n"
            let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (before + line).write(to: url, atomically: true, encoding: .utf8)
        }
    }
#endif
