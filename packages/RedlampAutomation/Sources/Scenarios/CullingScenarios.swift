#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// Runs `body` on the working folder's grid, shown from the library, then takes back every culling
        /// change it made and waits for their sidecars, also when `body` fails, so the scenarios after it find
        /// the photos as they were.
        func withCulling(_ body: ([String]) throws -> Void) throws {
            let names = try showGrid()
            try wait("the folder shown from the library", timeout: 90) { $0.library.isShownFromLibrary }
            let depth = try main { $0.cullingUndoCount }
            do {
                try body(names)
            } catch {
                try? takeBackCulling(to: depth)
                throw error
            }
            try takeBackCulling(to: depth)
        }

        /// Library's culling changes taken back until `depth` are left, Auto Advance off, the grid's compact
        /// cells and Develop again.
        func takeBackCulling(to depth: Int) throws {
            try main { model in
                model.showModule(.library)
                while model.cullingUndoCount > depth, model.undoCulling() {}
                if model.autoAdvance {
                    model.toggleAutoAdvance()
                }
                model.setCellStyle(.compact)
            }
            try waitWritten()
            try backToDevelop()
        }

        /// Until every culling change asked for has been made.
        func waitWritten(timeout: Double = 30) throws {
            try wait("the culling to be written", timeout: timeout) { !$0.isWritingCulling }
        }

        /// Until `name`'s sidecar holds what `holds` looks for: Develop saves its own photo a moment later.
        func waitInSidecar(
            _ name: String, _ what: @autoclosure () -> String, _ holds: @escaping @Sendable (PhotoMetadata) -> Bool,
        ) throws {
            let photos = photos
            try wait("\(name)'s sidecar to hold \(what())", timeout: 15) { model in
                holds(Self.sidecar(name, in: model, photos: photos))
            }
        }

        /// The photo's culling fields as the grid shows them.
        func shown(_ name: String) throws -> PhotoMetadata {
            try main { model in
                model.items.first { $0.url.lastPathComponent == name }?.metadata ?? PhotoMetadata()
            }
        }

        @MainActor private static func sidecar(_ name: String, in model: EditorModel, photos: URL) -> PhotoMetadata {
            let url = model.items.first { $0.url.lastPathComponent == name }?.url ?? photos.appending(path: name)
            return model.library.sidecars.store(for: url).summary(for: url)?.metadata ?? PhotoMetadata()
        }

        /// Selects the first `count` photos from the keyboard: the first, then ⇧→.
        func selectFromKeyboard(_ count: Int, of names: [String]) throws {
            try click(.identifier("grid.\(names[0])"))
            try wait("\(names[0]) alone") { $0.selectedPhotos.count == 1 }
            for _ in 1 ..< count {
                try press(KeyCombo(.right, shift: true))
            }
            try wait("\(count) photos selected") { $0.selectedPhotos.count == count }
        }
    }

    enum CullingScenarios {
        static let all: [Scenario] = [keys, mouse, autoAdvance, filtered]

        static let keys = Scenario(
            "library.culling-keys",
            "In the grid, the rating, flag, label and mark keys reach every photo selected as one change, kept in "
                + "their sidecars; ⌘Z takes it back and ⇧⌘Z makes it again; ⇧ with a key moves on",
            tiers: [.smoke, .full],
            claims: [.action(.undo), .action(.redo), .feature("library.ratings")],
        ) { app in
            try app.withCulling { names in
                try app.selectFromKeyboard(3, of: names)
                let three = Array(names[0 ... 2])
                let checks: [(ShortcutAction, @Sendable (PhotoMetadata) -> Bool)] = [
                    (.rating3, { $0.rating == 3 }), (.flagReject, { $0.flag == .reject }),
                    (.labelYellow, { $0.label == .yellow }), (.toggleMark, { $0.mark }),
                ]
                for (action, holds) in checks {
                    try app.press(action)
                    try app.wait("\(action.title) on the three photos, and on no other") { model in
                        model.items.allSatisfy { holds($0.metadata) == three.contains($0.url.lastPathComponent) }
                    }
                    try app.waitWritten()
                    for name in three {
                        try app.waitInSidecar(name, action.title, holds)
                    }
                    try app.waitInSidecar(names[3], "nothing of \(action.title)") { !holds($0) }
                    try app.press(.undo)
                    try app.wait("⌘Z to take \(action.title) back") { model in
                        !model.items.contains { holds($0.metadata) }
                    }
                    try app.waitWritten()
                    try app.waitInSidecar(names[1], "\(action.title) taken back") { !holds($0) }
                    try app.press(.redo)
                    try app.wait("⇧⌘Z to make \(action.title) again") { model in
                        model.items.filter { holds($0.metadata) }.count == 3
                    }
                    try app.waitWritten()
                    try app.waitInSidecar(names[2], "\(action.title) made again", holds)
                }
                try app.press(.rating2, shift: true)
                try app.wait("⇧2 to rate the three and move on to the next") { model in
                    model.selection?.lastPathComponent == names[3] && model.selectedPhotos.count == 1
                }
                try app.expect(try app.shown(names[0]).rating == 2 && app.shown(names[3]).rating == 0, "⇧2 rated")
                app.covered(.feature("library.ratings"), via: .key)
            }
        }

        static let mouse = Scenario(
            "library.culling-mouse",
            "A click on an expanded cell's stars, flag or mark sets it on the photo, or on every photo selected when "
                + "it's one of them; the context menu, the Photo menu and the palette set labels, custom labels and "
                + "No Label",
            claims: [
                .action(.labelPurple),
                .action(.clearLabel),
                .feature("library.ratings"),
                .feature("library.grid"),
            ],
        ) { app in
            try app.withCulling { names in
                try app.main { $0.setCellStyle(.expanded) }
                try app.wait("expanded cells") { _ in
                    Views.editorWindow.flatMap { Views.find("grid.\(names[0])", in: $0) }.map { $0.height > $0.width }
                        == true
                }
                try app.selectFromKeyboard(2, of: names)
                let size = try app.main { $0.libraryViews.thumbnailSize }
                func click(_ name: String, _ part: LibraryGridViews.CellPart) throws {
                    try app.click(.identifier("grid.\(name)"), at: LibraryGridViews.point(of: part, size: size))
                }
                try click(names[1], .star(4))
                try app.wait("the fourth star of a selected cell on both photos selected") { model in
                    model.items.prefix(2).allSatisfy { $0.metadata.rating == 4 } && model.items[2].metadata.rating == 0
                }
                try click(names[3], .star(2))
                try app.wait("another cell's second star on its photo alone") { model in
                    model.items[3].metadata.rating == 2 && model.selectedPhotos.count == 2
                }
                try click(names[0], .flag)
                try app
                    .wait("the flag of a selected cell") { $0.items.prefix(2).allSatisfy { $0.metadata.flag == .pick } }
                try click(names[0], .mark)
                try app.wait("the mark of a selected cell") { $0.items.prefix(2).allSatisfy(\.metadata.mark) }
                app.covered(.feature("library.grid"), via: .mouse)

                let fifth = try app.frame(of: .identifier("grid.\(names[4])"))
                try app.chooseInContextMenu(
                    "Purple Label", at: NSPoint(x: fifth.midX, y: fifth.midY), submenu: "Set Color Label",
                )
                try app.wait("the context menu's purple on its photo alone") { model in
                    model.items[4].metadata.label == .purple && model.items[0].metadata.label == nil
                }
                try app.choose(.labelPurple)
                try app.wait("the Photo menu's purple on the photos selected") { model in
                    model.items.prefix(2).allSatisfy { $0.metadata.label == .purple }
                }
                app.covered(.action(.labelPurple), via: .menu)
                // A custom label to choose: set as Photo Mechanic or another app would have left one.
                try app.main { $0.setCustomLabel("E2E Second Look") }
                try app.wait("the custom label offered") { $0.customLabels.contains("E2E Second Look") }
                let third = try app.frame(of: .identifier("grid.\(names[2])"))
                try app.chooseInContextMenu(
                    "E2E Second Look", at: NSPoint(x: third.midX, y: third.midY), submenu: "Set Color Label",
                )
                try app.wait("the custom label from the context menu") { model in
                    model.items[2].metadata.customLabel == "E2E Second Look" && model.items[2].metadata.label == nil
                }
                try app.runFromPalette(.clearLabel)
                try app.wait("the palette's No Label on the photos selected") { model in
                    model.items.prefix(2).allSatisfy { $0.metadata.label == nil && $0.metadata.customLabel == nil }
                }
                try app.waitWritten()
                try app.waitInSidecar(names[2], "the custom label") { $0.customLabel == "E2E Second Look" }
                try app.waitInSidecar(names[1], "the click's four stars") { $0.rating == 4 && $0.label == nil }
                app.covered(.feature("library.ratings"), via: .mouse)
            }
        }

        static let autoAdvance = Scenario(
            "library.culling-auto-advance",
            "Photo ▸ Auto Advance moves on after each rating, flag, label and mark, in Library and in Develop, as ⇧ "
                + "does",
            claims: [.action(.autoAdvance), .feature("library.ratings")],
        ) { app in
            try app.withCulling { names in
                try app.selectFromKeyboard(1, of: names)
                try app.choose(.autoAdvance)
                try app.wait("Auto Advance on") { $0.autoAdvance }
                for (step, action) in [ShortcutAction.rating1, .flagReject, .labelGreen].enumerated() {
                    try app.press(action)
                    try app.wait("\(action.title) to move on to \(names[step + 1])") { model in
                        model.selection?.lastPathComponent == names[step + 1]
                    }
                }
                try app.press(.developModule)
                try app.settle()
                try app.press(.toggleMark)
                try app.wait("Develop's mark to move on") { $0.selection?.lastPathComponent == names[4] }
                try app.settle()
                try app.expect(try app.shown(names[3]).mark, "Develop didn't mark \(names[3])")
                try app.choose(.autoAdvance)
                try app.wait("Auto Advance off") { !$0.autoAdvance }
                // Develop's own change isn't Library's to undo: its key takes it back.
                try app.press(.previousPhoto)
                try app.wait("back on \(names[3])") { $0.selection?.lastPathComponent == names[3] }
                try app.settle()
                try app.press(.toggleMark)
                try app.wait("the mark taken back, staying put") { model in
                    model.selection?.lastPathComponent == names[3] && !model.photoMetadata.mark
                }
                app.covered([.action(.autoAdvance), .feature("library.ratings")], via: .menu)
            }
        }

        static let filtered = Scenario(
            "library.culling-filter",
            "A photo a rating takes out of the filter bar's query leaves the grid at once, the one after it taking "
                + "its place, and ⌘Z brings it back",
            claims: [.feature("library.filter"), .feature("library.ratings")],
        ) { app in
            try app.withCulling { names in
                try app.press(.selectAllPhotos)
                try app.press(.rating3)
                try app.wait("every photo at three stars") { $0.items.allSatisfy { $0.metadata.rating == 3 } }
                try app.waitWritten()
                try app.withFilterBar { _ in
                    try app.typeQuery("rating>=3")
                    try app.wait("the query to keep every photo") { model in
                        model.library.isFiltered && model.items.count == names.count
                    }
                    if try app.main({ $0.libraryFilters?.completions.isEmpty == false }) {
                        try app.pressInWindow(KeyCombo(.escape))
                        try app.wait("Esc to close the completions") { $0.libraryFilters?.completions.isEmpty == true }
                    }
                    try app.pressInWindow(KeyCombo(.escape))
                    try app.wait("the grid to take the keyboard") { _ in
                        Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
                    }
                    try app.click(.identifier("grid.\(names[1])"))
                    try app.wait("\(names[1]) alone") { $0.selectedPhotos.map(\.lastPathComponent) == [names[1]] }
                    try app.press(.rating1)
                    try app.wait("\(names[1]) to leave the grid, \(names[2]) taking its place", timeout: 20) { model in
                        model.items.count == names.count - 1
                            && !model.items.contains { $0.url.lastPathComponent == names[1] }
                            && model.selection?.lastPathComponent == names[2]
                    }
                    try app.press(.undo)
                    try app.wait("⌘Z to bring it back", timeout: 20) { $0.items.count == names.count }
                    app.covered(.feature("library.filter"), via: .key)
                }
            }
        }
    }
#endif
