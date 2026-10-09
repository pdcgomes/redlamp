#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    extension ActionCheck {
        /// A Group By action, in the Library grid shown from the library: grouped by camera, or by moment for
        /// the moments' own; the first photo of the second group active for ⌥←, and every group closed for
        /// Open All Groups. Ungrouped and in Develop afterwards.
        static func groups(_ action: ShortcutAction) -> ActionCheck {
            ActionCheck(action: action, setUp: { app in
                let key: GroupKey = switch action {
                case .groupByCamera, .groupByNone: action == .groupByNone ? .camera : .day
                case .tighterMoments, .looserMoments, .unpickedMoments: .moment
                default: action.groupKey == nil ? .camera : .ungrouped
                }
                try app.showGroups(by: key)
                switch action {
                case .previousGroup, .nextGroup:
                    // A photo selected in the grid opens in Develop, not here, so there's no render to settle.
                    let url = try app.main { model -> URL? in
                        let group = action == .previousGroup ? 1 : 0
                        guard let list = model.gridGroups.list, list.groups.count > 1,
                              let photo = list.groups[group].photos.first, let url = model.library.url(ofPhoto: photo)
                        else { return nil }
                        model.select(url)
                        return url
                    }
                    if let url {
                        try app.wait("the group's first photo selected") { $0.selection == url }
                    }
                case .openAllGroups:
                    try app.main { $0.closeAllGroups() }
                    try app.settle()
                default:
                    try app.settle()
                }
                try app.main { model in
                    guard model.canPerform(action) else {
                        throw ScenarioFailure("\(action.title) isn't available: " + GroupScenarios.groups(model)
                            .map { "\($0.name) \($0.count)" }.joined(separator: ", ")
                            + " of \(model.items.count) photos; \(GroupScenarios.state(model))")
                    }
                }
            }, observe: GroupScenarios.state, restore: { app in
                try app.main { model in
                    model.setLooseness(0)
                    model.setGroupKey(.ungrouped)
                }
                try app.backToDevelop()
            })
        }
    }

    extension RunningApp {
        /// The working folder's grid, shown from the library and grouped by `key`, the first photo active.
        @discardableResult
        func showGroups(by key: GroupKey) throws -> [String] {
            try main { $0.libraryFilters?.setFilter(LibraryFilter()) }
            let names = try showGrid()
            try wait("the folder shown from the library", timeout: 90) { $0.canGroupPhotos }
            try main { model in
                model.setGroupKey(key)
                model.select(model.items[0].url)
            }
            try wait("the photos grouped by \(key.title)") { model in
                key == .ungrouped ? model.gridGroups.list == nil : model.gridGroups.list?.groups.key == key
            }
            try settle()
            return names
        }

        /// Chooses `title` in the pop-up button carrying `identifier`, as choosing it from its menu does.
        func choose(_ title: String, inPopUp identifier: String) throws {
            try main { _ in
                guard let window = Views.editorWindow,
                      let popUp = Views.all(NSPopUpButton.self, in: window.contentView?.superview ?? NSView())
                      .first(where: { $0.accessibilityIdentifier() == identifier })
                else { throw ScenarioFailure("No \(identifier) pop-up") }
                guard let index = popUp.itemTitles.firstIndex(of: title) else {
                    throw ScenarioFailure("\(identifier) has no \(title): \(popUp.itemTitles)")
                }
                popUp.selectItem(at: index)
                _ = popUp.sendAction(popUp.action, to: popUp.target)
            }
            pause(0.05)
        }

        /// The slider carrying `identifier`, its values whole steps, a step up or down, as dragging its knob to
        /// the next tick does.
        func step(slider identifier: String, up: Bool) throws {
            try main { _ in
                guard let window = Views.editorWindow,
                      let slider = Views.all(NSSlider.self, in: window.contentView?.superview ?? NSView())
                      .first(where: { $0.accessibilityIdentifier() == identifier })
                else { throw ScenarioFailure("No \(identifier) slider") }
                guard !slider.isHiddenOrHasHiddenAncestor else { throw ScenarioFailure("\(identifier) is hidden") }
                let next = slider.doubleValue.rounded() + (up ? 1 : -1)
                slider.doubleValue = min(max(next, slider.minValue), slider.maxValue)
                _ = slider.sendAction(slider.action, to: slider.target)
            }
            pause(0.05)
        }

        /// Clicks the view or grid element carrying `identifier` once it has stopped moving, as the grid scrolls
        /// to a photo selected a turn before.
        func clickStill(_ identifier: String, modifiers: NSEvent.ModifierFlags = []) throws {
            var last = try frame(of: .identifier(identifier))
            for _ in 0 ..< 40 {
                pause(0.05)
                let now = try frame(of: .identifier(identifier))
                if now == last {
                    break
                }
                last = now
            }
            try clickView(identifier, modifiers: modifiers)
        }

        /// Presses the button carrying `identifier` in the editor window, as a click on it does: a press sent to
        /// a button's view would wait in its tracking loop for a release that never comes.
        func press(_ identifier: String) throws {
            try main { _ in
                guard let window = Views.editorWindow,
                      let button = Views.all(NSButton.self, in: window.contentView?.superview ?? NSView())
                      .first(where: { $0.accessibilityIdentifier() == identifier })
                else { throw ScenarioFailure("No \(identifier) button") }
                guard !button.isHiddenOrHasHiddenAncestor, button.isEnabled else {
                    throw ScenarioFailure("\(identifier) can't be pressed")
                }
                button.performClick(nil)
            }
            pause(0.05)
        }

        /// How many times the editor window's grid has reloaded every cell.
        func gridReloads() throws -> Int {
            try main { _ in Views.editorWindow.flatMap(LibraryGridViews.reloads(in:)) ?? -1 }
        }
    }

    enum GroupScenarios {
        static let all: [Scenario] = [groupBy, openAndClose, moving, setting, unpicked, cullingOrder]

        /// The identifiers of the grid's elements whose middle is on show, not under a bar or kept just off screen.
        @MainActor static func onScreen() -> [String] {
            guard let window = Views.editorWindow, let root = window.contentView?.superview,
                  let grid = Views.all(NSView.self, in: root)
                  .first(where: { $0.accessibilityIdentifier() == "library.grid" })
            else { return [] }
            return (grid.accessibilityChildren() ?? []).compactMap { child -> String? in
                guard let element = child as? NSAccessibilityElement, let id = element.accessibilityIdentifier() else {
                    return nil
                }
                let frame = window.convertFromScreen(element.accessibilityFrame())
                return root.hitTest(CGPoint(x: frame.midX, y: frame.midY)) === grid ? id : nil
            }
        }

        /// The identifiers of the grid's group headers on show.
        @MainActor static func headersOnScreen() -> [String] {
            onScreen().filter { $0.hasPrefix("grid.group.") }
        }

        /// What the group actions change, for their checks.
        @MainActor static func state(_ model: EditorModel) -> String {
            let groups = model.gridGroups
            let open = groups.list.map { list in list.groups.indices.count(where: list.isOpen) } ?? -1
            return "\(model.libraryViews.groupKey) \(model.libraryViews.looseness) \(open) \(groups.showsUnpicked) "
                + (model.selection?.lastPathComponent ?? "")
        }

        @MainActor static func groups(_ model: EditorModel) -> [(name: String, count: Int, picks: Int)] {
            guard let list = model.gridGroups.list else { return [] }
            return list.groups.indices.map { (list.groups[$0].name, list.groups[$0].count, model.gridGroups.picks[$0]) }
        }

        static let groupBy = Scenario(
            "library.group-by",
            "Group By from the View menu, the grid's toolbar and the palette groups the grid by each key, each group "
                + "a header with its name, photos and picks; each source keeps its grouping, a collection as a folder",
            claims: ShortcutAction.allCases.filter { $0.groupKey != nil }.map(Claim.action)
                + [.feature("library.grid"), .feature("library.subfolders"), .feature("library.collections")],
        ) { app in
            try app.showGroups(by: .ungrouped)
            for action in ShortcutAction.allCases where action.groupKey != nil && action != .groupByNone {
                guard let key = action.groupKey else { continue }
                try app.choose(action)
                try app.wait("the menu's \(key.title)") { $0.gridGroups.list?.groups.key == key }
                let grouped = try app.main { $0.gridGroups.list?.groups.photos.count ?? 0 }
                try app.expect(grouped == app.photoNames().count, "\(key.title)'s groups hold \(grouped) photos")
                try app.wait("a header on screen") { _ in !GroupScenarios.headersOnScreen().isEmpty }
            }
            app.covered(.feature("library.grid"), via: .menu)
            try app.choose("Camera", inPopUp: "library.toolbar.groupBy")
            try app.wait("the toolbar's Camera") { $0.libraryViews.groupKey == .camera && $0.gridGroups.list != nil }
            let byCamera = try app.main(groups)
            try app.expect(
                byCamera.count > 1 && byCamera.allSatisfy { $0.count > 0 },
                "By camera the folder's photos are in \(byCamera)",
            )
            try app.choose("None", inPopUp: "library.toolbar.groupBy")
            try app.wait("the toolbar's None") { $0.gridGroups.list == nil }
            app.covered(.feature("library.grid"), via: .mouse)
            try app.runFromPalette(.groupByDay)
            try app.wait("the palette's Day") { $0.gridGroups.list?.groups.key == .day }

            // The folder with its subfolders keeps another grouping, and the folder alone its own.
            try app.main { $0.setIncludesSubfolders(true) }
            try app.wait("the folder with its subfolders") { $0.library.includesSubfolders && !$0.library.isListing }
            try app.wait("the folder shown from the library", timeout: 90) { $0.canGroupPhotos }
            try app.main { $0.setGroupKey(.orientation) }
            try app.main { $0.setIncludesSubfolders(false) }
            try app.wait("the folder alone") { !$0.library.includesSubfolders && !$0.library.isListing }
            try app.wait("its grouping by day back") { $0.libraryViews.groupKey == .day }
            try app.wait("grouped by day again", timeout: 90) { $0.gridGroups.list?.groups.key == .day }
            try app.main { $0.setIncludesSubfolders(true) }
            try app.wait("the subfolders' grouping by orientation back") { model in
                model.library.includesSubfolders && model.libraryViews.groupKey == .orientation
            }
            app.covered(.feature("library.subfolders"), via: .model)
            try app.main { $0.setIncludesSubfolders(false) }
            try app.wait("the folder alone") { !$0.library.includesSubfolders && !$0.library.isListing }
            try app.choose(.groupByNone)
            try app.wait("ungrouped") { $0.gridGroups.list == nil }
            try app.backToDevelop()

            // A collection is grouped as a folder is, and keeps a grouping of its own.
            try app.withCollection(of: ["A.jpg", "B.jpg", "Inner/C.jpg"]) { scratch, path in
                try app.wait("the collection shown from the library") { $0.canGroupPhotos }
                try app.choose(.groupByFolder)
                try app.wait("the collection by folder: the scratch's and its subfolder's") { model in
                    model.gridGroups.list.map { list in
                        list.groups.key == .folder && list.groups.count == 2 && list.groups.photos.count == 3
                    } == true
                }
                try app.wait("a header on screen") { _ in !GroupScenarios.headersOnScreen().isEmpty }
                try app.main { $0.showFolder(scratch.folder) }
                try app.wait("the scratch folder ungrouped, as it was left") { model in
                    model.folder == scratch.folder && !model.library.isListing && model.gridGroups.list == nil
                }
                try app.clickSourceRow("collections.\(path.text)")
                try app.wait("the collection by folder again", timeout: 20) { model in
                    model.librarySources.shown == .collection(path) && model.gridGroups.list?.groups.key == .folder
                }
                app.covered(.feature("library.collections"), via: .mouse)
                try app.choose(.groupByNone)
                try app.wait("ungrouped") { $0.gridGroups.list == nil }
            }
        }

        static let openAndClose = Scenario(
            "library.groups-open-close",
            "A click on a group's header closes and opens it, keeping the selection and the active photo; ⌥-click, "
                + "the menus and the palette open and close every group",
            claims: [
                .action(.toggleGroup),
                .action(.openAllGroups),
                .action(.closeAllGroups),
                .feature("library.grid"),
            ],
        ) { app in
            try app.showGroups(by: .camera)
            let firsts = try app.main { model in
                (model.gridGroups.list?.groups.compactMap(\.photos.first) ?? []).compactMap(model.library.url(ofPhoto:))
                    .map(\.lastPathComponent)
            }
            guard firsts.count >= 3 else {
                throw ScenarioFailure("Grouped by camera, the folder has \(firsts.count) groups")
            }
            // The first group's first photo active, and the first photo on show of a group past the second
            // selected with it, so closing the second keeps the selection.
            try app.main { model in
                if let url = model.items.first(where: { $0.url.lastPathComponent == firsts[0] })?.url {
                    model.select(url)
                }
            }
            app.pause(0.2)
            let shown = try app.main { _ in GroupScenarios.onScreen() }
            guard let lastFirst = firsts.dropFirst(2).first(where: { shown.contains("grid.\($0)") }) else {
                throw ScenarioFailure("None of \(firsts.dropFirst(2)) on show with \(firsts[0]): \(shown)")
            }
            try app.clickStill("grid.\(lastFirst)", modifiers: .command)
            let before = try app.selectionState()
            try app.expect(
                Set(before.photos) == [firsts[0], lastFirst],
                "⌘-click on \(lastFirst) selected \(before), the groups' firsts \(firsts)",
            )
            let reloads = try app.gridReloads()
            try app.clickStill("grid.group.1")
            try app.wait("a click to close the second group") { $0.gridGroups.list.map { !$0.isOpen(1) } == true }
            var after = try app.selectionState()
            try app.expect(
                after.photos == before.photos && after.active == before.active, "Closing a group selected \(after)",
            )
            app.covered(.feature("library.grid"), via: .mouse)
            try app.clickStill("grid.group.1")
            try app.wait("a click to open it again") { $0.gridGroups.list.map { $0.isOpen(1) } == true }
            after = try app.selectionState()
            try app.expect(
                after.photos == before.photos && after.active == before.active, "Opening a group selected \(after)",
            )
            try app.expect(try app.gridReloads() == reloads, "Opening and closing reloaded the grid")
            let header = try app.main { _ in GroupScenarios.headersOnScreen().first }
            guard let header else { throw ScenarioFailure("No group's header on show") }
            try app.clickStill(header, modifiers: .option)
            try app.wait("⌥-click to close every group") { model in
                model.gridGroups.list.map { list in list.groups.indices.allSatisfy { !list.isOpen($0) } } == true
            }
            try app.choose(.openAllGroups)
            try app.wait("Open All Groups") { model in
                model.gridGroups.list.map { list in list.groups.indices.allSatisfy(list.isOpen) } == true
            }
            try app.runFromPalette(.closeAllGroups)
            try app.wait("the palette's Close All Groups") { model in
                model.gridGroups.list.map { list in list.groups.indices.allSatisfy { !list.isOpen($0) } } == true
            }
            try app.choose(.openAllGroups)
            try app.choose(.toggleGroup)
            try app.wait("Open / Close Group to close the active photo's") { model in
                model.gridGroups.list.map { list in list.groups.indices.contains { !list.isOpen($0) } } == true
            }
            try app.runFromPalette(.openAllGroups)
            try app.main { $0.setGroupKey(.ungrouped) }
            try app.backToDevelop()
        }

        static let moving = Scenario(
            "library.groups-moving",
            "⌥→ and ⌥← by key, the Photo menu and the palette go to the first photo of the next and previous group; "
                + "→ passes over a closed group's photos",
            claims: [.action(.previousGroup), .action(.nextGroup), .feature("library.grid")],
        ) { app in
            try app.showGroups(by: .camera)
            func firstPhotos() throws -> [String] {
                try app.main { model in
                    (model.gridGroups.list?.groups.map(\.photos.first).compactMap(\.self) ?? [])
                        .compactMap(model.library.url(ofPhoto:)).map(\.lastPathComponent)
                }
            }
            let firsts = try firstPhotos()
            try app.expect(firsts.count > 2, "Grouped by camera, \(firsts.count) groups")
            try app.main { model in
                if let first = model.items.first(where: { $0.url.lastPathComponent == firsts[0] }) {
                    model.select(first.url)
                }
            }
            try app.press(.nextGroup)
            try app.wait("⌥→ to the second group's first photo") { $0.selection?.lastPathComponent == firsts[1] }
            try app.choose(.nextGroup)
            try app.wait("Next Group to the third's") { $0.selection?.lastPathComponent == firsts[2] }
            try app.runFromPalette(.previousGroup)
            try app.wait("the palette's Previous Group") { $0.selection?.lastPathComponent == firsts[1] }
            try app.press(.previousGroup)
            try app.wait("⌥← to the first group's first photo") { $0.selection?.lastPathComponent == firsts[0] }

            // → from the first group's last photo passes over the second group, closed, to the third's first.
            try app.main { model in
                guard let list = model.gridGroups.list, let last = list.groups[0].photos.last,
                      let url = model.library.url(ofPhoto: last) else { return }
                model.select(url)
                model.gridGroups.close(1)
            }
            try app.press(.nextPhoto)
            try app.wait("→ past the closed group") { $0.selection?.lastPathComponent == firsts[2] }
            app.covered(.feature("library.grid"), via: .key)
            try app.main { model in
                model.openAllGroups()
                model.setGroupKey(.ungrouped)
            }
            try app.backToDevelop()
        }

        static let setting = Scenario(
            "library.moments-setting",
            "Grouped by moment, the toolbar's Tighter–Looser slider, the View menu and the palette make moments "
                + "tighter and looser, the grid grouped again as it moves",
            claims: [.action(.tighterMoments), .action(.looserMoments), .feature("library.grid")],
        ) { app in
            try app.showGroups(by: .moment)
            try app.step(slider: "library.toolbar.looseness", up: true)
            try app.wait("the toolbar's slider: looser") { $0.libraryViews.looseness == 1 }
            try app.wait("moments found at the looser setting") { model in
                model.gridGroups.list?.groups.setting == MomentSetting(looseness: 1)
            }
            app.covered(.feature("library.grid"), via: .mouse)
            try app.choose(.tighterMoments)
            try app.wait("Tighter Moments") { $0.libraryViews.looseness == 0 }
            try app.runFromPalette(.tighterMoments)
            try app.wait("the palette's Tighter Moments") { $0.libraryViews.looseness == -1 }
            try app.choose(.looserMoments)
            try app.wait("Looser Moments") { $0.libraryViews.looseness == 0 }
            try app.runFromPalette(.looserMoments)
            try app.wait("the palette's Looser Moments") { $0.libraryViews.looseness == 1 }
            try app.main { model in
                model.setLooseness(0)
                model.setGroupKey(.ungrouped)
            }
            try app.backToDevelop()
        }

        static let unpicked = Scenario(
            "library.moments-unpicked",
            "Grouped by moment, the toolbar counts the moments without a pick, and it and the View menu show "
                + "those moments alone and every moment again",
            claims: [.action(.unpickedMoments), .feature("library.grid")],
        ) { app in
            try app.showGroups(by: .moment)
            try app.wait("the moments counted") { $0.gridGroups.coverage != nil }
            let coverage = try app.main { $0.gridGroups.coverage }
            try app.press("library.toolbar.unpicked")
            try app.wait("only the moments without a pick open") { $0.gridGroups.showsUnpicked }
            let open = try app.main { model in
                model.gridGroups.list.map { list in list.groups.indices.count(where: list.isOpen) } ?? 0
            }
            try app.expect(
                open == coverage?.unpicked, "\(open) moments open of \(String(describing: coverage)) without a pick",
            )
            app.covered(.feature("library.grid"), via: .mouse)
            try app.choose(.unpickedMoments)
            try app.wait("every moment again") { !$0.gridGroups.showsUnpicked }
            try app.main { $0.setGroupKey(.ungrouped) }
            try app.backToDevelop()
        }

        static let cullingOrder = Scenario(
            "library.groups-culling-order",
            "Grouped, ⇧ with a rating and Auto Advance move on in the grid's order, past a closed group; the "
                + "filmstrip leaves the closed group out, and Develop's ← steps back over it",
            claims: [.action(.autoAdvance), .feature("library.grid"), .feature("library.filmstrip")],
        ) { app in
            try app.withCulling { _ in
                try app.main { $0.gridStacks.openAll() }
                try app.showGroups(by: .camera)
                // Each group's photos with a cell of their own on show: a stack's others aren't.
                let groups = try app.main { model -> [[String]] in
                    guard let list = model.gridGroups.list else { return [] }
                    let shown = Set(GroupScenarios.onScreen())
                    return list.groups.indices.map { group in
                        list.groups.photos(ofGroup: group).compactMap { model.library.url(ofPhoto: $0) }
                            .map(\.lastPathComponent).filter { shown.contains("grid.\($0)") }
                    }
                }
                // Three groups in a row with cells: the middle one is closed.
                guard let first = groups.indices.dropLast(2).first(where: { start in
                    (start ..< start + 3).allSatisfy { !groups[$0].isEmpty }
                }), let last = groups[first].last, let closed = groups[first + 1].first,
                let next = groups[first + 2].first
                else { throw ScenarioFailure("Grouped by camera, groups of \(groups.map(\.count)) photos") }
                func selectLast() throws {
                    try app.clickStill("grid.\(last)")
                    try app.wait("\(last) selected") { $0.selection?.lastPathComponent == last }
                }

                try selectLast()
                try app.clickStill("grid.group.\(first + 1)")
                try app.wait("a click to close \(closed)'s group") { model in
                    model.gridGroups.list.map { !$0.isOpen(first + 1) } == true
                }
                try app.press(.rating1, shift: true)
                try app.wait("⇧1 to move past the closed group to \(next)") { $0.selection?.lastPathComponent == next }
                app.covered(.feature("library.grid"), via: .key)

                try selectLast()
                try app.choose(.autoAdvance)
                try app.wait("Auto Advance on") { $0.autoAdvance }
                try app.press(.flagPick)
                try app.wait("Auto Advance past the closed group to \(next)") { model in
                    model.selection?.lastPathComponent == next
                }
                app.covered(.action(.autoAdvance), via: .menu)

                let shown = try [last, next, closed].map { try app.exists(.filmstrip($0)) }
                try app.expect(
                    shown == [true, true, false],
                    "The filmstrip shows \(last), \(next) and the closed group's \(closed): \(shown)",
                )
                let (before, after) = try (app.frame(of: .filmstrip(last)), app.frame(of: .filmstrip(next)))
                try app.expect(
                    before.maxX <= after.minX, "The filmstrip shows \(last) at \(before), \(next) at \(after)",
                )
                app.covered(.feature("library.filmstrip"), via: .model)

                try app.press(.developModule)
                try app.settle()
                try app.press(.previousPhoto)
                try app.wait("Develop's ← back over the closed group to \(last)") { model in
                    model.selection?.lastPathComponent == last
                }
                try app.settle()
                try app.main { model in
                    model.openAllGroups()
                    model.setGroupKey(.ungrouped)
                }
            }
        }
    }

#endif
