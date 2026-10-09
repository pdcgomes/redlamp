#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampDesign
    @_spi(Harness) import RedlampUI

    /// What each part of the window costs held arrow keys (LIB-14): → held in the grid of a copy of lib-20k (or of
    /// `REDLAMP_MENU_FIXTURE`), 200 presses a key-repeat apart, with every part shown and then with the right panel,
    /// the filmstrip and the left panel hidden in turn, the main thread watched through each. Skipped unless
    /// `REDLAMP_ARROW_PARTS` is set, since the copy takes minutes; with `REDLAMP_TURN_PROFILE`, each phase's slow turns
    /// are profiled too (`SlowTurnProfile`).
    enum ArrowPartsScenarios {
        static let all: [Scenario] = [parts]

        static let parts = Scenario(
            "performance.held-arrows-parts",
            "→ held in the grid of a copy of lib-20k with each part of the window hidden in turn, with "
                + "REDLAMP_ARROW_PARTS set",
            tiers: [.performance], claims: [],
        ) { app in
            guard ProcessInfo.processInfo.environment["REDLAMP_ARROW_PARTS"] != nil else {
                throw ScenarioSkip("REDLAMP_ARROW_PARTS isn't set")
            }
            let fixture = MenuPerformanceScenarios.fixture
            guard FileManager.default.fileExists(atPath: fixture.path) else {
                throw ScenarioSkip("\(fixture.path) isn't on this Mac")
            }
            var lines: [String] = []
            defer {
                try? (lines.joined(separator: "\n") + "\n").write(
                    to: app.runDirectory.appending(path: "arrow-parts.txt"), atomically: true, encoding: .utf8,
                )
            }
            app.step("copying \(fixture.lastPathComponent)")
            let scratch = try DragBudgetScratch(cloning: fixture)
            defer {
                app.step("removing the copy")
                scratch.remove(app)
            }
            app.step("indexing the copy")
            let service = try app.main { $0.library.service }
            guard let service else { throw ScenarioSkip("the library is off") }
            let copy = scratch.copy
            try app.main { $0.open([copy, scratch.moved]) }
            // A step a minute: the run's supervisor stops a launch that reports nothing for 300 s.
            for minute in 1 ... 50 {
                let indexed = Flag()
                try app.run("the library to index the copy", timeout: 120) { _ in
                    for _ in 0 ..< 600 where await !service.canShow(copy, includingSubfolders: true) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if await service.canShow(copy, includingSubfolders: true) {
                        indexed.set()
                    }
                }
                guard !indexed.isSet else { break }
                app.step("indexing the copy, \(minute) min")
            }
            app.step("showing the copy")
            let count = try scratch.show(app)
            app.step("the copy shown")
            try app.main { model in
                model.setGroupKey(.ungrouped)
                model.setCellStyle(.compact)
                model.setThumbnailSize(GridSize.standard)
                model.gridStacks.closeAll()
                if let first = model.gridStacks.list?.first ?? model.library.photoList.first,
                   let url = model.library.url(ofPhoto: first) {
                    model.select(url)
                }
            }
            lines
                .append("\(fixture.lastPathComponent): \(count) photos shown, load average \(DragBudgetScratch.load())")
            try app.press(.gridView)
            try app.wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }
            let parts: [(String, @MainActor (EditorModel) -> Void)] = [
                ("every part shown", { _ in }),
                ("the right panel hidden", { $0.rightPanelVisible = false }),
                ("the filmstrip hidden", { $0.filmstripVisible = false }),
                ("the left panel hidden", { $0.leftPanelVisible = false }),
                ("the right panel and the filmstrip hidden", { model in
                    model.rightPanelVisible = false
                    model.filmstripVisible = false
                }),
                ("Develop's views hidden", { _ in
                    for view in ArrowPartsScenarios.developViews() {
                        view.isHidden = true
                    }
                }),
                ("Develop's views, the right panel and the filmstrip hidden", { model in
                    model.rightPanelVisible = false
                    model.filmstripVisible = false
                    for view in ArrowPartsScenarios.developViews() {
                        view.isHidden = true
                    }
                }),
            ]
            let right = UnicodeScalar(NSRightArrowFunctionKey).map(String.init) ?? ""
            for (name, hiding) in parts {
                // The run's supervisor stops a launch that reports nothing for 300 s.
                app.step(name)
                try app.main { model in
                    model.leftPanelVisible = true
                    model.rightPanelVisible = true
                    model.filmstripVisible = true
                    for view in ArrowPartsScenarios.developViews() {
                        view.isHidden = false
                    }
                    hiding(model)
                }
                app.pause(2)
                let phase = try app.watchingMainThread(name) {
                    for _ in 0 ..< 200 {
                        try app.pressGridKey(kVK_RightArrow, characters: right)
                        app.pause(1.0 / 30)
                    }
                }
                lines.append(String(
                    format: "%@: %.2f s, main thread p99 %.2f ms, max %.1f ms, %d of %d turns over 8.3 ms, load %@",
                    name, phase.seconds, phase.summary?.p99 ?? -1, phase.summary?.max ?? -1,
                    phase.summary?.overFrame ?? -1, phase.summary?.iterations ?? -1, DragBudgetScratch.load(),
                ))
            }
            try app.main { model in
                model.leftPanelVisible = true
                model.rightPanelVisible = true
                model.filmstripVisible = true
                for view in ArrowPartsScenarios.developViews() {
                    view.isHidden = false
                }
            }
        }

        /// Develop's views under the Library's, kept at no opacity while the Library is shown: its canvas and its side
        /// columns, the first of their modules' views.
        @MainActor static func developViews() -> [NSView] {
            var found: [NSView] = []
            func walk(_ view: NSView) {
                let name = "\(type(of: view))"
                if name == "ModuleContainerView" || name == "ModuleColumnView", let develop = view.subviews.first {
                    found.append(develop)
                }
                view.subviews.forEach(walk)
            }
            Views.editorWindow?.contentView.map(walk)
            return found
        }
    }
#endif
