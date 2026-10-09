#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import ImageIO
    import RedlampDocument
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import UniformTypeIdentifiers

    /// A scratch folder holding the stacks the library finds (LIB-28): a raw beside its JPEG, a burst of three frames a
    /// third of a second apart from one camera with one exposure length, and three photos alone, each taken an hour
    /// after the last.
    struct StackScratch {
        static let raw = "PAIR_0001.NEF"
        static let jpeg = "PAIR_0001.JPG"
        static let burst = ["BURST_1.JPG", "BURST_2.JPG", "BURST_3.JPG"]
        static let alone = ["SOLO_A.JPG", "SOLO_B.JPG", "SOLO_C.JPG"]

        let sources: SourcesScratch

        init(_ app: RunningApp) throws {
            guard let nef = try FileManager.default.contentsOfDirectory(at: app.photos, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension.uppercased() == "NEF" })
            else { throw ScenarioSkip("The run's folder has no NEF to stand beside a JPEG") }
            sources = try SourcesScratch(app, photos: [Self.jpeg] + Self.burst + Self.alone)
            for (frame, name) in Self.burst.enumerated() {
                try Self.jpeg(number: frame, captured: "2026:10:08 10:00:00", subseconds: 10 + 30 * frame)
                    .write(to: sources.photo(name))
            }
            for (place, name) in Self.alone.enumerated() {
                try Self.jpeg(number: 10 + place, captured: "2026:10:08 1\(1 + place):00:00", subseconds: 0)
                    .write(to: sources.photo(name))
            }
            try FileManager.default.copyItem(at: nef, to: sources.photo(Self.raw))
        }

        /// A small JPEG taken at `captured` and `subseconds` hundredths, by one camera at 1/500 s.
        static func jpeg(number: Int, captured: String, subseconds: Int) throws -> Data {
            guard let source = try CGImageSourceCreateWithData(SourcesScratch.jpeg(number: number) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw ScenarioFailure("The scratch JPEG wasn't read") }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw ScenarioFailure("No JPEG encoder") }
            let properties: [CFString: Any] = [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: captured,
                    kCGImagePropertyExifSubsecTimeOriginal: String(format: "%02d", subseconds),
                    kCGImagePropertyExifExposureTime: 1.0 / 500,
                ],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Redlamp", kCGImagePropertyTIFFModel: "E2E Burst",
                ],
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ScenarioFailure("The JPEG wasn't written") }
            return data as Data
        }
    }

    extension RunningApp {
        /// Runs `body` on a scratch folder with stacks (`StackScratch`), added to Folders and shown in Library's grid
        /// from the library, compact, once its pair and its burst are found and closed; then takes it out of Folders,
        /// removes it, and shows the run's folder again, ungrouped with its stacks open, also when `body` fails.
        func withStacks(_ body: (StackScratch) throws -> Void) throws {
            let scratch = try StackScratch(self)
            defer {
                try? main { model in
                    model.setGroupKey(.ungrouped)
                    model.setCellStyle(.compact)
                    model.gridStacks.openAll()
                }
                removeScratch(scratch.sources)
                try? openWorking()
            }
            try scratch.sources.index(self)
            try main { model in
                model.setCellStyle(.compact)
                model.setGroupKey(.ungrouped)
                model.gridStacks.closeAll()
            }
            try press(.gridView)
            try wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }
            try waitForStacks("the pair and the burst found, closed", open: 0, closed: 2, timeout: 60)
            try wait("their cells") { _ in GroupScenarios.onScreen().contains("grid.\(StackScratch.burst[0])") }
            try body(scratch)
        }

        /// Waits for the source's stacks to be `open` and `closed`; a failure says what's shown.
        func waitForStacks(_ what: String, open: Int, closed: Int, timeout: Double = 20) throws {
            do {
                try wait(what, timeout: timeout) { model in
                    model.gridStacks.list.map { $0.stacksShown == (open, closed) } ?? (open + closed == 0)
                }
            } catch {
                let state = try main { model in
                    let shown = model.gridStacks.list?.stacksShown
                    return "stacks \(shown.map { "\($0.open) open, \($0.closed) closed" } ?? "none"), "
                        + "\(model.items.count) photos, from the library \(model.library.isShownFromLibrary), "
                        + "cells \(GroupScenarios.onScreen())"
                }
                throw ScenarioFailure("\(error) (\(state))")
            }
        }

        /// Presses `action`'s key, or chooses its item in the menu bar on a keyboard without a key that types its
        /// character by itself; the way it took.
        func pressOrChoose(_ action: ShortcutAction) throws -> InputPath {
            do {
                try press(action)
                return .key
            } catch is ScenarioSkip {
                try choose(action)
                return .menu
            }
        }

        /// The ID of the photo named `name` among those shown.
        func photoID(_ name: String) throws -> Int64 {
            let id = try main { model in
                model.items.first { $0.name == name }.flatMap { model.library.photoID(of: $0.url) }
            }
            guard let id else { throw ScenarioFailure("\(name) isn't shown") }
            return id
        }

        /// What the grid's cell for `name` says of its stacks, as VoiceOver reads it.
        func cellValue(_ name: String) throws -> String {
            try main { _ in
                guard let window = Views.editorWindow, let root = window.contentView?.superview,
                      let grid = Views.all(NSView.self, in: root)
                      .first(where: { $0.accessibilityIdentifier() == "library.grid" })
                else { return "" }
                let element = (grid.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
                    .first { $0.accessibilityIdentifier() == "grid.\(name)" }
                return element?.accessibilityValue() as? String ?? ""
            }
        }
    }

    enum LibraryStackScenarios {
        static let all: [Scenario] = [shown, changes, perSource, order]

        static let order = Scenario(
            "library.stacks-order",
            "In an open burst, ⇧[ and ⇧] and the palette move the active photo up and down and a drag moves it to "
                + "another's place, each photo's sidecar keeping its place; Split Stack in the Photo menu splits the "
                + "stack before a photo and Remove from Stack in the filmstrip's menu takes one out, each one change ⌘Z "
                + "takes back",
            claims: [
                .action(.moveUpInStack), .action(.moveDownInStack), .action(.splitStack), .action(.removeFromStack),
                .feature("library.stacks"),
            ],
        ) { app in
            try app.withStacks { scratch in
                let burst = StackScratch.burst
                let ids = try burst.map(app.photoID)
                let changes = try app.main { $0.libraryPanels.undoCount }
                defer {
                    try? app.run("the stacks' changes taken back", timeout: 120) { model in
                        model.showModule(.library)
                        while model.libraryPanels.undoCount > changes, model.libraryPanels.undoInLibrary() == true {}
                        await model.libraryPanels.written()
                    }
                }
                /// Waits for the stack holding frame `holding` to be `frames`, by their places in the burst.
                func wait(_ what: String, for frames: [Int], holding: Int = 0) throws {
                    try app.wait(what, timeout: 60) { model in
                        model.gridStacks.list?.stacks.stack(containing: ids[holding])?.photos == frames.map { ids[$0] }
                    }
                }

                // The burst opened with S, its last frame active.
                try app.clickStill("grid.\(burst[0])")
                try app.press(.toggleStack)
                try app.waitForStacks("S to open the burst", open: 1, closed: 1)
                try app.clickStill("grid.\(burst[2])")

                // ⇧[ and ⇧], then the palette.
                try app.covered(.action(.moveUpInStack), via: app.pressOrChoose(.moveUpInStack))
                try wait("⇧[ to move the last frame up", for: [0, 2, 1])
                let place = SidecarStore().load(for: scratch.sources.photo(burst[1]))?.metadata?.stack?.position
                try app.expect(place == 2, "BURST_2's sidecar puts it at \(place.map(String.init) ?? "no place")")
                try app.covered(.action(.moveDownInStack), via: app.pressOrChoose(.moveDownInStack))
                try wait("⇧] to move it down again", for: [0, 1, 2])
                try app.runFromPalette(.moveUpInStack)
                try wait("the palette's Move Up in Stack", for: [0, 2, 1])
                app.covered(.action(.moveUpInStack), via: .palette)

                // Dragged onto the first frame, it takes its place.
                try app.simulateLibraryDrags(true)
                defer { try? app.simulateLibraryDrags(false) }
                try app.dragGridPhoto(burst[2], onto: "grid.\(burst[0])")
                try wait("the drag onto the first frame", for: [2, 0, 1])
                app.covered(.feature("library.stacks"), via: .mouse)

                // Split before the first frame from the Photo menu: the last one dragged up stands alone.
                try app.clickStill("grid.\(burst[0])")
                try app.choose(.splitStack)
                try wait("Split Stack to split it", for: [0, 1])
                try app.waitForStacks("the half below open", open: 1, closed: 1)
                app.covered(.action(.splitStack), via: .menu)

                // Remove from Stack in the filmstrip's menu: neither is in a stack.
                let strip = try app.frame(of: .filmstrip(burst[1]))
                try app.chooseInContextMenu(
                    ShortcutAction.removeFromStack.title, at: NSPoint(x: strip.midX, y: strip.midY),
                    submenu: "Stacking",
                )
                try app.waitForStacks(
                    "Remove from Stack to leave the pair alone a stack",
                    open: 0,
                    closed: 1,
                    timeout: 60,
                )
                app.covered(.action(.removeFromStack), via: .mouse)

                for (step, frames) in [[0, 1], [2, 0, 1], [0, 2, 1], [0, 1, 2], [0, 2, 1], [0, 1, 2]].enumerated() {
                    try app.press(.undo)
                    try wait("⌘Z \(step + 1) to take a change back", for: frames)
                }
                try app.wait("⌘Z to make it a burst again", timeout: 30) { model in
                    model.gridStacks.list?.stacks.stack(containing: ids[0])?.kind == .burst
                }
            }
        }

        static let perSource = Scenario(
            "library.stacks-per-source",
            "Each source keeps which of its stacks are open, as it keeps its Group By: a burst opened with S, and a "
                + "pair left closed, are so again when the folder is shown again after another",
            claims: [.action(.toggleStack), .feature("library.stacks")],
        ) { app in
            try app.withStacks { scratch in
                let (raw, jpeg, burst) = (StackScratch.raw, StackScratch.jpeg, StackScratch.burst)
                try app.clickStill("grid.\(burst[0])")
                try app.wait("the burst's three photos selected") { model in
                    Set(model.selectedPhotos.map(\.lastPathComponent)) == Set(burst)
                }
                try app.press(.toggleStack)
                try app.waitForStacks("S to open the burst", open: 1, closed: 1)
                let (photos, folder) = (app.photos, scratch.sources.folder)
                try app.main { $0.showFolder(photos) }
                try app.wait("the run's folder", timeout: 30) { $0.folder == photos && !$0.library.isListing }
                try app.main { $0.showFolder(folder) }
                try app.wait("the scratch folder again", timeout: 30) { $0.folder == folder && !$0.library.isListing }
                try app.waitForStacks("the burst open and the pair closed again", open: 1, closed: 1, timeout: 30)
                try app.wait("the burst's frames with cells of their own, the JPEG without") { _ in
                    let cells = GroupScenarios.onScreen()
                    return burst.allSatisfy { cells.contains("grid.\($0)") } && cells.contains("grid.\(raw)")
                        && !cells.contains("grid.\(jpeg)")
                }
                app.covered([.action(.toggleStack), .feature("library.stacks")], via: .key)
            }
        }

        /// The names of the photos shown whose metadata `holds` what's looked for.
        @MainActor static func names(in model: EditorModel, where holds: (PhotoMetadata) -> Bool) -> Set<String> {
            Set(model.items.filter { holds($0.metadata) }.map(\.name))
        }

        static let shown = Scenario(
            "library.stacks",
            "A raw and its JPEG show as one photo and a burst as one cell with its count, in the grid, the filmstrip and "
                + "Group By's groups; S, a click on the count, the context menu, the Photo menu and the palette open and "
                + "close them, and a closed stack's selection, culling and keywords reach all its photos",
            claims: [
                .action(.toggleStack), .action(.openAllStacks), .action(.closeAllStacks), .feature("library.stacks"),
                .feature("library.grid"),
            ],
        ) { app in
            try app.withStacks { _ in
                let (raw, jpeg, burst) = (StackScratch.raw, StackScratch.jpeg, StackScratch.burst)
                var cells = try app.main { _ in GroupScenarios.onScreen() }
                try app.expect(
                    cells.contains("grid.\(raw)") && !cells.contains("grid.\(jpeg)")
                        && cells.contains("grid.\(burst[0])") && !cells.contains("grid.\(burst[1])"),
                    "The pair and the burst aren't one cell each: \(cells)",
                )
                let (burstValue, rawValue) = try (app.cellValue(burst[0]), app.cellValue(raw))
                try app.expect(burstValue.contains("a stack of 3, closed"), "The burst's cell says \(burstValue)")
                try app.expect(rawValue.contains("a pair, closed"), "The raw's cell says \(rawValue)")
                try app.expect(
                    try app.exists(.filmstrip(raw)) && !app.exists(.filmstrip(jpeg))
                        && app.exists(.filmstrip(burst[0])) && !app.exists(.filmstrip(burst[2])),
                    "The filmstrip doesn't show the stacks closed",
                )

                // A closed stack's cell selects all of it, and culling and keywords reach every photo.
                try app.clickStill("grid.\(burst[0])")
                try app.wait("the burst's three photos selected") { model in
                    Set(model.selectedPhotos.map(\.lastPathComponent)) == Set(burst)
                }
                app.covered(.feature("library.grid"), via: .mouse)
                try app.press(.flagPick)
                try app.wait("P on every frame of the burst") { model in
                    names(in: model) { $0.flag == .pick } == Set(burst)
                }
                try app.press(.undo)
                try app.wait("⌘Z to take the flags back") { model in names(in: model) { $0.flag == .pick }.isEmpty }
                try app.waitWritten()
                let keyword = "E2E Stacked \(UUID().uuidString.prefix(4))"
                guard let path = KeywordPath(keyword) else { throw ScenarioFailure("No keyword path") }
                try app.wait("the panels following the burst", timeout: 30) { $0.libraryPanels.selection.count == 3 }
                try app.run("a keyword on the burst", timeout: 120) { model in
                    model.libraryPanels.addKeywords(keyword)
                    await model.libraryPanels.written()
                    await model.libraryPanels.keywordsRead()
                }
                let tagged = try app.main { $0.libraryPanels.keywordList?[path]?.count ?? 0 }
                try app.run("the keyword taken off and deleted", timeout: 120) { model in
                    model.libraryPanels.delete(path)
                    await model.libraryPanels.written()
                }
                try app.expect(tagged == 3, "The keyword reached \(tagged) of the burst's photos")

                // S, a click on the count, the context menu, the Photo menu and the palette.
                try app.press(.toggleStack)
                try app.waitForStacks("S to open the burst", open: 1, closed: 1)
                try app.wait("its frames' cells") { _ in GroupScenarios.onScreen().contains("grid.\(burst[2])") }
                try app.expect(try app.exists(.filmstrip(burst[2])), "The filmstrip didn't open the burst")
                app.covered(.action(.toggleStack), via: .key)
                try app.press(.toggleStack)
                try app.waitForStacks("S to close it", open: 0, closed: 2)
                try app.wait("the burst's three photos still selected") { model in
                    Set(model.selectedPhotos.map(\.lastPathComponent)) == Set(burst)
                }
                let size = try app.main { $0.libraryViews.thumbnailSize }
                try app.click(.identifier("grid.\(burst[0])"), at: LibraryGridViews.point(ofStackCount: 3, size: size))
                try app.waitForStacks("a click on the count to open the burst", open: 1, closed: 1)
                try app.click(.identifier("grid.\(burst[0])"), at: LibraryGridViews.point(ofStackCount: 3, size: size))
                try app.waitForStacks("a click on the count to close it", open: 0, closed: 2)
                app.covered(.feature("library.stacks"), via: .mouse)
                let pair = try app.frame(of: .identifier("grid.\(raw)"))
                try app.chooseInContextMenu(
                    ShortcutAction.toggleStack.title, at: NSPoint(x: pair.midX, y: pair.midY), submenu: "Stacking",
                )
                try app.wait("the context menu to open the pair") { _ in
                    GroupScenarios.onScreen().contains("grid.\(jpeg)")
                }
                app.covered(.action(.toggleStack), via: .mouse)
                try app.choose(.openAllStacks)
                try app.waitForStacks("Open All Stacks", open: 2, closed: 0)
                cells = try app.main { _ in GroupScenarios.onScreen() }
                try app.expect(
                    ([raw, jpeg] + burst + StackScratch.alone).allSatisfy { cells.contains("grid.\($0)") },
                    "Open, every photo has a cell: \(cells)",
                )
                app.covered(.action(.openAllStacks), via: .menu)
                try app.runFromPalette(.closeAllStacks)
                try app.waitForStacks("the palette's Close All Stacks", open: 0, closed: 2)
                app.covered(.action(.closeAllStacks), via: .palette)

                // Group By keeps each stack whole and closed in its group, and opens it there.
                try app.main { $0.setGroupKey(.camera) }
                try app.wait("grouped by camera, the stacks closed in their groups", timeout: 30) { model in
                    model.gridGroups.list.map { list in
                        list.groups.key == .camera && list.stacked.stacksShown == (0, 2)
                    } == true
                }
                try app.wait("a header and the burst's cell") { _ in
                    let shown = GroupScenarios.onScreen()
                    return shown.contains { $0.hasPrefix("grid.group.") } && shown.contains("grid.\(burst[0])")
                        && !shown.contains("grid.\(burst[1])")
                }
                try app.clickStill("grid.\(burst[0])")
                try app.press(.toggleStack)
                try app.wait("S to open the burst in its group") { model in
                    model.gridGroups.list.map { $0.stacked.stacksShown == (1, 1) } == true
                        && model.gridStacks.list.map { $0.stacksShown == (1, 1) } == true
                }
                try app.wait("its frames' cells in the group") { _ in
                    GroupScenarios.onScreen().contains("grid.\(burst[2])")
                }
                try app.press(.toggleStack)
                try app.wait("S to close it") { model in
                    model.gridGroups.list.map { $0.stacked.stacksShown == (0, 2) } == true
                }
                try app.main { $0.setGroupKey(.ungrouped) }
                try app.wait("ungrouped") { $0.gridGroups.list == nil }

                // ← and → go from cell to cell, past a closed stack's photos.
                try app.clickStill("grid.\(raw)")
                let order = try app.main { model in
                    model.gridStacks.list.map { Array($0) }?.compactMap(model.library.url(ofPhoto:))
                        .map(\.lastPathComponent)
                        ?? []
                }
                guard let at = order.firstIndex(of: raw), order.indices.contains(at + 1) else {
                    throw ScenarioFailure("The pair's cell isn't followed by another: \(order)")
                }
                try app.press(.nextPhoto)
                try app.wait("→ to the next cell, past the JPEG") { $0.selection?.lastPathComponent == order[at + 1] }
                try app.press(.previousPhoto)
                try app.wait("← back to the pair") { $0.selection?.lastPathComponent == raw }
            }
        }

        static let changes = Scenario(
            "library.stacks-changes",
            "⌘G stacks the photos selected, ⇧S shows another photo for its stack and Unstack in the Photo menu takes "
                + "it apart, each one change ⌘Z takes back and ⇧⌘Z makes again, the grid following the library",
            claims: [
                .action(.stackPhotos), .action(.unstackPhotos), .action(.moveToStackTop), .feature("library.stacks"),
            ],
        ) { app in
            try app.withStacks { _ in
                let (first, second) = (StackScratch.alone[0], StackScratch.alone[1])
                let (firstID, secondID) = try (app.photoID(first), app.photoID(second))
                let changes = try app.main { $0.libraryPanels.undoCount }
                defer {
                    try? app.run("the stacks' changes taken back", timeout: 120) { model in
                        model.showModule(.library)
                        while model.libraryPanels.undoCount > changes, model.libraryPanels.undoInLibrary() == true {}
                        await model.libraryPanels.written()
                    }
                }
                @MainActor func top(_ model: EditorModel) -> Int64? {
                    model.gridStacks.list?.stacks.stack(containing: firstID)?.top
                }

                // ⌘G: the two photos stacked by hand, the active one on top.
                try app.clickStill("grid.\(first)")
                try app.clickStill("grid.\(second)", modifiers: .command)
                try app.press(.stackPhotos)
                try app.waitForStacks("⌘G to stack them", open: 0, closed: 3, timeout: 60)
                try app.expect(try app.main(top) == secondID, "The active photo isn't on top")
                try app.wait("the stack's one cell") { _ in
                    let shown = GroupScenarios.onScreen()
                    return shown.contains("grid.\(second)") && !shown.contains("grid.\(first)")
                }
                app.covered(.action(.stackPhotos), via: .key)

                // ⇧S: the stack opened, the other photo shown for it.
                try app.clickStill("grid.\(second)")
                try app.press(.toggleStack)
                try app.waitForStacks("S to open the stack", open: 1, closed: 2)
                try app.clickStill("grid.\(first)")
                try app.press(.moveToStackTop)
                try app.wait("⇧S to show it for the stack", timeout: 60) { top($0) == firstID }
                app.covered(.action(.moveToStackTop), via: .key)

                // Unstack from the Photo menu, ⇧⌘G being one of the ⇧⌘ keys synthetic events don't reach: both photos
                // alone again.
                try app.expectKeyBinding(.unstackPhotos)
                try app.choose(.unstackPhotos)
                try app.waitForStacks("Unstack to take the stack apart", open: 0, closed: 2, timeout: 60)
                try app.expect(try app.main(top) == nil, "The photo is still in a stack")
                app.covered(.action(.unstackPhotos), via: .menu)

                // ⌘Z takes each change back, the stack again with its top; ⇧⌘Z makes the last again.
                try app.press(.undo)
                try app.wait("⌘Z to stack them again", timeout: 60) { top($0) == firstID }
                // ⇧⌘Z: synthetic events don't reach SwiftUI's handling of ⇧⌘ keys, so its item runs from the menu.
                try app.expectKeyBinding(.redo)
                try app.choose(.redo)
                try app.wait("⇧⌘Z to take them apart again", timeout: 60) { top($0) == nil }
                try app.press(.undo)
                try app.wait("⌘Z once more", timeout: 60) { top($0) == firstID }
                try app.press(.undo)
                try app.wait("⌘Z to put the first top back", timeout: 60) { top($0) == secondID }
                try app.press(.undo)
                try app.waitForStacks("⌘Z to take the stack back", open: 0, closed: 2, timeout: 60)
            }
        }
    }
#endif
