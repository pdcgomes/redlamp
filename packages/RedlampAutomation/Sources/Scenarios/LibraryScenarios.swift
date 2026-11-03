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

        /// UX-19 and UX-43: the four controls are one preference; kept up, the filmstrip has room of its own.
        static let filmstripHiding = Scenario(
            "library.filmstrip-hide-automatically",
            "Hide Automatically from the View menu, the filmstrip's own menu, its pin and Settings, the photo fitted "
                + "above it",
            claims: [.feature("library.filmstrip")],
            needsFocus: true,
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

            // A photo keeps its menu; beside it, the filmstrip's own has the item, unchecked, and turns it on, above
            // Show Info Line and the thumbnails' sizes (UX-42).
            try app.focus()
            let photoMenu = try app.rightClick(.filmstrip(first)).map(\.title)
            try app.expect(
                photoMenu.contains(ShortcutAction.copySettings.title) && !photoMenu.contains(item),
                "A photo's menu has \(photoMenu)",
            )
            let cell = try app.frame(of: .filmstrip(first))
            let beside = CGPoint(x: 1 + 3 / cell.width, y: 0.5)
            let stripMenu = try app.rightClick(.filmstrip(first), at: beside, choosing: item)
            try app.expect(
                stripMenu.map(\.title) == [item, "Show Info Line"] + FilmstripSize.allCases.map(\.title)
                    && stripMenu.first?.on == false,
                "The filmstrip's menu has \(stripMenu)",
            )
            try app.wait("the filmstrip floating again, its room given back", until: floats)
            try app.wait("View › Filmstrip › \(item) checked") { _ in Menus.isChecked(item) == true }
            app.covered(.feature("library.filmstrip"), via: .mouse)

            // The pin at the end of its line of text (UX-43), on the filmstrip brought up as the pointer at the
            // window's bottom edge brings it: pinned, it stays up once the pointer has gone, the photo fitted above
            // it, and unpinned it floats again.
            let pin = Target.identifier("filmstrip.pin")
            try app.main { $0.keepsFilmstripShown = true }
            defer { try? app.main { $0.keepsFilmstripShown = false } }
            let pinPlace = PlaceBox()
            try app.wait("the filmstrip up, its pin in place") { _ in
                guard let window = Views.editorWindow, let frame = Views.find("filmstrip.pin", in: window),
                      window.contentView?.bounds.contains(frame) == true
                else { return false }
                defer { pinPlace.last = frame }
                return pinPlace.last == frame
            }
            try app.tap(pin)
            try app.wait("the pin to keep the filmstrip up, the photo fitted above it", until: kept)
            try app.main { $0.keepsFilmstripShown = false }
            app.pause(0.5)
            try app.expect(try app.exists(pin), "The pinned filmstrip went away once the pointer had gone")
            try app.wait("View › Filmstrip › \(item) unchecked") { _ in Menus.isChecked(item) == false }
            let pinned = try app.main { _ in UserDefaults.standard.object(forKey: key) as? Bool }
            try app.expect(pinned == false, "The preference the pin saved is \(String(describing: pinned))")
            try app.tap(pin)
            try app.wait("the pin to let the filmstrip hide, its room given back", until: floats)
            try app.wait("View › Filmstrip › \(item) checked") { _ in Menus.isChecked(item) == true }
            app.covered(.feature("library.filmstrip"), via: .mouse)

            // Settings › Appearance: its switch turns it off and on, and follows the View menu.
            if !app.settingsControlsDrawnBySwiftUI {
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
            } else {
                // Kept up, as the switch leaves it, for what follows.
                try app.choose(item)
                try app.wait("the View menu to keep it up, as the switch would", until: kept)
            }

            // Kept up, F6 hides the filmstrip and gives its room back, and presenting takes the whole window.
            try app.press(.toggleFilmstrip)
            try app.wait("F6 to hide it, the room given back") {
                !$0.filmstripVisible && $0.canvas.stageInsets.bottom == floating
            }
            try app.press(.toggleFilmstrip)
            try app.wait("F6 to bring it back, kept up", until: kept)
            try app.pressFullScreenPreview()
            try app.wait("presenting on the whole window") { $0.isPresenting && $0.canvas.stageInsets == .zero }
            try app.pressFullScreenPreview()
            try app.wait("presenting to put it back, kept up") { !$0.isPresenting && kept($0) }

            try app.choose(item)
            try app.wait("hiding automatically, as at first", until: floats)
            if app.settingsControlsDrawnBySwiftUI {
                throw app.leftOutSettingsStep("Settings › Appearance's Hide automatically switch")
            }
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
            "saving.failed-save",
            "A save the disk refuses is shown over the photo and over the Library's photos, retried from the Library, "
                + "and lands once the disk allows it",
            claims: [.feature("saving.not-saved")],
            needsFocus: true,
        ) { app in
            /// Waits for the banner over the photo in Develop, or over the Library's photos, with its Retry.
            func waitForBanner(in module: AppModule) throws {
                let place = module == .library ? "over the Library's photos" : "over the photo"
                try app.wait("the failed save's banner \(place)", timeout: 10) { model in
                    guard model.module == module, model.saveError != nil, let window = Views.editorWindow else {
                        return false
                    }
                    return Views.find("saving.banner.retry", in: window) != nil
                }
            }
            let folder = app.photos.appending(path: "Locked")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let photo = folder.appending(path: "Locked.ARW")
            if !FileManager.default.fileExists(atPath: photo.path) {
                // A file of its own, which Library Health doesn't take for a copy of the run's photo to trash.
                let working = try Data(contentsOf: app.photos.appending(path: app.workingPhoto()))
                try (working + HealthScenarios.freeBox).write(to: photo)
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
            try waitForBanner(in: .develop)

            app.step("the banner over the Library's photos")
            try app.press(.gridView)
            try waitForBanner(in: .library)
            let focused = try app.focus()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            if focused {
                try app.tap(.identifier("saving.banner.retry"))
            } else {
                // What its button does: SwiftUI's buttons take no click while the app isn't active.
                try app.main { $0.retrySave() }
            }
            try app.wait("the save to land, and the banner to go", timeout: 20) { model in
                model.saveError == nil
                    && FileManager.default.fileExists(atPath: photo.path + ".redlamp/edit.json")
                    && Views.editorWindow.map { Views.find("saving.banner", in: $0) == nil } == true
            }
            app.covered(.feature("saving.not-saved"), via: focused ? .mouse : .model)
            try app.press(.developModule)
            try app.main { $0.open([app.photos]) }
            try app.wait("the photos folder again", timeout: 30) { $0.folder == app.photos }
            try app.openWorking()
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
        static let all: [Scenario] = [
            formats, sizes, metadata, previous, shortWindow, chooseFolder, clickAfterMenu, jpegXL, batch, fromLibrary,
            border,
        ]

        /// EDT-35 (#473): a Borders recipe on every photo exported, its long edge the file's; None
        /// leaves the photo's own border out.
        static let border = Scenario(
            "export.border",
            "Export with White 4:5 at a 1350 long edge writes 1080 × 1350; None leaves the photo's own border out",
            claims: [.feature("export.dialog")],
        ) { app in
            try app.openWorking()
            try app.choose(.resetAll)
            try app.main { $0.setBorderStyle(.film35) }
            guard let recipe = BuiltInRecipes.recipe(id: "redlamp/border/white-4x5") else {
                throw ScenarioFailure("No White 4:5 border recipe")
            }
            var settings = ExportSettings()
            settings.sizing = ExportSizing(mode: .longEdge)
            settings.sizing.longEdge = 1350
            settings.border = ExportBorder(recipeID: recipe.id, name: recipe.name, values: recipe.settings.values)
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "redlamp-export-border-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            func size(_ name: String, _ settings: ExportSettings) throws -> (Int, Int) {
                let url = folder.appending(path: name)
                try app.run("Export \(name)") { model in try? await model.export(settings, to: url) }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int
                else { throw ScenarioFailure("No file exported as \(name)") }
                return (width, height)
            }
            let bordered = try size("white.jpg", settings)
            try app.expect(bordered == (1080, 1350), "White 4:5 at 1350 wrote \(bordered.0) × \(bordered.1)")
            settings.border = .none
            let plain = try size("none.jpg", settings)
            let photo = try app.main { model in model.recipe.developedSize(imageSize: model.info?.pixelSize ?? .zero) }
            try app.expect(
                abs(Double(plain.0) / Double(plain.1) - photo.aspectRatio) < 0.01,
                "None kept a border: \(plain.0) × \(plain.1) for a \(photo.width) × \(photo.height) photo",
            )
            try app.choose(.resetAll)
            app.covered(.feature("export.dialog"), via: .model)
        }

        /// EDT-16 (#78): the photos selected with Select All Photos export at once from Export…, named by a template
        /// typed in the dialog, in the background, with the filmstrip saying how far it's got.
        static let batch = Scenario(
            "export.batch",
            "The photos selected with Select All Photos export at once from Export…, named by a typed template",
            claims: [.feature("export.batch"), .feature("export.dialog")],
        ) { app in
            try app.openWorking()
            try app.choose(Menus.title(of: .selectAllPhotos))
            try app.wait("several photos selected", timeout: 30) { $0.selectedCount > 1 && $0.info != nil }
            let count = try app.main { $0.selectedCount }
            let settings = try app.host.map { host in try app.main { _ in host.exports.initialSettings } }
                ?? ExportSettings()
            let folder = settings.destinationFolder ?? app.photos
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])

            try app.choose(Menus.title(of: .export))
            try app.waitForSheet("the Export dialog for \(count) photos")
            app.pause(0.5)
            try app.clickInSheet("export.naming")
            try app.selectSheetField()
            try app.typeInAttachedSheet("Batch {sequence:2} of {total}")
            app.pause(0.5)
            try app.expect(
                try app.pressInSheet(KeyCombo(.character("\r"))),
                "The Export dialog's Export button didn't take Return",
            )
            try app.waitForNoSheet("the Export dialog")
            let expected = (1 ... count).map {
                "Batch \(String(format: "%02d", $0)) of \(count).\(settings.format.fileExtension)"
            }
            @Sendable func written() -> Set<String> {
                Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).subtracting(before)
                    .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".redlamp") }
            }
            try app.wait("the \(count) exports", timeout: 300) { model in
                model.batchExport.progress == nil && written().count >= count
            }
            defer {
                for file in written() {
                    try? FileManager.default.removeItem(at: folder.appending(path: file))
                }
            }
            try app.expect(written() == Set(expected), "The batch wrote \(written().sorted()), not \(expected)")
            for file in expected {
                try app.expect(
                    app.imageProperties(folder.appending(path: file)) != nil, "\(file) doesn't decode",
                )
            }
            let summary = try app.main { $0.batchExport.summary }
            try app.expect(summary == "Exported \(count) photos", "The filmstrip says \(summary ?? "nothing")")
            app.covered([.feature("export.batch"), .feature("export.dialog")], via: .mouse)
        }

        /// #526: photos chosen in the Library's grid aren't open, since the Library lets go of the photo Develop had
        /// open once another is chosen, and the toolbar's Export and Export… still take them.
        static let fromLibrary = Scenario(
            "export.from-library",
            "Photos clicked and ⌘-clicked in the Library's grid, neither open, export from the toolbar's Export and "
                + "Export…",
            claims: [.feature("export.batch"), .feature("export.dialog")],
        ) { app in
            try app.showGrid()
            let open = try app.main { $0.info?.url.lastPathComponent }
            let names = try app.gridNames().filter { $0 != open }
            let chosen = [names[0], names[2]]
            try app.clickView("grid.\(chosen[0])")
            try app.clickView("grid.\(chosen[1])", modifiers: .command)
            try app.wait("\(chosen.joined(separator: " and ")) chosen, neither open") { model in
                model.selectedPhotos.map(\.lastPathComponent) == chosen && model.info == nil
            }
            try app.wait("the toolbar's Export to be available") { _ in
                Views.editorWindow?.toolbar?.items.first { $0.itemIdentifier.rawValue == "export" }?.isEnabled == true
            }
            let settings = try app.host.map { host in try app.main { _ in host.exports.initialSettings } }
                ?? ExportSettings()
            let folder = settings.destinationFolder ?? app.photos
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])

            try app.choose(Menus.title(of: .export))
            try app.waitForSheet("the Export dialog for the 2 photos")
            app.pause(0.5)
            try app.clickInSheet("export.naming")
            try app.selectSheetField()
            try app.typeInAttachedSheet("{name} from the Library")
            app.pause(0.5)
            try app.expect(
                try app.pressInSheet(KeyCombo(.character("\r"))),
                "The Export dialog's Export button didn't take Return",
            )
            try app.waitForNoSheet("the Export dialog")
            let expected = Set(chosen.map { name in
                "\((name as NSString).deletingPathExtension) from the Library.\(settings.format.fileExtension)"
            })
            @Sendable func written() -> Set<String> {
                Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).subtracting(before)
                    .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".redlamp") }
            }
            try app.wait("the 2 exports", timeout: 120) { model in
                model.batchExport.progress == nil && written().count >= chosen.count
            }
            let wrote = written()
            @Sendable func removeExports() {
                for file in wrote {
                    try? FileManager.default.removeItem(at: folder.appending(path: file))
                }
            }
            defer { removeExports() }
            try app.expect(wrote == expected, "The export wrote \(wrote.sorted()), not \(expected.sorted())")
            try app.expect(try app.main { $0.info == nil }, "Exporting opened a photo in Develop")
            // Listed before they're removed, so the grid follows their removal rather than listing them after it.
            try app.wait("the exports in the grid", timeout: 20) { model in
                wrote.allSatisfy { name in model.items.contains { $0.url.lastPathComponent == name } }
            }
            removeExports()
            try app.wait("the exports to leave the grid", timeout: 20) { model in
                !model.items.contains { wrote.contains($0.url.lastPathComponent) }
            }
            app.covered([.feature("export.batch"), .feature("export.dialog")], via: .mouse)
            try app.press(.developModule)
            try app.wait("Develop") { $0.module == .develop }
            try app.main { model in model.select(model.items[0].url) }
            try app.settle()
        }

        /// The scenarios that choose from the Export dialog's menus find each by the pop-up button showing it, which
        /// macOS 27's SwiftUI doesn't make: it draws the dialog's pickers itself.
        static func choosesFromMenus() throws {
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                throw ScenarioSkip(
                    knownIssue: "UX-44",
                    "on macOS 27, SwiftUI draws the Export dialog's menus itself, with no pop-up button to choose from",
                )
            }
        }

        /// EDT-30 (#373): JPEG XL is under both of the Format menu's sections, with Quality under
        /// Lossy and without it under Lossless, and each writes a JPEG XL file of its kind.
        static let jpegXL = Scenario(
            "export.jpeg-xl",
            "JPEG XL, chosen under Lossy or under Lossless in the Export dialog's Format menu, exports a JPEG XL file",
            claims: [.feature("export.formats"), .feature("export.dialog")],
        ) { app in
            try choosesFromMenus()
            try app.openWorking()
            for (section, format) in [("Lossy", ExportFormat.jxl), ("Lossless", .jxlLossless)] {
                let folder = try app.host.flatMap { host in
                    try app.main { _ in host.exports.initialSettings.destinationFolder }
                } ?? app.photos
                let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                try app.choose(Menus.title(of: .export))
                try app.waitForSheet("the Export dialog")
                app.pause(0.5)
                let shown = try app.main { _ in
                    ExportFormat.allCases.map(\.name).first { Views.popUpButton(showing: $0) != nil }
                }
                guard let shown else { throw ScenarioFailure("The Export dialog's Format menu shows no format") }
                let menu = try app.choose("JPEG XL", inSection: section, inPopUpButtonShowing: shown)
                try app.wait("the Format menu to close") { _ in menu.closed }
                try app.main { _ in menu.stop() }
                try app.wait("the Format menu to show JPEG XL") { _ in Views.popUpButton(showing: "JPEG XL") != nil }
                let quality = try app.main { _ in
                    Views.editorWindow?.attachedSheet?.contentView.map { !Views.all(NSSlider.self, in: $0).isEmpty }
                }
                try app.expect(
                    quality == !format.isLossless,
                    "JPEG XL under \(section) \(quality == true ? "shows" : "doesn't show") Quality",
                )
                try app.expect(
                    try app.pressInSheet(KeyCombo(.character("\r"))),
                    "The Export dialog's Export button didn't take Return",
                )
                @Sendable func newFile() -> String? {
                    let now = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                    return now.subtracting(before).first { !$0.hasPrefix(".") && !$0.hasSuffix(".redlamp") }
                }
                try app
                    .wait("the exported file", timeout: 60) { model in newFile() != nil && model.exportStatus == nil }
                guard let exported = newFile() else { return }
                let url = folder.appending(path: exported)
                let type = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(CGImageSourceGetType) as String?
                try app.expect(
                    type == format.typeIdentifier && url.pathExtension == format.fileExtension,
                    "Exporting JPEG XL under \(section) wrote \(exported), \(type ?? "unreadable")",
                )
                if let host = app.host {
                    let recorded = try app.main { _ in host.exports.previous?.format }
                    try app.expect(
                        recorded == format,
                        "JPEG XL under \(section) exported as \(recorded?.rawValue ?? "nothing")",
                    )
                }
                try? FileManager.default.removeItem(at: url)
            }
            app.covered([.feature("export.formats"), .feature("export.dialog")], via: .mouse)
        }

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

        /// #356: Choose… in Export to ran the folder panel modal from a run loop block, which holds back
        /// the blocks queued with it; on macOS 27 the panel's modal session ran with the panel never on
        /// screen, and the Export dialog took a click to get back.
        static let chooseFolder = Scenario(
            "export.choose-folder",
            "Choose… in Export to opens the folder panel once its menu has closed, and Cancel leaves the folder as it was",
            claims: [.feature("export.dialog")],
            needsFocus: true,
        ) { app in
            try app.openWorking()
            try app.focus()
            try app.choose(Menus.title(of: .export))
            try app.waitForSheet("the Export dialog")
            app.pause(0.5)
            let panel: @MainActor () -> NSOpenPanel? = {
                NSApp.windows.first { $0 is NSOpenPanel && $0.isVisible } as? NSOpenPanel
            }
            defer { try? app.main { _ in panel()?.cancel(nil) } }
            let original = "Same Folder as Original"
            // On macOS 27 SwiftUI draws the picker, with no pop-up button to read its value from (UX-44).
            let readable = try app.main { _ in Views.popUpButton(showing: original) != nil }
            let menu = try app.choose("Choose…", inPopUpButtonShowing: original, marked: "export.destination")
            defer { try? app.main { _ in menu.stop() } }
            // A launch's first panel waits to connect to AppKit's panel service.
            try app.wait("the folder panel on screen", timeout: 60) { _ in
                panel()?.occlusionState.contains(.visible) == true
            }
            try app.expect(
                try app.main { _ in menu.closed },
                "The folder panel came up while Export to's menu still tracked the mouse",
            )
            try app.main { _ in panel()?.cancel(nil) }
            try app.wait("the folder panel to close") { _ in panel() == nil }
            try app.wait("the Export dialog to have the keyboard again") { _ in
                Views.editorWindow?.attachedSheet?.isKeyWindow == true
            }
            try app.expect(
                try !readable || app.main { _ in Views.popUpButton(showing: original) != nil },
                "Cancel in the folder panel changed Export to",
            )
            try app.expect(try app.pressInSheet(KeyCombo(.escape)), "The Export dialog didn't close on Escape")
            app.covered(.feature("export.dialog"), via: .mouse)
        }

        /// #486: on macOS 27 the press that opens one of the dialog's menus begins SwiftUI's own gesture
        /// recognizers, and the menu took its release, so they held the press and took the dialog's next click
        /// as part of it: Cancel took two clicks.
        static let clickAfterMenu = Scenario(
            "export.click-after-menu",
            "After a choice from Export to, Format or Preset, one click on Cancel closes the Export dialog",
            claims: [.feature("export.dialog")],
            needsFocus: true,
        ) { app in
            try app.openWorking()
            guard try app.focus() else {
                throw ScenarioSkip("a click reaches the dialog as a person's does only with the app in front (--focus)")
            }
            let menus: [(menu: String, item: String, shown: String, marker: String)] = [
                ("Export to", "Same Folder as Original", "Same Folder as Original", "export.destination"),
                ("Format", "JPEG", "JPEG", "export.format"),
                ("Preset", "Web, 2048 px", ExportPreset.builtIns[0].name, "export.preset"),
            ]
            for (menu, item, shown, marker) in menus {
                try app.choose(Menus.title(of: .export))
                try app.waitForSheet("the Export dialog")
                app.pause(0.5)
                let opened = try app.choose(item, inPopUpButtonShowing: shown, marked: marker)
                try app.wait("the \(menu) menu to close") { _ in opened.closed }
                try app.main { _ in opened.stop() }
                app.pause(0.3)
                try click("export.cancel", inSheetOf: app)
                let closed = (try? app.waitForNoSheet("the Export dialog", timeout: 1.5)) != nil
                if !closed {
                    _ = try? app.pressInSheet(KeyCombo(.escape))
                }
                try app.expect(closed, "One click on Cancel didn't close the Export dialog after a choice from \(menu)")
            }
            app.covered(.feature("export.dialog"), via: .mouse)
        }

        /// Clicks the control `identifier` marks (`automationIdentifier`) in the sheet in front, its press and its
        /// release through the app's queue a moment apart, as the mouse's come.
        private static func click(_ identifier: String, inSheetOf app: RunningApp) throws {
            let location = try app.main { _ -> NSPoint in
                guard let sheet = Views.editorWindow?.attachedSheet, let marker = Views.shown(identifier, in: sheet)
                else { throw ScenarioFailure("\(identifier) isn't in the sheet") }
                let frame = marker.convert(marker.bounds, to: nil)
                return NSPoint(x: frame.midX, y: frame.midY)
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                try app.main { _ in
                    guard let sheet = Views.editorWindow?.attachedSheet,
                          let event = NSEvent.mouseEvent(
                              with: type, location: location, modifierFlags: [],
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                              context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                          )
                    else { return }
                    NSApp.postEvent(event, atStart: false)
                }
                app.pause(0.08)
            }
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
        static let all: [Scenario] = [
            apply, createAndImport, fujifilmPack, favorites, filmLooks, baseLookOnly, searchBaseLooks, baseLookMenu,
            showAndTrash, hideFolders,
        ]

        static func portra(_ app: RunningApp) throws -> Recipe {
            let recipe = try app.main { model in
                FilmLookCatalog.look("portra-400").flatMap { model.recipes.recipe(id: $0.recipeID) }
            }
            guard let recipe else { throw ScenarioFailure("No Portra 400 recipe") }
            return recipe
        }

        static let baseLookOnly = Scenario(
            "recipes.base-look-only",
            "A film recipe's Apply Base Look Only previews its look alone while highlighted, then sets only the look",
            claims: [.feature("recipes.applying")],
        ) { app in
            try app.openWorking()
            let recipe = try portra(app)
            let preview = try app
                .main { BaseLookPreviews.baseLookOnlyItem(recipe, model: $0)?.representedObject as? Recipe }
            guard let preview else { throw ScenarioFailure("No Apply Base Look Only, or nothing it previews") }
            try app.expect(
                preview.includes == [.baseLook],
                "Highlighting Apply Base Look Only previews more than the look",
            )
            try app.expectRenders("previewing Portra 400's look alone") { try app.main { $0.previewRecipe(preview) } }
            try app.main { $0.previewRecipe(nil) }
            let applied = try app.main { model in
                guard let item = BaseLookPreviews.baseLookOnlyItem(recipe, model: model), let action = item.action
                else { return false }
                return NSApplication.shared.sendAction(action, to: item.target, from: item)
            }
            try app.expect(applied, "Apply Base Look Only did nothing")
            try app.wait("Portra 400's look") { $0.baseLook.id == recipe.baseLook?.id }
            try app.expect(try app.main { $0.value(.grainAmount) } == 0, "Apply Base Look Only added grain")
            try app.choose(.resetAll)
            app.covered(.feature("recipes.applying"), via: .model)
        }

        /// UX-54: a film stock found in the Base Looks panel's search brings its grain and leaves the vignette.
        static let searchBaseLooks = Scenario(
            "develop.base-looks",
            "Base Looks' search finds a film stock, which previews, and a click applies it with its grain, keeping "
                + "the vignette",
            claims: [.feature("recipes.base-looks"), .feature("recipes.favorites")],
            needsFocus: true,
        ) { app in
            try app.openWorking()
            try app.main { $0.expandedSidebarSections.insert(.baseLooks) }
            try app.set(.vignetteAmount, -30)
            let found = try app.main { BaseLookPreviews.search("ektar", model: $0) }
            guard let ektar = found.first, found.count == 1 else {
                throw ScenarioFailure("Searching Base Looks for \"ektar\" finds \(found.map(\.name))")
            }
            try app.expect(
                try app.main { $0.recipes.searchPresets("t-max") }.isEmpty,
                "The Recipes panel's search finds a film stock",
            )
            try app.click(.identifier("baseLooks.search"))
            try app.type("ektar")
            try app.expectRenders("previewing \(ektar.name), as hovering its row does") {
                try app
                    .main { model in BaseLookPreviews.choice(id: ektar.id, model: model).map { model.previewLook($0) } }
            }
            try app.main { $0.previewLook(nil) }
            let focused = try app.focus()
            if focused {
                try app.clickRow("baseLooks.look.\(ektar.id)")
            } else {
                try app
                    .main { model in BaseLookPreviews.choice(id: ektar.id, model: model).map { model.chooseLook($0) } }
            }
            try app.wait("\(ektar.name) chosen") { $0.baseLook.id == ektar.id }
            try app.expect(
                try app.main { $0.value(.vignetteAmount) } == -30,
                "Choosing a film stock reset the vignette",
            )
            try app.expect(try app.main { $0.value(.grainAmount) } > 0, "\(ektar.name) came without its grain")
            try app.choose(.resetAll)
            app.covered([.feature("recipes.base-looks"), .feature("recipes.favorites")], via: focused ? .mouse : .model)
        }

        static let baseLookMenu = Scenario(
            "develop.base-look-menu",
            "The Base Look menu lists Redlamp's looks and the Film Styles, and a film stock only while it's in use",
            claims: [.feature("develop.treatment")],
        ) { app in
            try app.openWorking()
            let films = Set(FilmLookCatalog.looks.map(\.baseLookID))
            let before = try app.main { BaseLookPreviews.menuSections($0) }
            try app.expect(before.first?.name == "Redlamp", "The menu starts with \(before.first?.name ?? "nothing")")
            try app.expect(before.allSatisfy { Set($0.ids).isDisjoint(with: films) }, "The menu lists film stocks")
            let recipe = try portra(app)
            try app.main { $0.applyRecipe(recipe) }
            try app.wait("Portra 400 applied") { $0.appliedRecipe?.id == recipe.id }
            let after = try app.main { BaseLookPreviews.menuSections($0) }
            try app.expect(after.first?.ids == [recipe.baseLook?.id ?? ""], "The menu doesn't show Portra 400 first")
            try app.choose(.resetAll)
            app.covered(.feature("develop.treatment"), via: .model)
        }

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

        static let fujifilmPack = Scenario(
            "recipes.import-fujifilm-pack",
            "A downloaded pack of Fujifilm's LUTs imports from its folder, one look per simulation",
            claims: [.feature("recipes.importing")],
        ) { app in
            try app.openWorking()
            let pack = app.runDirectory.appending(path: "Fujifilm pack")
            // Each a different table: looks are identified by their tables.
            let files = [
                ("F-Log2/FLog2_to_PROVIA.cube", "F-Log2 to PROVIA", 0.9),
                ("F-Log2/FLog2_to_CLASSIC-CHROME.cube", "F-Log2 to CLASSIC CHROME", 0.8),
                ("F-Log/FLog_to_PROVIA.cube", "F-Log to PROVIA", 0.7),
                ("F-Log2/FLog2_to_WDR.cube", "F-Log2 to Wide Dynamic Range curve", 0.6),
            ]
            for (path, gamma, gain) in files {
                var lines = [
                    "#FUJIFILM Corporation",
                    "#Gamma:\(gamma)",
                    "#Gamut:F-Gamut to ITU-R BT.709",
                    "LUT_3D_SIZE 2",
                ]
                for b in 0 ... 1 {
                    for g in 0 ... 1 {
                        for r in 0 ... 1 {
                            lines.append("\(Double(r) * gain) \(Double(g) * gain) \(Double(b) * gain)")
                        }
                    }
                }
                let url = pack.appending(path: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            try app.main { RecipeActions.importFiles([pack], model: $0) }
            try app.wait("the pack's two simulations", timeout: 20) { model in
                model.recipes.all.filter { $0.group == FujifilmLUT.group }.count == 2
            }
            let stayLocal = try app.main { model in
                model.recipes.all.filter { $0.group == FujifilmLUT.group }
                    .allSatisfy {
                        $0.baseLook?.staysOnThisMac == true && model.recipes.library.exportable($0).embeddedBaseLooks
                            .isEmpty
                    }
            }
            try app.expect(stayLocal, "An imported Fujifilm look would leave this Mac in an exported recipe")
            app.covered(.feature("recipes.importing"), via: .model)
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
            let opened = try app.main { model in
                guard let item = BaseLookPreviews.filmStocksMenu(model)?.items
                    .first(where: { $0.title == "Open Film Looks" }),
                    let action = item.action
                else { return false }
                return NSApplication.shared.sendAction(action, to: item.target, from: item)
            }
            try app.expect(opened, "The Film Stocks folder has no Open Film Looks")
            guard let portra = FilmLookCatalog.look("portra-400"), let choice = LookChoice(film: portra) else {
                throw ScenarioFailure("No Portra 400 look")
            }
            try app.expectRenders("previewing Portra 400, as hovering its card does") {
                try app.main { $0.previewLook(choice) }
            }
            try app.main { $0.previewLook(nil) }
            try app
                .wait("the Film Looks window, from the Film Stocks folder", timeout: 10) { _ in
                    NSApp.windows.contains { $0.isVisible && $0.title == "Film Looks" }
                }
            try app.main { _ in NSApp.windows.first { $0.title == "Film Looks" }?.close() }
            app.covered(.feature("recipes.film-looks"), via: .menu)
        }
    }

    extension RunningApp {
        /// Whether SwiftUI draws Settings' switches and pickers itself, as on macOS 27, with no AppKit control for the
        /// driver to find (UX-44): the scenarios leave out the steps that use them.
        var settingsControlsDrawnBySwiftUI: Bool {
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        }

        /// How a scenario that left out such a step ends once the rest has passed: the known issue, in the report.
        func leftOutSettingsStep(_ control: String) -> ScenarioSkip {
            ScenarioSkip(
                knownIssue: "UX-44",
                "on macOS 27, SwiftUI draws \(control) itself, with no AppKit control to use; the rest passed",
            )
        }
    }
#endif
