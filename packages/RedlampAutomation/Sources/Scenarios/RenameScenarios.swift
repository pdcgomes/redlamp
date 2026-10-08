#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampDocument
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// Rename Photos and Move to Folder (LIB-25, LIB-26), on copies of the run's photos in a folder of the run's own,
    /// which the scenarios add to Folders and take out again: F2 and the menus, the sheet's template typed with a
    /// token put in from its menu, the preview, Rename, Move to Folder, and ⌘Z and ⇧⌘Z.
    enum RenameScenarios {
        static let all: [Scenario] = [renamePhotos, moveToFolder]

        static let renamePhotos = Scenario(
            "library.rename-photos",
            "F2 opens Rename Photos on the selection, as Library › Rename Photos… does; a template typed with a token "
                + "from its menu names every photo in the preview, Rename renames each with its pair and sidecars, "
                + "and ⌘Z and ⇧⌘Z take it back and make it again, the selection following",
            claims: [.action(.renamePhotos), .feature("library.rename")],
        ) { app in
            let scratch = try RenameScratch(app)
            defer { scratch.remove(app) }
            try scratch.show(app)

            try app.explaining { try app.choose(.renamePhotos) }
            try app.waitForSheet("Rename Photos")
            try app.pressInSheet(KeyCombo(.escape))
            try app.waitForNoSheet("Rename Photos")

            try app.choose(.selectAllPhotos)
            try app.wait("every photo selected") { $0.selectedPhotos.count == scratch.names.count }
            try app.explaining { try app.pressF2() }
            try app.waitForSheet("Rename Photos")
            try app.wait("the photos read and named", timeout: 30) { $0.renameSheetNames != nil }
            try app.selectSheetField()
            try app.typeInSheet("Trip-")
            try app.chooseToken("{sequence:4:folder}")
            let renamed = scratch.names.map { name in
                let stem = name.hasPrefix("IMG_0001") ? "0001" : String(name.dropFirst(4).prefix(4))
                return "Trip-\(stem).\((name as NSString).pathExtension)"
            }
            try app.wait("the preview to follow the template") { model in
                model.renameSheetNames.map(Set.init) == Set(renamed)
            }
            try app.clickInSheet("rename.rename")
            try app.waitForNoSheet("Rename Photos", timeout: 120)
            try app.wait("the photos renamed, each with its sidecar", timeout: 60) { _ in
                scratch.photos() == renamed.sorted() && renamed.allSatisfy(scratch.hasSidecar)
            }
            try app.wait("the grid showing the new names, every photo still selected") { model in
                Set(model.items.map(\.name)) == Set(renamed) && model.selectedPhotos.count == renamed.count
            }
            app.covered(.action(.renamePhotos), via: .key)
            app.covered(.feature("library.rename"), via: .key)

            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("⌘Z to put the names back", timeout: 30) { model in
                scratch.photos() == scratch.names.sorted() && Set(model.items.map(\.name)) == Set(scratch.names)
                    && model.selectedPhotos.count == scratch.names.count
            }
            try app.expectKeyBinding(.redo)
            try app.choose(.redo)
            try app.run("the Redo", timeout: 60) { await $0.filesMade() }
            try app.wait("⇧⌘Z to rename them again", timeout: 30) { _ in scratch.photos() == renamed.sorted() }
            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("the names as they were", timeout: 30) { _ in scratch.photos() == scratch.names.sorted() }
        }

        static let moveToFolder = Scenario(
            "library.move-to-folder",
            "Photo › Move to Folder… moves the photos selected, with their pairs and sidecars, into a folder of the "
                + "library, the photo after them becoming active, and ⌘Z brings them back selected",
            claims: [.action(.moveToFolder), .feature("library.rename")],
        ) { app in
            let scratch = try RenameScratch(app)
            defer { scratch.remove(app) }
            try scratch.show(app)
            let moving = Array(scratch.names.prefix(2))
            try app.click(.identifier("grid.\(moving[0])"))
            try app.wait("\(moving[0]) alone") { $0.selectedPhotos.map(\.lastPathComponent) == [moving[0]] }
            try app.press(KeyCombo(.right, shift: true))
            try app.wait("the pair selected") { $0.selectedPhotos.map(\.lastPathComponent) == moving }
            try app.main { _ in EditorModel.moveToFolderAnswer = scratch.picked }
            try app.choose(.moveToFolder)
            try app.wait("the pair and its sidecar in Picked", timeout: 60) { _ in
                scratch.photos(in: scratch.picked) == moving.sorted()
                    && scratch.hasSidecar("IMG_0001.JPG", in: scratch.picked)
            }
            try app.wait("the grid without them, the photo after them active", timeout: 30) { model in
                model.items.map(\.name) == Array(scratch.names.dropFirst(2))
                    && model.selection?.lastPathComponent == scratch.names[2]
            }
            app.covered(.feature("library.rename"), via: .menu)

            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("⌘Z to bring them back, selected", timeout: 30) { model in
                scratch.photos() == scratch.names.sorted() && scratch.photos(in: scratch.picked).isEmpty
                    && Set(model.selectedPhotos.map(\.lastPathComponent)) == Set(moving)
            }
        }
    }

    /// A folder of copies of the run's photos below the run's folder: three raws as IMG_0001 to IMG_0003, the first
    /// beside a JPEG of its name that has a sidecar, and Picked, an empty folder to move them to.
    struct RenameScratch: Sendable {
        let root: URL
        let folder: URL
        let picked: URL
        /// The photos, in the grid's order.
        let names: [String]

        init(_ app: RunningApp) throws {
            root = app.runDirectory.appending(path: "rename-\(UUID().uuidString)", directoryHint: .isDirectory)
            folder = root.appending(path: "Photos", directoryHint: .isDirectory)
            picked = folder.appending(path: "Picked", directoryHint: .isDirectory)
            let raws = ["arw", "raf", "cr3", "nef", "dng"]
            let originals = try FileManager.default.contentsOfDirectory(atPath: app.photos.path)
                .filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            guard originals.count >= 3 else { throw ScenarioFailure("The run has \(originals.count) raws to copy") }
            try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
            var names: [String] = []
            for (number, original) in originals.prefix(3).enumerated() {
                let name = String(format: "IMG_%04d.", number + 1) + (original as NSString).pathExtension
                try FileManager.default.copyItem(
                    at: app.photos.appending(path: original),
                    to: folder.appending(path: name),
                )
                names.append(name)
            }
            let jpeg = folder.appending(path: "IMG_0001.JPG")
            try FileManager.default.copyItem(at: app.photos.appending(path: "Bitmap.jpg"), to: jpeg)
            try SidecarStore(locator: .besidePhotos).save(
                Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 2)), for: jpeg,
            )
            self.names = (names + ["IMG_0001.JPG"]).sorted(by: FileOrder.precedes)
        }

        /// Adds the folder to Folders and shows it in Library's grid, from the library.
        func show(_ app: RunningApp) throws {
            let (folder, count) = (folder, names.count)
            if try app.main({ $0.module != .develop }) {
                try app.press(.developModule)
            }
            try app.main { $0.open([folder]) }
            try app.wait("the folder indexed and shown from the library", timeout: 180) { model in
                model.folder?.standardizedFileURL == folder.standardizedFileURL && model.library.isShownFromLibrary
                    && model.items.count == count
            }
            try app.settle()
            try app.press(.gridView)
            try app.wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }
            try app.wait("the grid's cells") { _ in
                Views.editorWindow.flatMap { Views.find("grid.IMG_0001.JPG", in: $0) } != nil
            }
        }

        /// The photos in `folder` (the scratch's own by default), without their sidecars, sorted.
        func photos(in folder: URL? = nil) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: (folder ?? self.folder).path)) ?? []
            return names.filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                return !["redlamp", "xmp", ""].contains(ext)
            }.sorted()
        }

        func hasSidecar(_ name: String) -> Bool {
            hasSidecar(name, in: folder)
        }

        func hasSidecar(_ name: String, in folder: URL) -> Bool {
            FileManager.default.fileExists(atPath: folder.appending(path: name + ".redlamp").path)
        }

        /// Takes the folder out of Folders and away, and opens the run's working photo again.
        func remove(_ app: RunningApp) {
            let folder = folder
            try? app.main { model in
                EditorModel.moveToFolderAnswer = nil
                ImportWindowController.forget(folder, in: model)
            }
            try? FileManager.default.removeItem(at: root)
            try? app.openWorking()
        }
    }

    extension RunningApp {
        /// Runs `body`, saying in its failure how the editor stood for Rename Photos.
        func explaining(_ body: () throws -> Void) throws {
            do {
                try body()
            } catch {
                let state = try main { model in
                    "module \(model.module), active \(model.selection?.lastPathComponent ?? "none"), "
                        + "\(model.selectedPhotos.count) selected, dialog \(model.isModalDialogOpen), "
                        + "library ready \(model.library.service?.isReady == true), "
                        + "Rename Photos available \(model.canPerform(.renamePhotos)), "
                        + "sheet \(Views.editorWindow?.attachedSheet?.title ?? "none"), "
                        + "key window \(NSApp.keyWindow?.title ?? "none"), menu items "
                        + (NSApp.mainMenu?.items ?? []).compactMap { top -> String? in
                            guard let menu = top.submenu else { return nil }
                            Menus.open(menu)
                            defer { Menus.close(menu) }
                            let items = menu.items.filter { $0.title.hasPrefix("Rename Photos") }
                            return items.isEmpty ? nil : items.map { item in
                                "\(top.title) › \(item.title) enabled \(item.isEnabled) action "
                                    + "\(item.action.map(NSStringFromSelector) ?? "none") target \(item.target.map { "\(Swift.type(of: $0))" } ?? "none")"
                            }.joined(separator: "; ")
                        }.joined(separator: "; ")
                }
                throw ScenarioFailure("\(error) (\(state))")
            }
        }

        /// F2, as the keyboard sends it: through the app's event dispatch to the key monitor.
        func pressF2() throws {
            let mark = try mark()
            post { _ in
                let key = String(UnicodeScalar(NSF2FunctionKey)!)
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.function],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: EditorWindowController.frontWindow?.windowNumber ?? 0, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: UInt16(kVK_F2),
                ) else { return }
                NSApp.sendEvent(event)
            }
            try expectPerformed(.renamePhotos, since: mark)
        }

        /// Selects all of the text in the sheet's field that has the keyboard, as ⌘A does.
        func selectSheetField() throws {
            try main { _ in
                guard let editor = Views.editorWindow?.attachedSheet?.firstResponder as? NSTextView else {
                    throw ScenarioFailure("No field in the sheet has the keyboard")
                }
                editor.selectAll(nil)
            }
        }

        /// Types `text` in the sheet, a key at a time, through the sheet's window; a character this keyboard
        /// layout types with other keys goes in as the text system puts it in.
        func typeInSheet(_ text: String) throws {
            for character in text {
                try main { _ in
                    guard let sheet = Views.editorWindow?.attachedSheet else { throw ScenarioFailure("No sheet is up") }
                    let lower = Character(character.lowercased())
                    guard character.isLetter || character.isNumber || character == "-", Keyboard.hasKey(for: lower)
                    else {
                        let editor = sheet.firstResponder as? NSTextView
                        editor?.insertText(String(character), replacementRange: editor?.selectedRange() ?? NSRange())
                        return
                    }
                    let typed = try Keyboard.event(KeyCombo(.character(lower), shift: character.isUppercase))
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: typed.modifierFlags, timestamp: typed.timestamp,
                        windowNumber: sheet.windowNumber, context: nil, characters: typed.characters ?? "",
                        charactersIgnoringModifiers: typed.charactersIgnoringModifiers ?? "", isARepeat: false,
                        keyCode: typed.keyCode,
                    ) else { return }
                    sheet.sendEvent(event)
                }
                pause(0.03)
            }
        }

        /// Clicks the control carrying `identifier` in the sheet, through the sheet's window, as the mouse does.
        func clickInSheet(_ identifier: String) throws {
            let location = try main { _ -> NSPoint in
                guard let sheet = Views.editorWindow?.attachedSheet, let control = Self.view(
                    identifier,
                    in: sheet.contentView,
                )
                else { throw ScenarioFailure("\(identifier) isn't in the sheet") }
                let frame = control.convert(control.bounds, to: nil)
                return NSPoint(x: frame.midX, y: frame.midY)
            }
            post { _ in
                guard let sheet = Views.editorWindow?.attachedSheet else { return }
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    )
                }
                guard events.count == 2 else { return }
                // The button tracks the press, and takes the release from the queue as the mouse's.
                NSApp.postEvent(events[1], atStart: false)
                sheet.sendEvent(events[0])
            }
            pause(0.2)
        }

        /// Chooses `token` in the sheet's Insert Token menu, as a click on its item does.
        func chooseToken(_ token: String) throws {
            try main { _ in
                guard let sheet = Views.editorWindow?.attachedSheet,
                      let button = Self.view("rename.template.tokens", in: sheet.contentView) as? NSPopUpButton,
                      let (menu, index) = Self.item("rename.template.token.\(token)", in: button.menu)
                else { throw ScenarioFailure("The Insert Token menu has no \(token)") }
                menu.performActionForItem(at: index)
            }
            pause(0.1)
        }

        @MainActor private static func view(_ identifier: String, in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            return view.subviews.lazy.compactMap { Self.view(identifier, in: $0) }.first
        }

        @MainActor private static func item(_ identifier: String, in menu: NSMenu?) -> (NSMenu, Int)? {
            guard let menu else { return nil }
            for (index, item) in menu.items.enumerated() {
                if item.accessibilityIdentifier() == identifier {
                    return (menu, index)
                }
                if let found = Self.item(identifier, in: item.submenu) {
                    return found
                }
            }
            return nil
        }
    }
#endif
