#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import CoreGraphics
    import ImageIO
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import UniformTypeIdentifiers

    /// The left panel's Library section (LIB-23): All Photographs, Previous Import, Marked and Rejected, and
    /// Library Health's checks (LIB-40), each appearing with its count once it holds photos and shown by a click on
    /// its row, ⌘B, the View menu and the palette.
    enum LibraryPanelScenarios {
        static let all: [Scenario] = [libraryPanel, removedFolder, previousImportFollows, removeFolderPerformance]

        static let libraryPanel = Scenario(
            "library.library-panel",
            "The Library panel's entries and Library Health's checks, with their counts, shown by a click, ⌘B, the "
                + "View menu and the palette",
            claims: [
                .action(.showAllPhotographs), .action(.showPreviousImport), .action(.showMarked),
                .action(.showRejected), .feature("library.library-panel"),
            ],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg", "C.jpg"], empty: ["Empty.jpg"])
            defer { scratch.remove(app) }
            try scratch.index(app)
            let names = scratch.names

            // B on two photos and X on a third, from the grid: the run's other photos may be marked or rejected too.
            try app.run("the library counted") { model in
                model.librarySources.recount()
                await model.librarySources.counted()
            }
            let (marked, rejected) = try app.main { model in
                (model.librarySources.count(of: .marked) ?? 0, model.librarySources.count(of: .rejected) ?? 0)
            }
            try app.main { model in
                model.showLibrary(.grid)
                model.select(scratch.photo(names[0]))
                model.click(scratch.photo(names[1]), toggling: true)
            }
            try app.press(.toggleMark)
            try app.main { $0.select(scratch.photo(names[2])) }
            try app.press(.flagReject)
            let markedLabel = "Marked, \((marked + 2).formatted()) photos"
            try app.wait("the Library panel counting two more marked photos and a rejected one", timeout: 30) { _ in
                app.sourceRowLabel("sources.marked")?.hasPrefix(markedLabel) == true
                    && app.sourceRowLabel("sources.rejected")?
                    .hasPrefix("Rejected, \((rejected + 1).formatted()) photo")
                    == true
            }

            // A press on Marked's row shows its photos.
            app.step("pressing Marked's row")
            try app.clickSourceRow("sources.marked")
            try app.waitForSource("Marked's photos") { model in
                model.librarySources.shown == .marked && !model.librarySources.isListing
                    && Set(names.prefix(2)).isSubset(of: Set(model.items.map(\.name)))
                    && !model.items.map(\.name).contains(names[2])
            }

            // Marked's summary, and the folder's, from their rows' menus.
            try app.rightClickSourceRow("sources.marked", choosing: "Show Summary…")
            try app.wait("Marked's summary", timeout: 20) { _ in
                SourceSummaryPopover.shownLines.prefix(2).first == "Marked"
                    && SourceSummaryPopover.shownLines.dropFirst().first?
                    .hasPrefix("\((marked + 2).formatted()) photos")
                    == true
            }
            try app.main { _ in SourceSummaryPopover.close() }
            try app.rightClickSourceRow("folders." + scratch.folder.standardizedFileURL.path, choosing: "Show Summary…")
            try app.wait("the folder's summary", timeout: 20) { _ in
                let lines = SourceSummaryPopover.shownLines
                return lines.first == scratch.folder.lastPathComponent && lines.count > 2
                    && lines.last == "No pairs or stacks"
            }
            try app.main { _ in SourceSummaryPopover.close() }

            // ⌘B from the folder.
            app.step("⌘B from the folder")
            try app.main { $0.showFolder(scratch.folder) }
            try app.wait("the folder again", timeout: 20) { $0.folder == scratch.folder && !$0.library.isListing }
            try app.press(.showMarked)
            try app.waitForSource("Marked again") { $0.librarySources.shown == .marked }

            // The View menu, then the palette.
            try app.choose(.showRejected)
            try app.waitForSource("Rejected's photo", timeout: 20) { model in
                model.librarySources.shown == .rejected && model.items.map(\.name).contains(names[2])
                    && !model.items.map(\.name).contains(names[0])
            }
            try app.runFromPalette(.showAllPhotographs)
            try app.waitForSource("All Photographs", timeout: 20) { model in
                model.librarySources.shown == .allPhotographs && !model.librarySources.isListing
                    && Set(names).isSubset(of: Set(model.items.map(\.name)))
            }

            // Library Health: the empty file under Damaged Files, from its row.
            app.step("Library Health's Damaged Files")
            try app.wait("Library Health's Damaged Files", timeout: 30) { _ in
                app.sourceRowLabel("sources.health.damaged")?.hasPrefix("Damaged Files, ") == true
            }
            try app.clickSourceRow("sources.health.damaged")
            try app.waitForSource("the damaged file", timeout: 20) { model in
                model.librarySources.shown == .health(.damaged) && model.items.map(\.name).contains("Empty.jpg")
            }

            // Previous Import, from the palette, once an import has copied a photo.
            app.step("an import for Previous Import")
            let imported = try ImportScratch(app, photos: 1)
            defer { imported.remove(app) }
            try app.main { _ in ImportWindowController.ignoresVolumes = true }
            try app.choose(.importPhotos)
            try app.waitForImportWindow()
            try app.inImportWindow { window in
                window.prepare(
                    destination: imported.destination,
                    backup: imported.backup,
                    folders: "Imported",
                    names: "{name}",
                )
            }
            try app
                .run("adding the folder") { _ in try? await ImportWindowController.current?.add(folder: imported.card) }
            try app.wait("the folder browsed", timeout: 60) { _ in
                ImportWindowController.current.map { $0.isBrowsed && $0.photoCount == 1 } == true
            }
            try app.clickInImportWindow("import.import")
            try app.wait("the import", timeout: 120) { _ in ImportWindowController.current?.isFinished == true }
            try app.main { _ in ImportWindowController.current?.close() }
            try app.runFromPalette(.showPreviousImport)
            try app.waitForSource("Previous Import's photo", timeout: 30) { model in
                model.librarySources.shown == .previousImport && model.items.map(\.name) == imported.names
            }
            try app.wait("Previous Import's row", timeout: 30) { _ in
                app.sourceRowLabel("sources.previous-import") == "Previous Import, 1 photo, shown"
            }
            app.covered(.feature("library.library-panel"), via: .mouse)

            // As the run had it.
            let photos = app.photos
            try app.main { model in
                model.showFolder(photos)
                model.showModule(.develop)
            }
            try app.wait("the photos folder again", timeout: 20) { $0.folder == photos && !$0.library.isListing }
        }
    }

    /// A folder of small JPEGs of the run's own on the external disk's scratch folder, each its own colour (a
    /// name with a slash in a subfolder), and empty files written ten minutes ago, added to Folders; taken out of
    /// Folders and removed afterwards.
    struct SourcesScratch: Sendable {
        let folder: URL
        let names: [String]

        init(_: RunningApp, photos: [String], empty: [String] = []) throws {
            folder = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
                .appending(path: "e2e-sources-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            names = photos
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (number, name) in photos.enumerated() {
                try FileManager.default.createDirectory(
                    at: photo(name).deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                try Self.jpeg(number: number).write(to: photo(name))
            }
            let earlier = Date().addingTimeInterval(-600)
            for name in empty {
                try Data().write(to: photo(name))
                try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: photo(name).path)
            }
        }

        func photo(_ name: String) -> URL {
            folder.appending(path: name, directoryHint: .notDirectory)
        }

        /// Adds the folder to Folders and opens it, in Library, once the library has indexed it.
        func index(_ app: RunningApp) throws {
            let service = try app.main { $0.library.service }
            guard let service else { throw ScenarioSkip("the library is off") }
            let folder = folder
            try app.main { model in
                model.open([folder])
                model.showLibrary(.grid)
            }
            let indexed = Flag()
            try app.run("the library to index \(folder.lastPathComponent)", timeout: 90) { _ in
                for _ in 0 ..< 900 where await !service.canShow(folder, includingSubfolders: true) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if await service.canShow(folder, includingSubfolders: true) {
                    indexed.set()
                }
            }
            try app.expect(indexed.isSet, "the library didn't index \(folder.path)")
            try app.main { $0.showFolder(folder) }
            try app.wait("the folder from the library", timeout: 30) { model in
                model.folder == folder && !model.library.isListing && model.library.isShownFromLibrary
            }
        }

        func remove(_ app: RunningApp) {
            let folder = folder
            try? app.main { model in
                if let root = model.library.root(containing: folder) {
                    model.library.remove(root)
                }
            }
            try? FileManager.default.removeItem(at: folder)
        }

        static func jpeg(number: Int) throws -> Data {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
                  )
            else { throw ScenarioFailure("No bitmap context") }
            context.setFillColor(
                red: CGFloat(number % 7) / 7, green: CGFloat(number % 5) / 5, blue: CGFloat(number % 3) / 3, alpha: 1,
            )
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            let data = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw ScenarioFailure("No JPEG encoder") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ScenarioFailure("The JPEG wasn't written") }
            return data as Data
        }
    }

    extension RunningApp {
        /// Waits for a source to show what `condition` wants; a failure says what's shown instead.
        func waitForSource(
            _ what: String, timeout: Double = 20, _ condition: @escaping @MainActor (EditorModel) -> Bool,
        ) throws {
            do {
                try wait(what, timeout: timeout, until: condition)
            } catch {
                let state = try main { model in
                    let sources = model.librarySources
                    return "shown \(sources.shown.map { "\($0)" } ?? "none"), listing \(sources.isListing), "
                        + "\(model.items.count) photos \(model.items.prefix(4).map(\.name)), folder "
                        + "\(model.folder?.lastPathComponent ?? "none"), \(model.module), selection "
                        + "\(model.selection?.lastPathComponent ?? "none"), sheet \(model.isModalDialogOpen)"
                }
                throw ScenarioFailure("\(error) (\(state))")
            }
        }

        /// Presses the Library or Collections section's row carrying `identifier`, as the mouse does: the list shows
        /// its source as it's pressed. A list in a window that isn't key takes the press as the click after
        /// activation would.
        func clickSourceRow(_ identifier: String) throws {
            let location = try main { _ -> NSPoint in
                guard let window = Views.editorWindow, let root = window.contentView?.superview,
                      let row = Views.all(NSView.self, in: root).first(where: {
                          $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor
                      })
                else { throw ScenarioFailure("\(identifier) isn't on screen") }
                row.scrollToVisible(row.bounds)
                let frame = row.convert(row.bounds, to: nil)
                return NSPoint(x: frame.midX, y: frame.midY)
            }
            post { _ in
                guard let window = Views.editorWindow, let root = window.contentView?.superview,
                      let row = Views.all(NSView.self, in: root)
                      .first(where: { $0.accessibilityIdentifier() == identifier }),
                      let press = NSEvent.mouseEvent(
                          with: .leftMouseDown, location: location, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
                      )
                else { return }
                var list = row.superview
                while let view = list, !(view is NSOutlineView) {
                    list = view.superview
                }
                if window.isKeyWindow {
                    window.sendEvent(press)
                } else {
                    list?.mouseDown(with: press)
                }
            }
            pause(0.2)
        }

        /// Right-clicks the left panel's row carrying `identifier`, as the mouse does, and chooses the item `path`
        /// names in the menu that opens, a submenu's title first ("Move To", then the set). The menu tracks inside
        /// the press, so the driver asks the main thread nothing until the press has begun: a question queued with
        /// it would wait behind the menu, which waits for the question.
        func rightClickSourceRow(_ identifier: String, choosing path: String...) throws {
            step("right-clicking \(identifier)")
            let location = try main { _ -> NSPoint in
                guard let window = Views.editorWindow, let root = window.contentView?.superview,
                      let row = Views.all(NSView.self, in: root).first(where: {
                          $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor
                      })
                else { throw ScenarioFailure("\(identifier) isn't on screen") }
                row.scrollToVisible(row.bounds)
                window.contentView?.layoutSubtreeIfNeeded()
                let frame = row.convert(row.bounds, to: nil)
                return NSPoint(x: frame.midX, y: frame.midY)
            }
            let opened = OpenedMenu()
            try main { _ in opened.watch() }
            defer { try? main { _ in opened.stop() } }
            let pressed = Flag()
            post { _ in
                pressed.set()
                guard let window = Views.editorWindow else { return }
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseUp ? 0 : 1,
                    ) else { continue }
                    window.sendEvent(event)
                }
            }
            for _ in 0 ..< 1000 where !pressed.isSet {
                pause(0.01)
            }
            do {
                try wait("\(identifier)'s context menu to open") { _ in opened.menu != nil }
            } catch {
                let state = try main { _ -> String in
                    let window = Views.editorWindow
                    let hit = window?.contentView?.superview?.hitTest(location)
                    let menus = NSApp.windows.filter { $0.isVisible && "\(Swift.type(of: $0))".contains("Menu") }.count
                    return "pressed \(pressed.isSet), \(hit.map { "\(Swift.type(of: $0))" } ?? "nothing") at \(location), "
                        + "\(menus) menus open, key \(window?.isKeyWindow == true), sheet \(window?.attachedSheet != nil)"
                }
                throw ScenarioFailure("\(error) (\(state))")
            }
            try main { _ in
                guard let menu = opened.menu else { return }
                defer { menu.cancelTracking() }
                var current = menu
                for (depth, title) in path.enumerated() {
                    guard let index = current.items.firstIndex(where: { $0.title == title }) else {
                        throw ScenarioFailure(
                            "\(identifier)'s menu has no \(path.prefix(depth + 1).joined(separator: " › ")): "
                                + "\(current.items.map(\.title))",
                        )
                    }
                    if depth == path.count - 1 {
                        current.performActionForItem(at: index)
                    } else if let submenu = current.items[index].submenu {
                        current = submenu
                    }
                }
            }
            try wait("\(identifier)'s context menu to close") { _ in opened.closed }
        }

        /// What VoiceOver says of the Library or Collections section's row carrying `identifier`: its name and
        /// count ("Marked, 2 photos"); nil while it isn't on screen.
        @MainActor func sourceRowLabel(_ identifier: String) -> String? {
            guard let root = Views.editorWindow?.contentView?.superview else { return nil }
            return Views.all(NSView.self, in: root)
                .first { $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor }?
                .accessibilityLabel()
        }
    }
#endif
