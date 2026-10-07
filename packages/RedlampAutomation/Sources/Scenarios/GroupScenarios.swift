#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    extension ActionCheck {
        /// A Group By action, in the Library grid shown from the library: ungrouped for a key, grouped by day for
        /// Group by Camera and by camera for No Grouping and the groups' own actions, with every group closed for
        /// Open All Groups. Ungrouped and in Develop afterwards.
        static func groups(_ action: ShortcutAction) -> ActionCheck {
            ActionCheck(action: action, setUp: { app in
                let key: GroupKey = switch action {
                case .groupByCamera, .groupByNone: action == .groupByNone ? .camera : .day
                default: action.groupKey == nil ? .camera : .ungrouped
                }
                try app.showGroups(by: key)
                if action == .openAllGroups {
                    try app.main { $0.closeAllGroups() }
                }
                try app.settle()
            }, observe: GroupScenarios.state, restore: { app in
                try app.main { $0.setGroupKey(.ungrouped) }
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

        /// How many times the editor window's grid has reloaded every cell.
        func gridReloads() throws -> Int {
            try main { _ in Views.editorWindow.flatMap(LibraryGridViews.reloads(in:)) ?? -1 }
        }
    }

    enum GroupScenarios {
        static let all: [Scenario] = [groupBy, openAndClose]

        /// What the group actions change, for their checks.
        @MainActor static func state(_ model: EditorModel) -> String {
            let groups = model.gridGroups
            let open = groups.list.map { list in list.groups.indices.count(where: list.isOpen) } ?? -1
            return "\(model.libraryViews.groupKey) \(open) " + (model.selection?.lastPathComponent ?? "")
        }

        @MainActor private static func groups(_ model: EditorModel) -> [(name: String, count: Int, picks: Int)] {
            guard let list = model.gridGroups.list else { return [] }
            return list.groups.indices.map { (list.groups[$0].name, list.groups[$0].count, model.gridGroups.picks[$0]) }
        }

        static let groupBy = Scenario(
            "library.group-by",
            "Group By from the View menu, the grid's toolbar and the palette groups the grid by each key, each group "
                + "a header with its name, photos and picks; each source keeps its grouping",
            claims: ShortcutAction.allCases.filter { $0.groupKey != nil }.map(Claim.action)
                + [.feature("library.grid"), .feature("library.subfolders")],
        ) { app in
            try app.showGroups(by: .ungrouped)
            for action in ShortcutAction.allCases where action.groupKey != nil && action != .groupByNone {
                guard let key = action.groupKey else { continue }
                try app.choose(action)
                try app.wait("the menu's \(key.title)") { $0.gridGroups.list?.groups.key == key }
                let grouped = try app.main { $0.gridGroups.list?.groups.photos.count ?? 0 }
                try app.expect(grouped == app.photoNames().count, "\(key.title)'s groups hold \(grouped) photos")
                try app.wait("the first header on screen") { _ in
                    Views.editorWindow.flatMap { Views.find("grid.group.0", in: $0) } != nil
                }
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
            guard firsts.count >= 3, let lastFirst = firsts.last else {
                throw ScenarioFailure("Grouped by camera, the folder has \(firsts.count) groups")
            }
            // The first group's first photo active, and the last group's first selected with it.
            try app.main { model in
                if let url = model.items.first(where: { $0.url.lastPathComponent == firsts[0] })?.url {
                    model.select(url)
                }
            }
            try app.clickView("grid.\(lastFirst)", modifiers: .command)
            let before = try app.selectionState()
            try app.expect(Set(before.photos) == [firsts[0], lastFirst], "⌘-click selected \(before)")
            let reloads = try app.gridReloads()
            try app.clickView("grid.group.1")
            try app.wait("a click to close the second group") { $0.gridGroups.list.map { !$0.isOpen(1) } == true }
            var after = try app.selectionState()
            try app.expect(
                after.photos == before.photos && after.active == before.active, "Closing a group selected \(after)",
            )
            app.covered(.feature("library.grid"), via: .mouse)
            try app.clickView("grid.group.1")
            try app.wait("a click to open it again") { $0.gridGroups.list.map { $0.isOpen(1) } == true }
            after = try app.selectionState()
            try app.expect(
                after.photos == before.photos && after.active == before.active, "Opening a group selected \(after)",
            )
            try app.expect(try app.gridReloads() == reloads, "Opening and closing reloaded the grid")
            try app.clickView("grid.group.0", modifiers: .option)
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
    }

#endif
