#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// The import window (LIB-27), from copies of the run's raws in a folder of the run's own: never a
    /// card, and never this Mac's volumes, which the window is told to leave alone.
    enum ImportScenarios {
        static let all: [Scenario] = [fromFolder]

        static let fromFolder = Scenario(
            "import.from-folder",
            "Import Photos… copies a folder's photos, rated, flagged and labelled from the grid's keys, to a "
                + "destination and a backup, and Library shows them selected",
            claims: [.action(.importPhotos)],
        ) { app in
            try app.openWorking()
            let scratch = try ImportScratch(app, photos: 3)
            defer { scratch.remove(app) }
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
            try app.wait("Library showing the photos imported, selected", timeout: 30) { model in
                model.folder?.standardizedFileURL.path == folder.standardizedFileURL.path
                    && model.selectedPhotos.count == 3 && model.module == .library
            }
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

        /// Stops and closes the window, takes the destination out of Folders and the folder away.
        func remove(_ app: RunningApp) {
            let destination = destination
            try? app.main { model in
                ImportWindowController.current?.stop()
                ImportWindowController.current?.close()
                ImportWindowController.forget(destination, in: model)
                ImportWindowController.ignoresVolumes = false
            }
            try? FileManager.default.removeItem(at: root)
            try? app.openWorking()
        }
    }

    extension RunningApp {
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

        /// Clicks the control carrying `identifier` in the import window through the window, as the mouse does.
        func clickInImportWindow(_ identifier: String) throws {
            let location = try inImportWindow { window -> NSPoint in
                guard let content = window.window?.contentView, let control = Self.view(identifier, in: content) else {
                    throw ScenarioFailure("\(identifier) isn't in the import window")
                }
                window.window?.makeKeyAndOrderFront(nil)
                let frame = control.convert(control.bounds, to: nil)
                return NSPoint(x: frame.midX, y: frame.midY)
            }
            post { _ in
                guard let window = ImportWindowController.current?.window else { return }
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    )
                }
                guard events.count == 2 else { return }
                // The button tracks the press, and takes the release from the queue as the mouse's.
                NSApp.postEvent(events[1], atStart: false)
                window.sendEvent(events[0])
            }
            pause(0.2)
        }

        @MainActor private static func view(_ identifier: String, in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            return view.subviews.lazy.compactMap { Self.view(identifier, in: $0) }.first
        }
    }
#endif
