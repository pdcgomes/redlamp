#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import ImageIO
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampRecipes
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// The open photo's sidecar edit, as written on disk.
        func sidecarJSON(_ name: String) -> String {
            let url = photos.appending(path: "\(name).redlamp/edit.json")
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        /// Waits until the open photo's edits are on disk.
        func waitSaved(_ name: String, containing text: String, timeout: Double = 15) throws {
            try wait("\(name)'s sidecar to hold \(text)", timeout: timeout) { [self] model in
                model.saveNow()
                return sidecarJSON(name).contains(text)
            }
        }
    }

    /// A frame read on main between checks; only touched there.
    final class PlaceBox: @unchecked Sendable {
        var last: NSRect?
    }

    enum LibraryScenarios {
        static let all: [Scenario] = [subfolders, thumbnails, diskChanges, ratings, filmstripHiding]

        /// UX-19: the three controls are one preference; kept up, the filmstrip has room of its own.
        static let filmstripHiding = Scenario(
            "library.filmstrip-hide-automatically",
            "Hide Automatically from the View menu, the filmstrip's own menu and Settings, the photo fitted above it",
            claims: [.feature("library.filmstrip")],
        ) { app in
            let item = "Hide Automatically", toggle = "settings.filmstrip.hide-automatically"
            try app.openWorking()
            try app.waitForCanvas()
            let floating = try app.main { $0.canvas.stageInsets.bottom }
            try app.expect(try app.main { $0.filmstripHidesAutomatically }, "Hide Automatically isn't on at first")
            try app.expect(
                try app.main { _ in Menus.isChecked(item) } == true,
                "View › Filmstrip › \(item) isn't checked",
            )

            /// Kept up, with the photo fitted above it.
            @MainActor func kept(_ model: EditorModel) -> Bool {
                let canvas = model.canvas
                let stageBottom = canvas.viewSize.height - canvas.stageInsets.bottom
                return !model.filmstripHidesAutomatically && canvas.stageInsets.bottom > floating + 100
                    && canvas.imageRect(in: canvas.viewSize).maxY <= stageBottom + 0.5
            }
            /// Floating over the photo, which has the whole stage.
            @MainActor func floats(_ model: EditorModel) -> Bool {
                model.filmstripHidesAutomatically && model.canvas.stageInsets.bottom == floating
            }

            // The View menu: the filmstrip stays up without the pointer, and the photo is fitted above it.
            try app.choose(item)
            try app.wait("the filmstrip kept up, the photo fitted above it", until: kept)
            // It slides in: in place once its first photo stays put inside the window.
            let first = try app.photoNames()[0]
            let place = PlaceBox()
            try app.wait("the filmstrip on screen") { _ in
                guard let window = Views.editorWindow, let cell = Views.find("filmstrip.\(first)", in: window),
                      window.contentView?.bounds.contains(cell) == true
                else { return false }
                defer { place.last = cell }
                return place.last == cell
            }
            try app.wait("View › Filmstrip › \(item) unchecked") { _ in Menus.isChecked(item) == false }
            let key = "app.redlamp.filmstripHidesAutomatically"
            let saved = try app.main { _ in UserDefaults.standard.object(forKey: key) as? Bool }
            try app.expect(saved == false, "The preference saved is \(String(describing: saved))")
            app.covered(.feature("library.filmstrip"), via: .menu)

            // A photo keeps its menu; beside it, the filmstrip's own has the item, unchecked, and turns it on.
            let photoMenu = try app.rightClick(.filmstrip(first)).map(\.title)
            try app.expect(
                photoMenu.contains(ShortcutAction.copySettings.title) && !photoMenu.contains(item),
                "A photo's menu has \(photoMenu)",
            )
            let cell = try app.frame(of: .filmstrip(first))
            let beside = CGPoint(x: 1 + 3 / cell.width, y: 0.5)
            let stripMenu = try app.rightClick(.filmstrip(first), at: beside, choosing: item)
            try app.expect(
                stripMenu.map(\.title) == [item] && stripMenu.first?.on == false,
                "The filmstrip's menu has \(stripMenu)",
            )
            try app.wait("the filmstrip floating again, its room given back", until: floats)
            try app.wait("View › Filmstrip › \(item) checked") { _ in Menus.isChecked(item) == true }
            app.covered(.feature("library.filmstrip"), via: .mouse)

            // Settings › Appearance: its switch turns it off and on, and follows the View menu.
            let settings = try app.main { _ -> String in
                NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title.hasPrefix("Settings") }?.title ?? ""
            }
            try app.choose(settings)
            try app.wait("Settings › Appearance") { _ in Views.window(titled: "Appearance") != nil }
            try app.expect(try app.isOn(toggle, inWindowTitled: "Appearance"), "Settings' switch is off")
            try app.click(toggle, inWindowTitled: "Appearance")
            try app.wait("Settings' switch to keep the filmstrip up", until: kept)
            try app.wait("View › Filmstrip › \(item) unchecked") { _ in Menus.isChecked(item) == false }
            try app.choose(item)
            try app.wait("the View menu to let it hide", until: floats)
            try app.wait("Settings' switch to follow the View menu") { _ in
                Views.window(titled: "Appearance").flatMap { Views.accessible(toggle, in: $0) as? NSControl }?
                    .integerValue == 1
            }
            try app.click(toggle, inWindowTitled: "Appearance")
            try app.wait("Settings' switch to keep the filmstrip up again", until: kept)
            try app.main { _ in Views.window(titled: "Appearance")?.close() }
            app.covered(.feature("library.filmstrip"), via: .mouse)

            // Kept up, F6 hides the filmstrip and gives its room back, and presenting takes the whole window.
            try app.press(.toggleFilmstrip)
            try app.wait("F6 to hide it, the room given back") {
                !$0.filmstripVisible && $0.canvas.stageInsets.bottom == floating
            }
            try app.press(.toggleFilmstrip)
            try app.wait("F6 to bring it back, kept up", until: kept)
            try app.press(.fullScreenPreview)
            try app.wait("presenting on the whole window") { $0.isPresenting && $0.canvas.stageInsets == .zero }
            try app.press(.fullScreenPreview)
            try app.wait("presenting to put it back, kept up") { !$0.isPresenting && kept($0) }

            try app.choose(item)
            try app.wait("hiding automatically, as at first", until: floats)
        }

        static let subfolders = Scenario(
            "library.subfolders", "Show Photos in Subfolders from the View menu, and the Folders panel's counts",
            claims: [.feature("library.subfolders"), .feature("library.folders")],
        ) { app in
            try app.openWorking()
            let top = try app.main { $0.items.count }
            try app.choose("Show Photos in Subfolders")
            try app
                .wait("the subfolders' photos", timeout: 20) { $0.library.includesSubfolders && $0.items.count > top }
            try app.choose("Show Photos in Subfolders")
            try app
                .wait("only the folder's own photos", timeout: 20) {
                    !$0.library.includesSubfolders && $0.items.count == top
                }
            try app.expect(try app.exists(.identifier("sidebar.folders")), "The Folders panel isn't on screen")
            app.covered([.feature("library.subfolders"), .feature("library.folders")], via: .menu)
        }

        static let thumbnails = Scenario(
            "library.thumbnails", "Every photo's filmstrip thumbnail decodes, in a second or two each",
            claims: [.feature("library.thumbnails"), .feature("performance.slow-library")],
        ) { app in
            try app.openWorking()
            // The fixture photos, not exports another scenario may have left.
            let items = try app.main { model in
                model.items.filter { !$0.url.lastPathComponent.contains("-redlamp")
                    && FileManager.default.fileExists(atPath: $0.url.path)
                }
            }
            for item in items {
                let decoded = Flag()
                let started = Date()
                try app.run("\(item.url.lastPathComponent)'s thumbnail", timeout: 30) { model in
                    if await model.thumbnailLoader.image(for: item) != nil {
                        decoded.set()
                    }
                }
                try app.expect(decoded.isSet, "\(item.url.lastPathComponent) has no thumbnail")
                let seconds = Date().timeIntervalSince(started)
                try app.expect(seconds < 10, "\(item.url.lastPathComponent)'s thumbnail took \(seconds) s")
            }
            app.covered([.feature("library.thumbnails"), .feature("performance.slow-library")], via: .model)
        }

        static let diskChanges = Scenario(
            "library.disk-changes", "Photos copied in, renamed and deleted on disk follow in the filmstrip",
            claims: [.feature("library.disk-changes")],
        ) { app in
            try app.openWorking()
            let source = try app.photos.appending(path: app.workingPhoto())
            let copied = app.photos.appending(path: "Copied In.ARW")
            let renamed = app.photos.appending(path: "Renamed.ARW")
            try? FileManager.default.removeItem(at: copied)
            try? FileManager.default.removeItem(at: renamed)
            try FileManager.default.copyItem(at: source, to: copied)
            try app
                .wait("the copied photo", timeout: 20) {
                    $0.items.contains { $0.url.lastPathComponent == "Copied In.ARW" }
                }
            try FileManager.default.moveItem(at: copied, to: renamed)
            try app.wait("the renamed photo", timeout: 20) { model in
                model.items.contains { $0.url.lastPathComponent == "Renamed.ARW" }
                    && !model.items.contains { $0.url.lastPathComponent == "Copied In.ARW" }
            }
            try FileManager.default.removeItem(at: renamed)
            try app.wait("the deleted photo to leave", timeout: 20) { model in
                !model.items.contains { $0.url.lastPathComponent == "Renamed.ARW" }
            }
            app.covered(.feature("library.disk-changes"), via: .model)
        }

        static let ratings = Scenario(
            "library.ratings", "A rating, a flag and a label by their keys, kept in the sidecar",
            claims: [.feature("library.ratings")],
        ) { app in
            try app.openRaw(3)
            let name = try app.main { $0.selection?.lastPathComponent ?? "" }
            try app.press(.rating4)
            try app.press(.flagPick)
            try app.press(.labelGreen)
            try app.wait("the rating, flag and label") { model in
                model.photoMetadata.rating == 4 && model.photoMetadata.flag == .pick && model.photoMetadata
                    .label == .green
            }
            try app.waitSaved(name, containing: "rating")
            try app.press(.rating0)
            try app.press(.unflag)
            try app.press(.labelGreen)
            app.covered(.feature("library.ratings"), via: .key)
        }
    }

    enum SavingScenarios {
        static let all: [Scenario] = [failedSave, readOnly, startOver]

        static let failedSave = Scenario(
            "saving.failed-save", "A save the disk refuses is shown, retried, and lands once the disk allows it",
            claims: [.feature("saving.not-saved")],
        ) { app in
            let folder = app.photos.appending(path: "Locked")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let photo = folder.appending(path: "Locked.ARW")
            if !FileManager.default.fileExists(atPath: photo.path) {
                try FileManager.default.copyItem(at: app.photos.appending(path: app.workingPhoto()), to: photo)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            try app.main { $0.open([photo]) }
            try app.wait("the locked photo", timeout: 30) { $0.selection == photo && $0.info != nil }
            try app.settle()
            try app.set(.exposure, 0.3)
            try app.wait("the failed save to show", timeout: 20) { model in
                model.saveNow()
                return model.saveError != nil
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try app.main { $0.retrySave() }
            try app.wait("the save to land", timeout: 20) { model in
                model.saveError == nil
                    && FileManager.default.fileExists(atPath: photo.path + ".redlamp/edit.json")
            }
            try app.main { $0.open([app.photos]) }
            try app.wait("the photos folder again", timeout: 30) { $0.folder == app.photos }
            try app.openWorking()
            app.covered(.feature("saving.not-saved"), via: .model)
        }

        static let readOnly = Scenario(
            "saving.read-only", "A sidecar from a newer Redlamp opens read-only and is never overwritten",
            claims: [.feature("saving.read-only")],
        ) { app in
            let name = "Bitmap.png"
            let package = app.photos.appending(path: "\(name).redlamp")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let newer = #"{"format": 999, "recipe": {"processVersion": 999}}"#
            try newer.write(to: package.appending(path: "edit.json"), atomically: true, encoding: .utf8)
            try app.open(name)
            try app.wait("read-only", timeout: 20) { $0.isReadOnly }
            try app.main { $0.setSliderValue(.exposure, 0.5) }
            app.pause(1)
            try app.main { $0.saveNow() }
            app.pause(2)
            let after = (try? String(contentsOf: package.appending(path: "edit.json"), encoding: .utf8)) ?? ""
            try app.expect(after == newer, "The newer sidecar was rewritten")
            try FileManager.default.removeItem(at: package)
            try app.openWorking()
            app.covered(.feature("saving.read-only"), via: .model)
        }

        static let startOver = Scenario(
            "saving.start-over", "A damaged edit opens read-only, and Start Over keeps it aside for a new edit",
            claims: [.feature("saving.read-only")],
        ) { app in
            let name = "Bitmap.png"
            let package = app.photos.appending(path: "\(name).redlamp")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: package) }
            let damaged = #"{"format": "app.redlamp.edit", "recipe": {"version": 3, "#
            try damaged.write(to: package.appending(path: "edit.json"), atomically: true, encoding: .utf8)
            try app.open(name)
            try app.wait("the damaged edit", timeout: 20) { $0.canStartOver }
            try app.main { $0.startOver() }
            try app.wait("a new edit", timeout: 20) { !$0.isReadOnly }
            try app.set(.exposure, 0.3)
            try app.wait("the new edit saved", timeout: 20) { model in
                model.saveNow()
                return FileManager.default.fileExists(atPath: package.appending(path: "edit.json").path)
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: package.path)
            let copies = names.filter { $0.hasPrefix("edit.damaged-") }
            let kept = try copies.first.map { try String(contentsOf: package.appending(path: $0), encoding: .utf8) }
            try app.expect(copies.count == 1 && kept == damaged, "The damaged edit wasn't kept: \(names)")
            try app.openWorking()
            app.covered(.feature("saving.read-only"), via: .model)
        }
    }

    enum SyncScenarios {
        static let all: [Scenario] = [copyPaste, syncAndAuto]

        static let copyPaste = Scenario(
            "sync.copy-paste", "Copy Settings through its checklist, then Paste onto another photo",
            claims: [.feature("sync.copy"), .feature("sync.paste")],
        ) { app in
            try app.openRaw(0)
            try app.set(.exposure, 0.42)
            try app.choose(.copySettings)
            try app.wait("the Copy Settings checklist") { $0.settingsChooser != nil }
            try app.pressInSheet(KeyCombo(.character("\r")))
            try app.wait("the copied settings") { $0.hasClipboard && $0.settingsChooser == nil }
            try app.openRaw(1)
            try app.choose(.pasteSettings)
            try app.wait("the pasted Exposure") { abs($0.value(.exposure) - 0.42) < 1e-6 }
            try app.choose(.resetAll)
            try app.openRaw(0)
            try app.choose(.resetAll)
            app.covered([.feature("sync.copy"), .feature("sync.paste")], via: .menu)
        }

        static let syncAndAuto = Scenario(
            "sync.sync-and-auto", "Sync Settings onto a selection, Undo Sync, and Auto Sync",
            claims: [.feature("sync.sync"), .feature("sync.auto-sync")],
        ) { app in
            try app.openRaw(0)
            let other = try app.photoNames().filter { $0.hasSuffix(".NEF") || $0.hasSuffix(
                ".CR3",
            ) }.first ?? "DSC_0750.NEF"
            try app.set(.vibrance, 17)
            try app.choose(.selectAllPhotos)
            try app.wait("every photo selected") { $0.selectedPhotos.count == $0.items.count }
            try app.choose(.syncSettingsAgain)
            try app.wait("the sync", timeout: 180) { $0.settingsSync.progress == nil && $0.settingsSync.canUndo }
            try app.expect(app.sidecarJSON(other).contains("vibrance"), "\(other) didn't get the synced Vibrance")
            try app.choose(.undoSync)
            try app.wait("Undo Sync", timeout: 180) { $0.settingsSync.progress == nil && !$0.settingsSync.canUndo }
            try app.choose(.toggleAutoSync)
            try app.wait("Auto Sync on") { $0.settingsSync.isAutoSyncing }
            try app.set(.contrast, 12)
            try app.wait("Auto Sync to reach \(other)", timeout: 180) { model in
                model.settingsSync.progress == nil && app.sidecarJSON(other).contains("contrast")
            }
            try app.choose(.toggleAutoSync)
            try app.choose(.deselectOtherPhotos)
            try app.choose(.resetAll)
            app.covered([.feature("sync.sync"), .feature("sync.auto-sync")], via: .menu)
        }
    }

    enum ExportScenarios {
        static let all: [Scenario] = [formats, sizes, metadata, previous, shortWindow]

        /// #290: on the editor window at its smallest, the dialog was taller than the window and
        /// its settings didn't scroll, so the last ones were out of reach.
        static let shortWindow = Scenario(
            "export.short-window",
            "On the smallest editor window, the Export dialog fits and Tab reaches its last setting",
            claims: [.feature("export.dialog")],
        ) { app in
            try app.openWorking()
            let frame = try app.main { _ -> NSRect? in
                guard let window = Views.editorWindow else { return nil }
                defer { window.setContentSize(window.contentMinSize) }
                return window.frame
            }
            defer {
                if let frame {
                    try? app.main { _ in Views.editorWindow?.setFrame(frame, display: true) }
                }
            }
            app.pause(0.5)
            try app.choose(Menus.title(of: .export))
            try app.waitForSheet("the Export dialog")
            app.pause(0.5)
            let fits = try app.main { _ -> Bool in
                guard let window = Views.editorWindow, let sheet = window.attachedSheet else { return false }
                return window.frame.contains(sheet.frame)
            }
            try app.expect(fits, "The Export dialog hangs past the bottom of the editor window")

            /// Resolution, the lowest field: Tab ends on it whichever controls the Mac's Keyboard
            /// Navigation setting lets it stop on, and the settings scroll to show it.
            @MainActor func lowestField() -> (NSTextField, NSScrollView, NSWindow)? {
                guard let sheet = Views.editorWindow?.attachedSheet, let root = sheet.contentView,
                      let scroll = root.hitTest(NSPoint(x: root.bounds.midX, y: root.bounds.midY))?
                      .enclosingScrollView,
                      let document = scroll.documentView,
                      let lowest = fields(in: document).max(by: {
                          $0.convert($0.bounds, to: document).maxY < $1.convert($1.bounds, to: document).maxY
                      })
                else { return nil }
                return (lowest, scroll, sheet)
            }
            var focused = false
            for _ in 0 ..< 30 where !focused {
                try app.main { _ in try Views.editorWindow?.attachedSheet?.sendEvent(Keyboard.event(KeyCombo(.tab))) }
                app.pause(0.1)
                focused = try app.main { _ in
                    lowestField().map { field, _, sheet in (sheet.firstResponder as? NSTextView)?.delegate === field }
                        ?? false
                }
            }
            try app.expect(focused, "Tab didn't reach the Export dialog's last field")
            app.pause(0.5)
            let shown = try app.main { _ -> Bool in
                guard let (field, scroll, _) = lowestField(), let document = scroll.documentView else { return false }
                return scroll.contentView.documentVisibleRect.contains(field.convert(field.bounds, to: document))
            }
            try app.expect(shown, "The Export dialog didn't scroll its last field into view")
            try app.expect(try app.pressInSheet(KeyCombo(.escape)), "The Export dialog didn't close on Escape")
            app.covered(.feature("export.dialog"), via: .key)
        }

        @MainActor private static func fields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + view.subviews.flatMap(fields)
        }

        static let formats = Scenario(
            "export.formats", "Every format, bit depth and colour space writes the file it says",
            claims: [.feature("export.formats")],
        ) { app in
            try app.openWorking()
            for format in ExportFormat.allCases {
                for depth in format.bitDepths {
                    for space in OutputColorSpace.allCases {
                        var settings = ExportSettings()
                        settings.setFormat(format)
                        settings.bitDepth = depth
                        settings.colorSpace = space
                        settings.sizing = ExportSizing(mode: .longEdge)
                        settings.sizing.longEdge = 800
                        let url = try app.export(settings, as: "\(format.rawValue)-\(depth)-\(space)")
                        guard let file = app.imageProperties(url)
                        else { throw ScenarioFailure("\(url.lastPathComponent) doesn't decode") }
                        try app.expect(file.type == format.typeIdentifier, "\(url.lastPathComponent) is \(file.type)")
                        try app.expect(
                            max(file.width, file.height) == 800,
                            "\(url.lastPathComponent) is \(file.width)×\(file.height)",
                        )
                        if depth > 8, format != .heic, format != .avif {
                            try app.expect(file.depth >= 16, "\(url.lastPathComponent) has \(file.depth) bits")
                        }
                        try app.expect(
                            file.space.localizedCaseInsensitiveContains(space == .sRGB ? "sRGB" : "P3"),
                            "\(url.lastPathComponent) is in \(file.space)",
                        )
                    }
                }
            }
            app.covered(.feature("export.formats"), via: .model)
        }

        static let sizes = Scenario(
            "export.size", "Every way of sizing an export gives the size it says",
            claims: [.feature("export.size")],
        ) { app in
            try app.openWorking()
            let full = try app.main { $0.info?.pixelSize } ?? PixelSize(width: 1, height: 1)
            for mode in ExportSizing.Mode.allCases {
                var settings = ExportSettings()
                settings.sizing = ExportSizing(mode: mode)
                settings.sizing.longEdge = 1200
                settings.sizing.shortEdge = 600
                settings.sizing.width = 900
                settings.sizing.height = 900
                settings.sizing.megapixels = 2
                settings.sizing.percentage = 25
                let url = try app.export(settings, as: "size-\(mode.rawValue)")
                guard let file = app.imageProperties(url) else { throw ScenarioFailure("\(mode) doesn't decode") }
                let long = max(file.width, file.height), short = min(file.width, file.height)
                let fullLong = max(full.width, full.height)
                switch mode {
                case .full: try app.expect(long == fullLong, "Full size is \(long), not \(fullLong)")
                case .longEdge: try app.expect(long == 1200, "Long edge is \(long)")
                case .shortEdge: try app.expect(short == 600, "Short edge is \(short)")
                case .dimensions: try app.expect(long <= 900, "Width & Height gave \(file.width)×\(file.height)")
                case .megapixels: try app.expect(
                        abs(Double(file.width * file.height) / 2_000_000 - 1) < 0.05,
                        "2 MP gave \(file.width)×\(file.height)",
                    )
                case .percentage: try app.expect(abs(Double(long) / Double(fullLong) - 0.25) < 0.01, "25% gave \(long)")
                }
            }
            app.covered(.feature("export.size"), via: .model)
        }

        static let metadata = Scenario(
            "export.metadata", "Metadata policies: all with the edit embedded, all but the location, none",
            claims: [.feature("export.metadata")],
        ) { app in
            try app.openWorking()
            for policy in ExportMetadataPolicy.allCases {
                var settings = ExportSettings()
                settings.metadata = policy
                settings.sizing = ExportSizing(mode: .longEdge)
                settings.sizing.longEdge = 600
                let url = try app.export(settings, as: "metadata-\(policy.rawValue)")
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    throw ScenarioFailure("\(url.lastPathComponent) doesn't open")
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
                let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
                    .flatMap { CGImageMetadataCreateXMPData($0, nil) as Data? }
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                switch policy {
                case .all, .allExceptLocation:
                    try app.expect(properties[kCGImagePropertyExifDictionary] != nil, "\(policy) dropped the EXIF")
                    try app.expect(xmp.localizedCaseInsensitiveContains("redlamp"), "\(policy) has no embedded edit")
                    if policy == .allExceptLocation {
                        try app.expect(properties[kCGImagePropertyGPSDictionary] == nil, "\(policy) kept the location")
                    }
                case .none:
                    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                    try app.expect(
                        properties[kCGImagePropertyGPSDictionary] == nil && exif[
                            kCGImagePropertyExifDateTimeOriginal,
                        ] ==
                            nil,
                        "No metadata kept the capture date or the location",
                    )
                }
            }
            app.covered(.feature("export.metadata"), via: .model)
        }

        static let previous = Scenario(
            "export.presets-and-previous",
            "Export with Previous repeats the last export without the dialog; presets are listed",
            claims: [.feature("export.presets")],
        ) { app in
            try app.openWorking()
            if let host = app.host {
                let presets = try app.main { _ in host.exports.presets.count }
                try app.expect(presets >= ExportPreset.builtIns.count, "\(presets) presets listed")
            }
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: app.photos.path)) ?? [])
            try app.choose(Menus.title(of: .exportWithPrevious))
            app.pause(0.5)
            if try app.sheetIsUp() {
                // No previous export yet: the dialog opens, and exporting from it makes one.
                try app.pressInSheet(KeyCombo(.character("\r")))
            }
            @Sendable func newFiles() -> Set<String> {
                Set((try? FileManager.default.contentsOfDirectory(atPath: app.photos.path)) ?? []).subtracting(before)
                    .filter { !$0.hasSuffix(".redlamp") && !$0.hasPrefix(".") }
            }
            try app.wait("the export", timeout: 60) { model in !newFiles().isEmpty && model.exportStatus == nil }
            for file in newFiles() {
                try? FileManager.default.removeItem(at: app.photos.appending(path: file))
            }
            app.covered(.feature("export.presets"), via: .menu)
        }
    }

    enum RecipeScenarios {
        static let all: [Scenario] = [apply, createAndImport, favorites, filmLooks]

        static let apply = Scenario(
            "recipes.apply", "Bundled recipes preview, apply and take an Amount",
            claims: [.feature("recipes.applying"), .section(.recipes)],
        ) { app in
            try app.openWorking()
            let ids = try app.main { $0.recipes.all.prefix(6).map(\.id) }
            try app.expect(ids.count >= 6, "Only \(ids.count) recipes")
            for id in ids {
                try app.expectRenders("previewing \(id)") {
                    try app.main { model in model.recipes.recipe(id: id).map(model.previewRecipe) }
                }
                try app.main { $0.previewRecipe(nil) }
                try app.main { model in model.recipes.recipe(id: id).map { model.applyRecipe($0) } }
                try app.wait("\(id) applied") { $0.appliedRecipe?.id == id }
                try app.main { $0.setRecipeAmount(50) }
            }
            try app.choose(.resetAll)
            app.covered([.feature("recipes.applying"), .section(.recipes)], via: .model)
        }

        static let createAndImport = Scenario(
            "recipes.create-and-import", "Save the edit as a recipe, and import a .cube LUT",
            claims: [.feature("recipes.creating"), .feature("recipes.importing")],
        ) { app in
            try app.openWorking()
            try app.set(.vibrance, 25)
            let saved = try app.main { $0.saveRecipe(
                name: "Regression recipe",
                includes: Set(RecipeSettingGroup.allCases),
            ) }
            try app.expect(saved != nil, "Saving a recipe failed")
            let cube = app.runDirectory.appending(path: "Regression.cube")
            var lines = ["TITLE \"Regression\"", "LUT_3D_SIZE 2"]
            for b in 0 ... 1 {
                for g in 0 ... 1 {
                    for r in 0 ... 1 {
                        lines.append("\(Double(r) * 0.9) \(Double(g)) \(Double(b))")
                    }
                }
            }
            try lines.joined(separator: "\n").write(to: cube, atomically: true, encoding: .utf8)
            let before = try app.main { $0.recipes.all.count }
            try app.main { RecipeActions.importFiles([cube], model: $0) }
            try app.wait("the imported LUT", timeout: 20) { $0.recipes.all.count > before }
            if try app.sheetIsUp() {
                try app.pressInSheet(KeyCombo(.character("\r")))
            }
            try app.choose(.resetAll)
            app.covered([.feature("recipes.creating"), .feature("recipes.importing")], via: .model)
        }

        static let favorites = Scenario(
            "recipes.favorites-and-search", "Recipes are found by Lightroom's words, and favorites stick",
            claims: [.feature("recipes.favorites")],
        ) { app in
            try app.openWorking()
            for word in ["preset", "profile", "film", "black"] {
                let found = try app.main { $0.recipes.search(word).count }
                try app.expect(found > 0, "Searching \"\(word)\" finds nothing")
            }
            let id = try app.main { $0.recipes.all.first?.id }
            guard let id else { throw ScenarioFailure("No recipes") }
            try app.main { model in model.recipes.recipe(id: id).map { model.recipes.setFavorite($0, true) } }
            try app.wait("a favorite") { model in model.recipes.recipe(id: id).map(model.recipes.isFavorite) == true }
            try app.main { model in model.recipes.recipe(id: id).map { model.recipes.setFavorite($0, false) } }
            app.covered(.feature("recipes.favorites"), via: .model)
        }

        static let filmLooks = Scenario(
            "recipes.film-looks", "The Film Looks window opens from its menu item",
            claims: [.feature("recipes.film-looks")],
        ) { app in
            try app.openWorking()
            try app.choose(.filmLooks, expectPerformed: false)
            try app
                .wait("the Film Looks window", timeout: 10) { _ in
                    NSApp.windows.contains { $0.isVisible && $0.title == "Film Looks" }
                }
            try app.main { _ in NSApp.windows.first { $0.title == "Film Looks" }?.close() }
            app.covered(.feature("recipes.film-looks"), via: .menu)
        }
    }
#endif
