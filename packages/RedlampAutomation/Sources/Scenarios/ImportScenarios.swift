#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The import window (LIB-27), from copies of the run's raws in a folder of the run's own: never a
    /// card, and never this Mac's volumes, which the window is told to leave alone.
    enum ImportScenarios {
        static let all: [Scenario] = [fromFolder, cardMoments, rangeSelection, performance]

        static let cardMoments = Scenario(
            "import.card-moments",
            "A card's photos show in the import window in moments, the newest first, each under its header, and "
                + "Group By shows them ungrouped and in moments again",
            claims: [.feature("library.import")],
        ) { app in
            try app.openWorking()
            let card = try ImportCardScratch(app)
            defer { card.remove(app) }
            try app.main { _ in ImportWindowController.ignoresVolumes = true }
            try app.choose(.importPhotos)
            try app.waitForImportWindow()
            try app.run("adding the card") { _ in try? await ImportWindowController.current?.add(card: card.root) }
            try app.wait("the card browsed", timeout: 60) { _ in
                ImportWindowController.current.map { $0.isBrowsed && $0.photoCount == card.count } == true
            }
            // Each raw's copies were taken together, and the raws apart: a moment for each, as the heads say,
            // once the photos are grouped by every capture time browsing read.
            try app.run("the photos grouped again") { _ in await ImportWindowController.current?.regrouped() }
            let raws = Set(card.originals.values).count
            try app.wait("a moment for each raw's copies", timeout: 30) { _ in
                guard let window = ImportWindowController.current, window.grouping == "Moment" else { return false }
                let groups = window.groups
                return groups.count == raws && groups.allSatisfy { group in
                    !group.name.isEmpty && Set(group.photos.compactMap { card.originals[$0] }).count == 1
                }
            }
            let order = try app.inImportWindow { window in window.groups.flatMap(\.photos) }
            try app.chooseInImportWindow("None", inPopUp: "import.group-by")
            try app.wait("the photos ungrouped") { _ in
                ImportWindowController.current.map { $0.groups.count == 1 && $0.groups[0].name.isEmpty } == true
            }
            try app.chooseInImportWindow("Moment", inPopUp: "import.group-by")
            try app.wait("in moments again") { _ in
                ImportWindowController.current.map { $0.groups.count == raws } == true
            }
            try app.expect(
                try app.inImportWindow { window in window.groups.flatMap(\.photos) } == order, "the same order",
            )
            app.covered(.feature("library.import"), via: .mouse)
        }

        static let rangeSelection = Scenario(
            "import.range-selection",
            "In the import grid a click selects a photo, Shift-click every photo from it through another across "
                + "moments, Command-click one fewer, a moment's header its photos and Shift-click on another header "
                + "adds those, Shift with the arrow keys extends from the photo clicked, and Shift still extends "
                + "from it once Group By has changed",
            claims: [.feature("library.import")],
        ) { app in
            try app.openWorking()
            let card = try ImportCardScratch(app)
            defer { card.remove(app) }
            try app.main { _ in ImportWindowController.ignoresVolumes = true }
            try app.choose(.importPhotos)
            try app.waitForImportWindow()
            try app.run("adding the card") { _ in try? await ImportWindowController.current?.add(card: card.root) }
            try app.wait("the card browsed", timeout: 60) { _ in
                ImportWindowController.current.map { $0.isBrowsed && $0.photoCount == card.count } == true
            }
            try app.run("the photos grouped again") { _ in await ImportWindowController.current?.regrouped() }
            let raws = Set(card.originals.values).count
            guard raws >= 3 else { throw ScenarioFailure("The card needs three moments, and the run has \(raws) raws") }
            try app.wait("a moment for each raw's copies", timeout: 30) { _ in
                ImportWindowController.current.map { $0.grouping == "Moment" && $0.groups.count == raws } == true
            }
            // Each moment holds a raw's three copies: moment m is places 3m to 3m + 2.
            let moment = { (index: Int) in Array(3 * index ... 3 * index + 2) }

            try app.clickInImportGrid(photo: 1)
            try app.expectImportSelection([1], "a click")
            try app.clickInImportGrid(photo: 7, modifiers: .shift)
            try app.expectImportSelection(Array(1 ... 7), "Shift-click, across the moments")
            try app.clickInImportGrid(photo: 4, modifiers: .command)
            try app.expectImportSelection([1, 2, 3, 5, 6, 7], "Command-click")
            try app.clickInImportGrid(group: 2)
            try app.expectImportSelection(moment(2), "a click on the third moment's header")
            try app.clickInImportGrid(group: 0, modifiers: .shift)
            try app.expectImportSelection(moment(0) + moment(2), "Shift-click on the first's")

            try app.clickInImportGrid(photo: 3)
            for _ in 0 ..< 2 {
                try app.pressInImportWindow(KeyCombo(.right, shift: true))
            }
            try app.expectImportSelection([3, 4, 5], "Shift-→ twice")
            for _ in 0 ..< 3 {
                try app.pressInImportWindow(KeyCombo(.left, shift: true))
            }
            try app.expectImportSelection([2, 3], "Shift-← three times, from the photo clicked")

            // Ungrouped, the photos are in another order: the selection and the photo clicked are followed by name.
            let inMoments = try app.inImportWindow { window in window.groups.flatMap(\.photos) }
            try app.chooseInImportWindow("None", inPopUp: "import.group-by")
            try app.wait("the photos ungrouped") { _ in
                ImportWindowController.current.map { $0.groups.count == 1 && $0.groups[0].name.isEmpty } == true
            }
            let ungrouped = try app.inImportWindow { window in window.groups.flatMap(\.photos) }
            guard let clicked = ungrouped.firstIndex(of: inMoments[3]),
                  let other = ungrouped.firstIndex(of: inMoments[2])
            else { throw ScenarioFailure("The photos ungrouped aren't those in moments: \(ungrouped)") }
            try app.expectImportSelection([clicked, other].sorted(), "the selection kept as the grid is reloaded")
            let target = clicked + 2 < ungrouped.count ? clicked + 2 : clicked - 2
            try app.clickInImportGrid(photo: target, modifiers: .shift)
            try app.expectImportSelection(
                Array(min(clicked, target) ... max(clicked, target)),
                "Shift-click from the photo clicked before the reload",
            )
            try app.chooseInImportWindow("Moment", inPopUp: "import.group-by")
            app.covered(.feature("library.import"), via: .mouse)
        }

        static let fromFolder = Scenario(
            "import.from-folder",
            "Import Photos… copies a folder's photos, rated, flagged and labelled from the grid's keys and given a "
                + "metadata preset chosen in To, to a destination and a backup, and Library shows them selected",
            claims: [.action(.importPhotos), .feature("library.import")],
        ) { app in
            try app.openWorking()
            let scratch = try ImportScratch(app, photos: 3)
            defer { scratch.remove(app) }
            let preset = MetadataPreset(name: "E2E Import", fields: [
                .caption: MetadataPreset.Entry("E2E imported"), .copyright: MetadataPreset.Entry("© E2E"),
            ])
            try app.run("a metadata preset made in the library") { _ = await $0.libraryPanels.save(preset) }
            defer {
                try? app.run("the preset removed") { _ = await $0.libraryPanels.deletePreset(named: preset.name) }
            }
            try app.main { _ in ImportWindowController.ignoresVolumes = true }
            // ⇧⌘I: synthetic events don't reach SwiftUI's handling of ⇧⌘ keys, so its item runs from the menu.
            try app.expectKeyBinding(.importPhotos)
            try app.choose(.importPhotos)
            try app.waitForImportWindow()
            try app.inImportWindow { window in
                window.prepare(
                    destination: scratch.destination,
                    backup: scratch.backup,
                    folders: "Imported",
                    names: "{name}",
                )
            }
            try app.wait("the library's presets in To") { _ in
                ImportWindowController.current?.presetNames.contains(preset.name) == true
            }
            try app.chooseInImportWindow(preset.name, inPopUp: "import.preset")
            try app.wait("the preset chosen") { _ in ImportWindowController.current?.presetChosen == preset.name }
            try app
                .run("adding the folder") { _ in try? await ImportWindowController.current?.add(folder: scratch.card) }
            try app.wait("the folder browsed", timeout: 60) { _ in
                ImportWindowController.current.map { $0.isBrowsed && $0.photoCount == 3 } == true
            }

            // The newest two photos selected, then Library's keys typed in the grid.
            try app.inImportWindow { $0.select([0, 1]) }
            for key in ["3", "p", "6"] {
                try app.pressInImportWindow(KeyCombo(.character(Character(key))))
            }
            try app.wait("the keys' choices on the photos") { _ in
                guard let window = ImportWindowController.current else { return false }
                return window.badges(at: 0) == "★★★  Pick  Red" && window.badges(at: 1) == "★★★  Pick  Red"
                    && window.badges(at: 2) == ""
            }
            try app.clickInImportWindow("import.import")
            try app.wait("the import", timeout: 120) { _ in ImportWindowController.current?.isFinished == true }
            let result = try app.inImportWindow { $0.result.map { "\($0.verified) \($0.safeToErase)" } }
            try app.expect(result == "3 true", "Imported: \(result ?? "nothing")")

            let folder = scratch.destination.appending(path: "Imported", directoryHint: .isDirectory)
            for root in [folder, scratch.backup.appending(path: "Imported", directoryHint: .isDirectory)] {
                let found = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                try app.expect(Set(scratch.names).isSubset(of: found), "\(root.path) holds \(found.sorted())")
            }
            let rated = try app.inImportWindow { $0.ratedNames(rating: 3) }
            try app.expect(rated.count == 2, "\(rated.count) photos rated in the window")
            let sidecars = SidecarStore(locator: .besidePhotos)
            for name in rated {
                let metadata = sidecars.load(for: folder.appending(path: name))?.metadata
                try app.expect(
                    metadata?.rating == 3 && metadata?.flag == .pick && metadata?.label == .red,
                    "\(name)'s sidecar at the destination holds \(String(describing: metadata))",
                )
            }
            for name in scratch.names {
                let metadata = sidecars.load(for: folder.appending(path: name))?.metadata
                try app.expect(
                    metadata?.caption == "E2E imported" && metadata?.copyright == "© E2E",
                    "\(name)'s sidecar holds the preset's fields: \(String(describing: metadata))",
                )
            }
            try app.chooseInImportWindow("None", inPopUp: "import.preset")
            try app.wait("Library showing the photos imported, selected", timeout: 30) { model in
                model.folder?.standardizedFileURL.path == folder.standardizedFileURL.path
                    && model.selectedPhotos.count == 3 && model.module == .library
            }
            app.covered(.feature("library.import"), via: .menu)
        }

        static let performance = Scenario(
            "import.performance",
            "A folder of 2,000 copies of raws: its first previews on screen, and the import grid scrolled while "
                + "it's browsed and while it copies",
            tiers: [.performance], claims: [],
        ) { app in
            try app.openWorking()
            let scratch = try ImportScratch(app, photos: 2000)
            defer { scratch.remove(app) }
            try app.main { _ in ImportWindowController.ignoresVolumes = true }
            try app.choose(.importPhotos)
            try app.waitForImportWindow()
            try app.inImportWindow { window in
                window.prepare(
                    destination: scratch.destination,
                    backup: scratch.backup,
                    folders: "Imported",
                    names: "{name}",
                )
            }
            let started = Date()
            app.post { _ in Task { try? await ImportWindowController.current?.add(folder: scratch.card) } }
            try app
                .wait("the first preview", timeout: 30) { _ in (ImportWindowController.current?.imagesShown ?? 0) > 0 }
            let first = Date().timeIntervalSince(started) * 1000
            let visible = try app.inImportWindow { $0.visibleCount }
            try app.wait("the first screenful", timeout: 30) { _ in
                (ImportWindowController.current?.imagesShown ?? 0) >= visible
            }
            let screen = Date().timeIntervalSince(started) * 1000
            app.record("e2e-import-first-preview", first)
            app.record("e2e-import-first-screen", screen)

            let browsing = try app.scrollImportGrid()
            try app.wait("the folder browsed", timeout: 600) { _ in ImportWindowController.current?.isBrowsed == true }
            let browsed = try app.scrollImportGrid()
            try app.clickInImportWindow("import.import")
            try app.wait("the copying", timeout: 120) { _ in ImportWindowController.current?.isCopying == true }
            let copying = try app.scrollImportGrid()
            try app.clickInImportWindow("import.cancel")
            try app.wait("the import to stop", timeout: 300) { _ in ImportWindowController.current?.isFinished == true }
            for (metric, summary) in [
                ("e2e-import-scroll-browsing-p99", browsing), ("e2e-import-scroll-p99", browsed),
                ("e2e-import-scroll-copying-p99", copying),
            ] {
                if let summary {
                    app.record(metric, summary.p99)
                }
            }
            let line = String(
                format: "import: first preview %.0f ms, first screen (%d cells) %.0f ms; scrolling p99 %.2f ms "
                    + "browsing, %.2f ms browsed, %.2f ms copying\n",
                first, visible, screen, browsing?.p99 ?? -1, browsed?.p99 ?? -1, copying?.p99 ?? -1,
            )
            try? line.write(
                to: app.runDirectory.appending(path: "import-performance.txt"), atomically: true, encoding: .utf8,
            )
        }
    }

    /// A folder of copies of the run's raws to import from, and a destination and a backup, below the
    /// run's folder; each copy ends in a box of its own length, so each has a content key of its own.
    struct ImportScratch: Sendable {
        let root: URL
        let card: URL
        let destination: URL
        let backup: URL
        let names: [String]

        init(_ app: RunningApp, photos count: Int) throws {
            root = app.runDirectory.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
            card = root.appending(path: "Card", directoryHint: .isDirectory)
            destination = root.appending(path: "Pictures", directoryHint: .isDirectory)
            backup = root.appending(path: "Backup", directoryHint: .isDirectory)
            let raws = ["arw", "raf", "cr3", "nef", "dng"]
            let originals = try FileManager.default.contentsOfDirectory(atPath: app.photos.path)
                .filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            guard !originals.isEmpty else { throw ScenarioFailure("The run has no raws to copy") }
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
            var names: [String] = []
            for number in 0 ..< count {
                let original = originals[number % originals.count]
                let name = String(format: "IMG_%04d.", number) + (original as NSString).pathExtension
                let copy = card.appending(path: name)
                try FileManager.default.copyItem(at: app.photos.appending(path: original), to: copy)
                let handle = try FileHandle(forWritingTo: copy)
                try handle.seekToEnd()
                let length = 16 + number
                var box = Data([
                    UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF),
                    UInt8(length & 0xFF),
                ])
                box.append(contentsOf: Array("free".utf8))
                box.append(Data(count: length - 8))
                try handle.write(contentsOf: box)
                try handle.close()
                names.append(name)
            }
            self.names = names
        }

        /// Stops and closes the window, takes what the import added out of Folders, and the folder away.
        func remove(_ app: RunningApp) {
            try? app.main { _ in
                ImportWindowController.current?.stop()
                ImportWindowController.current?.close()
                ImportWindowController.ignoresVolumes = false
            }
            app.leaveScratch(root)
        }
    }

    /// A card of the run's own to import from, its photos in `DCIM/100CANON`: three copies of each of four raws, each
    /// copy ending in a box of its own length so each has a content key of its own, and their files' dates the time
    /// they were copied; and a destination and a backup beside it.
    struct ImportCardScratch: Sendable {
        let root: URL
        let destination: URL
        let backup: URL
        /// Each copy's name, and the raw it's a copy of.
        let originals: [String: String]

        var count: Int {
            originals.count
        }

        init(_ app: RunningApp) throws {
            let base = app.runDirectory.appending(path: "card-\(UUID().uuidString)", directoryHint: .isDirectory)
            root = base.appending(path: "EOS_DIGITAL", directoryHint: .isDirectory)
            destination = base.appending(path: "Pictures", directoryHint: .isDirectory)
            backup = base.appending(path: "Backup", directoryHint: .isDirectory)
            let photos = root.appending(path: "DCIM/100CANON", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            let raws = ["arw", "raf", "cr3", "nef"]
            let found = try FileManager.default.contentsOfDirectory(atPath: app.photos.path)
                .filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            var originals: [String: String] = [:]
            for original in found {
                for _ in 0 ..< 3 {
                    let number = originals.count
                    let name = String(format: "IMG_%04d.", number + 1) + (original as NSString).pathExtension
                    let copy = photos.appending(path: name)
                    try FileManager.default.copyItem(at: app.photos.appending(path: original), to: copy)
                    let handle = try FileHandle(forWritingTo: copy)
                    try handle.seekToEnd()
                    let length = 16 + number
                    var box = Data([
                        UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF),
                        UInt8(length & 0xFF),
                    ])
                    box.append(contentsOf: Array("free".utf8))
                    box.append(Data(count: length - 8))
                    try handle.write(contentsOf: box)
                    try handle.close()
                    originals[name] = original
                }
            }
            self.originals = originals
        }

        /// Stops and closes the window, takes what the import added out of Folders, and the card away.
        func remove(_ app: RunningApp) {
            try? app.main { _ in
                ImportWindowController.current?.stop()
                ImportWindowController.current?.close()
                ImportWindowController.ignoresVolumes = false
            }
            app.leaveScratch(root.deletingLastPathComponent())
        }
    }

    extension RunningApp {
        /// Takes the folders below `scratch` out of Folders and shows the run's photos again, then removes `scratch`:
        /// an import adds the folder its photos went to, and the app left on a folder that's gone finds no photos.
        func leaveScratch(_ scratch: URL) {
            let below = scratch.standardizedFileURL.path + "/"
            try? main { model in
                for root in model.library.roots where root.url.standardizedFileURL.path.hasPrefix(below) {
                    model.library.remove(root)
                }
            }
            try? showRunPhotos()
            try? FileManager.default.removeItem(at: scratch)
            try? openWorking()
        }

        func waitForImportWindow() throws {
            try wait("the import window", timeout: 30) { _ in
                ImportWindowController.current?.window?.isVisible == true
            }
        }

        /// Runs `body` on the main thread with the import window open now.
        @discardableResult
        func inImportWindow<T: Sendable>(_ body: @escaping @MainActor (ImportWindowController) throws -> T) throws
            -> T {
            try main { _ in
                guard let window = ImportWindowController.current else {
                    throw ScenarioFailure("The import window isn't open")
                }
                return try body(window)
            }
        }

        /// Types `combo` in the import window: through the app's event dispatch when the run lets it take
        /// focus, so the editor's key monitor has to leave the window its keys; else straight to the window.
        func pressInImportWindow(_ combo: KeyCombo) throws {
            let focused = try focus()
            try main { _ in
                guard let window = ImportWindowController.current?.window else { return }
                window.makeKeyAndOrderFront(nil)
                let event = try Keyboard.event(combo)
                guard let routed = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                    windowNumber: window.windowNumber, context: nil, characters: event.characters ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: false,
                    keyCode: event.keyCode,
                ) else { return }
                if focused {
                    NSApp.sendEvent(routed)
                } else {
                    window.sendEvent(routed)
                }
            }
            pause(0.05)
        }

        /// Chooses `title` in the import window's pop-up button `identifier`, as a click in its menu does: the item
        /// selected, and the button's action sent.
        func chooseInImportWindow(_ title: String, inPopUp identifier: String) throws {
            try inImportWindow { window in
                guard let content = window.window?.contentView,
                      let button = Self.view(identifier, in: content) as? NSPopUpButton
                else { throw ScenarioFailure("\(identifier) isn't in the import window") }
                guard let index = button.itemArray.firstIndex(where: { $0.title == title }) else {
                    throw ScenarioFailure("\(identifier) has no \(title): \(button.itemTitles)")
                }
                button.selectItem(at: index)
                button.sendAction(button.action, to: button.target)
            }
            pause(0.1)
        }

        /// Clicks the control carrying `identifier` in the import window through the window, as the mouse does, once
        /// it's shown and enabled: the window's controls follow its model a moment later, so a small folder browsed
        /// within the window's first batch of events is browsed in the model while Import is still disabled, and a
        /// click then does nothing.
        func clickInImportWindow(_ identifier: String) throws {
            try inImportWindow { window in
                guard let content = window.window?.contentView, Self.view(identifier, in: content) != nil else {
                    throw ScenarioFailure("\(identifier) isn't in the import window")
                }
            }
            try waitInImportWindow("\(identifier) shown and enabled") { _ in
                guard let content = ImportWindowController.current?.window?.contentView,
                      let control = Self.view(identifier, in: content)
                else { return false }
                return !control.isHiddenOrHasHiddenAncestor && (control as? NSControl)?.isEnabled != false
            }
            post { _ in
                guard let window = ImportWindowController.current?.window, let content = window.contentView,
                      let control = Self.view(identifier, in: content)
                else { return }
                window.makeKeyAndOrderFront(nil)
                let frame = control.convert(control.bounds, to: nil)
                let location = NSPoint(x: frame.midX, y: frame.midY)
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    )
                }
                guard events.count == 2 else { return }
                Self.lastImportClick = ImportClick(
                    identifier: identifier,
                    found: content.superview?.hitTest(location).map(Views.describe) ?? "nothing",
                    isEnabled: (control as? NSControl)?.isEnabled != false, isKey: window.isKeyWindow, time: Date(),
                )
                // The button tracks the press, and takes the release from the queue as the mouse's.
                NSApp.postEvent(events[1], atStart: false)
                window.sendEvent(events[0])
            }
            pause(0.2)
        }

        /// Clicks the cell of the photo at `place` in the import grid, holding `modifiers`, as the mouse does, the cell
        /// scrolled into view first.
        func clickInImportGrid(photo place: Int, modifiers: NSEvent.ModifierFlags = []) throws {
            try clickInImportGrid("the photo at \(place)", modifiers: modifiers) { $0.pointOfPhoto(at: place) }
        }

        /// Clicks group `group`'s header in the import grid, holding `modifiers`, as the mouse does.
        func clickInImportGrid(group: Int, modifiers: NSEvent.ModifierFlags = []) throws {
            try clickInImportGrid("group \(group)'s header", modifiers: modifiers) { $0.pointOfGroup(group) }
        }

        /// A press and a release at the point `where` finds in the import window, through the app as the mouse's
        /// come, or to the view under it when the window isn't key and the view doesn't take a first click.
        private func clickInImportGrid(
            _ what: String, modifiers: NSEvent.ModifierFlags,
            at point: @escaping @MainActor (ImportWindowController) -> NSPoint?,
        ) throws {
            try inImportWindow { controller in
                guard let window = controller.window, let location = point(controller) else {
                    throw ScenarioFailure("\(what) isn't in the import grid")
                }
                window.makeKeyAndOrderFront(nil)
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    )
                }
                guard events.count == 2 else { throw ScenarioFailure("No mouse events for \(what)") }
                let hit = window.contentView?.superview?.hitTest(location)
                if window.isKeyWindow || hit?.acceptsFirstMouse(for: events[0]) == true {
                    for event in events {
                        NSApp.sendEvent(event)
                    }
                } else if let hit {
                    hit.mouseDown(with: events[0])
                    hit.mouseUp(with: events[1])
                }
            }
            pause(0.1)
        }

        /// Waits for the import grid's selection to be the photos at `places`; a failure says what it is, or what
        /// kept the wait from reading it.
        func expectImportSelection(_ places: [Int], _ what: String) throws {
            do {
                try wait("\(what) selects \(places)") { _ in ImportWindowController.current?.selectedPlaces == places }
            } catch {
                guard let selected = try? inImportWindow({ $0.selectedPlaces }) else { throw error }
                throw ScenarioFailure("\(what) selects \(selected), not \(places) (\(importWindowState()))")
            }
        }

        /// The last click `clickInImportWindow` sent: what the window's hit test found under it, and whether the
        /// control was enabled and the window key as it went.
        struct ImportClick {
            var identifier: String
            var found: String
            var isEnabled: Bool
            var isKey: Bool
            var time: Date
        }

        @MainActor private static var lastImportClick: ImportClick?

        /// The import window as it is now, and what the last click in it found, for a wait's failure.
        func importWindowState() -> String {
            let state = try? main { _ -> String in
                guard let window = ImportWindowController.current else { return "no import window" }
                var text = "the import window: \(window.state)"
                if let click = Self.lastImportClick {
                    text += String(
                        format: "; the click on %@ %.1f s ago found %@, %@, in %@", click.identifier,
                        Date().timeIntervalSince(click.time), click.found, click.isEnabled ? "enabled" : "disabled",
                        click.isKey ? "the key window" : "a window that wasn't key",
                    )
                }
                return text
            }
            return state ?? "the main thread didn't answer"
        }

        /// Waits as `wait` does, a timeout saying what the import window was doing and what the last click in it found.
        func waitInImportWindow(
            _ what: String, timeout: Double = 10, until condition: @escaping @MainActor (EditorModel) -> Bool,
        ) throws {
            try wait("\(what) (\(importWindowState()))", timeout: timeout, until: condition)
        }

        @MainActor private static func view(_ identifier: String, in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            return view.subviews.lazy.compactMap { Self.view(identifier, in: $0) }.first
        }

        /// Scrolls the import grid end to end in 4 s at 120 Hz, watching the main thread.
        func scrollImportGrid() throws -> MainThreadMonitor.Summary? {
            let monitor = try MainThread.run { () -> MainThreadMonitorBox in
                let monitor = MainThreadMonitor()
                monitor.start()
                return MainThreadMonitorBox(monitor)
            }
            let duration = 4.0
            let start = Date()
            while Date().timeIntervalSince(start) < duration {
                let fraction = Date().timeIntervalSince(start) / duration
                post { _ in ImportWindowController.current?.scroll(to: fraction) }
                pause(1.0 / 120)
            }
            return try MainThread.run { () -> MainThreadMonitor.Summary? in
                monitor.monitor.stop()
                return monitor.monitor.summary(seconds: duration)
            }
        }
    }
#endif
