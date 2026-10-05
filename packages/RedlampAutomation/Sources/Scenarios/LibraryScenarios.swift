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

    enum LibraryScenarios {
        static let all: [Scenario] = [subfolders, thumbnails, diskChanges, ratings]

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
        static let all: [Scenario] = [failedSave, readOnly]

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
        static let all: [Scenario] = [formats, sizes, metadata, previous]

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
