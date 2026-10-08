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
        static let all: [Scenario] = [libraryPanel]

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

            // B on two photos and X on a third, from the grid.
            try app.main { model in
                model.showLibrary(.grid)
                model.select(scratch.photo(names[0]))
                model.click(scratch.photo(names[1]), toggling: true)
            }
            try app.press(.toggleMark)
            try app.main { $0.select(scratch.photo(names[2])) }
            try app.press(.flagReject)
            try app.wait("the Library panel counting two marked photos and a rejected one", timeout: 30) { _ in
                app.sourceRowLabel("sources.marked")?.hasPrefix("Marked, 2 photos") == true
                    && app.sourceRowLabel("sources.rejected") == "Rejected, 1 photo"
            }

            // A click on Marked's row shows its photos.
            try app.clickSourceRow("sources.marked")
            try app.wait("Marked's two photos", timeout: 20) { model in
                model.librarySources.shown == .marked && !model.librarySources.isListing
                    && Set(model.items.map(\.name)) == Set(names.prefix(2))
            }

            // Marked's summary, and the folder's, from their rows' menus.
            try app.rightClick(.identifier("sources.marked"), choosing: "Show Summary…")
            try app.wait("Marked's summary", timeout: 20) { _ in
                SourceSummaryPopover.shownLines.prefix(2) == ["Marked", "2 photos"]
            }
            try app.main { _ in SourceSummaryPopover.close() }
            try app.rightClick(
                .identifier("folders." + scratch.folder.standardizedFileURL.path),
                choosing: "Show Summary…",
            )
            try app.wait("the folder's summary", timeout: 20) { _ in
                let lines = SourceSummaryPopover.shownLines
                return lines.first == scratch.folder.lastPathComponent && lines.count > 2
                    && lines.last == "No pairs or stacks"
            }
            try app.main { _ in SourceSummaryPopover.close() }

            // ⌘B from the folder.
            try app.main { $0.showFolder(scratch.folder) }
            try app.wait("the folder again", timeout: 20) { $0.folder == scratch.folder && !$0.library.isListing }
            try app.press(.showMarked)
            try app.wait("Marked again") { $0.librarySources.shown == .marked }

            // The View menu, then the palette.
            try app.choose(.showRejected)
            try app.wait("Rejected's photo", timeout: 20) { model in
                model.librarySources.shown == .rejected && model.items.map(\.name) == [names[2]]
            }
            try app.runFromPalette(.showAllPhotographs)
            try app.wait("All Photographs", timeout: 20) { model in
                model.librarySources.shown == .allPhotographs && !model.librarySources.isListing
                    && Set(names).isSubset(of: Set(model.items.map(\.name)))
            }

            // Library Health: the empty file under Damaged Files, from its row.
            try app.wait("Library Health's Damaged Files", timeout: 30) { _ in
                app.sourceRowLabel("sources.health.damaged")?.hasPrefix("Damaged Files, ") == true
            }
            try app.clickSourceRow("sources.health.damaged")
            try app.wait("the damaged file", timeout: 20) { model in
                model.librarySources.shown == .health(.damaged) && model.items.map(\.name).contains("Empty.jpg")
            }

            // Previous Import, from the palette, once an import has copied a photo.
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
            try app.wait("Previous Import's photo", timeout: 30) { model in
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

    /// A folder of small JPEGs of the run's own on the external disk's scratch folder, each its own colour, and
    /// empty files written ten minutes ago, added to Folders; taken out of Folders and removed afterwards.
    struct SourcesScratch: Sendable {
        let folder: URL
        let names: [String]

        init(_: RunningApp, photos: [String], empty: [String] = []) throws {
            folder = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
                .appending(path: "e2e-sources-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            names = photos
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (number, name) in photos.enumerated() {
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
        /// Clicks the Library or Collections section's row carrying `identifier`, as the mouse does: the press goes
        /// to its list, which tracks it, and the release waits in the queue, where the list takes it from. A list
        /// in a window that isn't key takes the press as the click after activation would.
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
                      .first(where: { $0.accessibilityIdentifier() == identifier })
                else { return }
                var list = row.superview
                while let view = list, !(view is NSOutlineView) {
                    list = view.superview
                }
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    )
                }
                guard events.count == 2, let list else { return }
                NSApp.postEvent(events[1], atStart: false)
                if window.isKeyWindow {
                    window.sendEvent(events[0])
                } else {
                    list.mouseDown(with: events[0])
                }
            }
            pause(0.2)
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
