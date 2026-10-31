#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampCanvas
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// Development aids for screenshots and visual checks:
    ///
    /// - `--script "<key=value,…>"` applies scripted state after launch (see
    ///   `EditorModel.applyDebugCommand`), e.g. `select=3,exposure=0.5,panel=all`. `select`
    ///   also takes a file name, `mask=<kind>[:<part>]` computes an AI mask, such as
    ///   `mask=sky` or `mask=people:faceSkin`, `mask-pick=<kind>` picks an AI kind as the mask
    ///   picker does, asking first for a model it needs and, for Sky, offering the models that make
    ///   it better, `mask-select=<n>` selects the nth mask, and
    ///   `overlay=<style>` shows masks in one of `MaskOverlayStyle`'s modes, such as
    ///   `overlay=imageOnBlack` (`overlay=off` hides it); `palette=<steps>` drives
    ///   the command palette as the harness's `--palette-steps` does, such as
    ///   `palette=open;type:exposure;enter;right`; `quit=now` quits there and then, as ⌘Q would.
    /// - `--snapshot <path.png> [--snapshot-delay <s>] [--snapshot-quit]` writes an image of
    ///   the window without Screen Recording permission (glass materials are approximated;
    ///   `scripts/capture-screenshots.sh` uses real window captures instead). An open sheet is
    ///   captured instead of the window, or with `--snapshot-window` over the window where it
    ///   sits, any part hanging past the window's edge included. `export=open` in a script opens
    ///   the Export dialog from the File menu, and `export=end` opens it and turns a mouse wheel
    ///   over its settings to their end; the dialog holds the app, so either comes last.
    ///   `stack=open` in a script opens the Stack workspace on
    ///   the selected stack document (`stack=depth` showing the depth map, `stack=retouch`
    ///   painting one stroke from the frame under the cursor). `window=<name>` opens a window
    ///   from the Window menu by its title in kebab case, such as `window=film-looks`;
    ///   `welcome=<step>` opens the welcome window playing its film (`film`) or on a page
    ///   (`about`, `help`). `feedback=form` opens Report a Bug or Send Feedback
    ///   (`feedback=note` at its note, `feedback=error` filled in as the button beside a photo's
    ///   open error fills it), and `feedback=reports` Your Reports. `whats-new=<step>`
    ///   opens What's New from the Help menu playing its film (`film`), on its highlights
    ///   (`highlights`) or on a page (`page1`, `page2`, …). `filmstrip=shown` keeps the filmstrip
    ///   up with a photo selected, `inspector=end` scrolls the inspector to its end, `extend=<n>`
    ///   selects from the open photo to the nth, or to the one with that file name, as ⇧-click does,
    ///   `wait=<seconds>` pauses the script, and `wait=library` until the library has opened and the
    ///   launch has reopened what it showed, `type=<identifier>` clicks a value
    ///   field to type in it, such as `type=slider.basic.exposure.value`, `off=<panel>[+<panel>]`
    ///   switches Develop panels off, `scrollers=flash` shows every window's scrollers twice a second
    ///   so a capture finds them showing, `settings=open` opens Settings, and `filmstrip-menu=<n>` opens
    ///   the context menu of the nth photo on screen; the menu holds the app, so it comes last.
    ///   `import=<folder>[;<destination>[;<backup>]]` opens the import window on a folder as on a card
    ///   whose photos are in its `DCIM`, importing to the destination and backing up to the backup, and
    ///   `lightroom=<catalog>` opens Import from Lightroom Classic on a catalog, as Choose… picks it.
    ///   `scroll=<to>[:<seconds>]` scrolls the Library grid to `<to>`, a fraction of its height (`0.5`) or a
    ///   number of rows from where it is (`+40`, `-12`), over the seconds given (2), easing in and out, a step
    ///   for each frame the display draws; `find=<text>` types the text at the end of the filter bar's, a key
    ///   every 120 ms, showing the bar first; and `source=<source>` shows one of the Library section's entries
    ///   by its key (`all-photographs`, `marked`), a collection (`collection:<path>`) or a folder
    ///   (`folder:<path>`). A command's value is everything after its first `=`, so `find=rating>=4` types
    ///   `rating>=4`. `judge=<tools>` turns on the judging bar's `histogram`, `peaking` and `af`, joined by
    ///   `+`; `painter=<keywords>` takes the keyword painter out to paint them, and `click=<file name>` clicks a
    ///   photo in the Library grid, as a press and release on its cell do, so the painter paints it;
    ///   `settings=<tab>` opens Settings on the tab with that label (`Shortcuts`); `import=start` imports
    ///   what the import window has chosen and waits for it to finish; `move=<folder>` runs Move to Folder… with
    ///   its panel answered; and `signal=<path>` makes an empty file there, so a capture can be taken at that
    ///   moment. After `tool=heal`, `heal=<how>` picks what to remove with Click picks on Object, setting Drag
    ///   as the panel's menu does and waiting for the pick, at fractions of the photo's width and height:
    ///   `heal=click:x:y` as a click there, `heal=box:x:y:width:height` as a box dragged around it, and
    ///   `heal=stroke:x1:y1:x2:y2…` as a stroke brushed through the points, which adds to the selected
    ///   pick when it passes over it. While Develop is shown, every command but
    /// `wait`, `scroll`, `find`, `source` and `quit` waits for
    ///   its photo to open first; in the Library, which may have none open, no command waits.
    /// - `--whats-new-endpoint <url>` reads What's New from elsewhere for this launch: a Preview
    ///   deployment's `/api/whats-new`, or a `file://` feed whose image URLs are absolute.
    /// - `--window-size <width>x<height>` sizes the editor's content in points and centres it
    ///   on a Retina screen if there is one, so captures are 2×, without touching its saved
    ///   frame (`scripts/capture-promo.sh`). Windows a script opens are centred there too.
    @MainActor
    enum DebugSnapshot {
        static func scheduleIfRequested(model: EditorModel) {
            let arguments = LaunchArguments.all
            func value(after flag: String) -> String? {
                arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            }

            if let size = value(after: "--window-size").flatMap(parseSize) {
                resizeEditor(to: size)
            }
            if let endpoint = value(after: "--whats-new-endpoint") {
                // For this launch only: the defaults are shared with an installed Redlamp.
                var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                arguments["WhatsNewEndpoint"] = endpoint
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            }

            // Deliberately never activates the app: stealing focus while someone types
            // elsewhere sends their keystrokes (e.g. Z for zoom) into the editor.
            if let script = value(after: "--script") {
                run(script, model: model)
            }

            guard let path = value(after: "--snapshot") else { return }
            let delay = value(after: "--snapshot-delay").flatMap(Double.init) ?? 5
            let quit = arguments.contains("--snapshot-quit")
            let withWindow = arguments.contains("--snapshot-window")
            // In the common modes, so it also fires while the Export dialog's modal loop runs.
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated {
                    capture(to: URL(fileURLWithPath: path), withWindow: withWindow)
                    if quit {
                        NSApp.terminate(nil)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }

        /// The commands that don't wait for a photo to open in Develop.
        private static let libraryCommands: Set = ["wait", "scroll", "find", "source", "quit"]

        private static func run(_ script: String, model: EditorModel) {
            let commands = script.split(separator: ",").compactMap { command -> (String, String)? in
                let parts = command.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
            Task { @MainActor in
                for (key, value) in commands {
                    // Edits only stick once the image has finished opening, or failed to; the Library's
                    // sources open none in Develop.
                    while !libraryCommands.contains(key), model.module != .library,
                          (model.info == nil && model.errorMessage == nil) || model.isLoading {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if await runAppCommand(key, value, model: model) {
                        continue
                    }
                    model.applyDebugCommand(key, value)
                    if key == "select" {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        }

        /// Carries out the script commands the model can't do on its own; `false` leaves the
        /// command to `EditorModel.applyDebugCommand`.
        private static func runAppCommand(_ key: String, _ value: String, model: EditorModel) async -> Bool {
            switch key {
            case "stack":
                guard let selection = model.selection else { return false }
                await openStack(selection, showing: value, model: model)
            case "window":
                await openWindow(titled: value.split(separator: "-").map(\.capitalized).joined(separator: " "))
            case "welcome":
                await openWelcome(at: value)
            case "whats-new":
                await openWhatsNew(at: value)
            case "filmstrip-menu":
                await showFilmstripMenu(at: Int(value) ?? 0)
            case "inspector" where value == "end":
                await scrollInspectorToEnd()
            case "scrollers" where value == "flash":
                flashScrollers()
            case "settings" where value == "open":
                await openSettings()
            case "settings":
                await openSettings()
                await showSettingsTab(value)
            case "click":
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let grid = LibraryGridViews.grid(in: window),
                      let item = model.items.first(where: { $0.url.lastPathComponent == value })
                else { return true }
                LibraryGridViews.click(grid, photo: item.url)
                try? await Task.sleep(for: .milliseconds(200))
            case "import" where value == "start":
                await ImportWindowController.current?.importAndWait()
            case "signal":
                FileManager.default.createFile(atPath: value, contents: nil)
            case "type":
                await beginTyping(in: value)
            case "scroll":
                await scrollGrid(value)
            case "find":
                await find(value, model: model)
            case "select" where Int(value) == nil:
                await select(named: value, model: model)
            case "extend" where Int(value) == nil:
                guard let index = model.items.firstIndex(where: { $0.url.lastPathComponent == value }) else {
                    return true
                }
                model.applyDebugCommand(key, String(index))
            case "wait" where value == "library":
                for _ in 0 ..< 300 {
                    if model.library.service?.isReady == true, !model.librarySources.isReopening {
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            case "wait":
                try? await Task.sleep(for: .seconds(Double(value) ?? 1))
            case "mask":
                await createMask(value, model: model)
            case "mask-pick":
                guard let kind = MaskKind(rawValue: value), kind.isAI else { return true }
                await model.startAIMask(kind)
            case "heal":
                await pickToRemove(value, model: model)
            case "mask-select":
                guard let index = Int(value), model.masks.indices.contains(index) else { return true }
                model.selectedMaskID = model.masks[index].id
                model.selectedComponentID = nil
            case "overlay" where value == "off":
                model.showMaskOverlay = false
            case "overlay":
                model.maskOverlayStyle = MaskOverlayStyle.allCases.first { value == "\($0)" } ?? model.maskOverlayStyle
            case "export":
                openExport(scrolledToEnd: value == "end")
            case "feedback" where value == "reports":
                FeedbackActions.presentReports(model: model)
            case "feedback":
                // For this launch only: the defaults are shared with an installed Redlamp.
                var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                arguments["feedback.noteAccepted"] = value == "note" ? 0 : 1
                arguments["feedback.draft"] = Data()
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                model.sendFeedback(value == "error" ? model.openErrorReport : nil)
            case "palette":
                await drivePalette(value, model: model)
            case "import":
                await openImport(value, model: model)
            case "lightroom":
                await openLightroom(catalog: URL(fileURLWithPath: value), model: model)
            case "quit":
                NSApp.terminate(nil)
            default:
                return false
            }
            return true
        }

        private static func select(named name: String, model: EditorModel) async {
            guard let item = model.items.first(where: { $0.url.lastPathComponent == name }) else { return }
            model.select(item.url)
            try? await Task.sleep(for: .milliseconds(200))
        }

        /// `sky`, `people`, or a person's part such as `people:faceSkin`.
        private static func createMask(_ value: String, model: EditorModel) async {
            let parts = value.split(separator: ":").map(String.init)
            guard let kind = MaskKind(rawValue: parts[0]) else { return }
            let part = parts.count > 1 ? PersonPart(rawValue: parts[1]) : nil
            await model.createAIMask(kind, part: part ?? .entirePerson)
        }

        /// `click:x:y`, `box:x:y:width:height` or `stroke:x1:y1:x2:y2…`, in fractions of the photo.
        private static func pickToRemove(_ value: String, model: EditorModel) async {
            let parts = value.split(separator: ":")
            let numbers = parts.dropFirst().compactMap { Double($0) }
            guard numbers.count == parts.count - 1 else { return }
            model.spotPick = .object
            switch parts.first {
            case "click" where numbers.count == 2:
                await model.pickRegion(at: ImagePoint(x: numbers[0], y: numbers[1]))
            case "box" where numbers.count == 4:
                model.objectSelection = .rectangle
                let box = ImageRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
                await model.pickRegion(in: box)
            case "stroke" where numbers.count >= 4 && numbers.count.isMultiple(of: 2):
                model.objectSelection = .brush
                let corners = stride(from: 0, to: numbers.count, by: 2).map {
                    ImagePoint(x: numbers[$0], y: numbers[$0 + 1])
                }
                // As many points between the corners as a drag's events give, so the stroke's prompts spread as
                // a drag's do. The reach is the Brush's 16 points on a photo shown about 800 points tall.
                let stroke = zip(corners, corners.dropFirst()).flatMap { a, b in
                    (0 ..< 8).map { step in
                        let t = Double(step) / 8
                        return ImagePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    }
                } + corners.suffix(1)
                await model.pickRegion(along: stroke, reach: 0.02)
            default:
                return
            }
        }

        private static let paletteKeys: [String: PaletteKey] = [
            "up": .up, "down": .down, "left": .left([]), "right": .right([]), "shift-right": .right(.shift),
            "enter": .submit, "esc": .escape, "delete": .deleteBackward,
        ]

        /// Steps between `;`: `open`, `sliders`, `type:<text>` (`_` for a space, since launch
        /// arguments split on spaces), `up`, `down`, `left`, `right`, `shift-right`, `enter`, `esc`,
        /// `delete`, and `shift`, which holds ⇧ so its hint in the slider bar lights up.
        private static func drivePalette(_ steps: String, model: EditorModel) async {
            for step in steps.split(separator: ";").map(String.init) {
                if step == "open" || step == "sliders" {
                    model.openCommandPalette(scope: step == "open" ? .all : .sliders)
                } else if let key = paletteKeys[step] {
                    model.commandPalette?.handle(key)
                } else if step == "shift" {
                    model.commandPalette?.heldModifiers = .shift
                } else if step.hasPrefix("type:") {
                    model.commandPalette?.setText(step.dropFirst(5).replacingOccurrences(of: "_", with: " "))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        private static func openStack(_ selection: URL, showing value: String, model: EditorModel) async {
            model.openStackWorkspace(selection)
            guard let workspace = model.stackWorkspace else { return }
            workspace.showsDepth = value == "depth"
            workspace.isRetouching = value == "retouch"
            if value == "retouch" {
                while workspace.preview == nil || workspace.isMerging {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                workspace.brushRadius = 0.04
                await workspace.addStroke((0 ... 20).map { CGPoint(x: 0.15 + 0.03 * Double($0), y: 0.3) })
            }
        }

        private static func parseSize(_ text: String) -> CGSize? {
            let parts = text.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
        }

        /// The screen `--window-size` put the editor on; windows a script opens join it there.
        private static var captureScreen: NSScreen?

        /// Clears the autosave name first, so the size never replaces the one the editor reopens at.
        private static func resizeEditor(to size: CGSize) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            window.setFrameAutosaveName("")
            window.setContentSize(size)
            captureScreen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? window.screen
            if let captureScreen {
                center(window, on: captureScreen)
            }
        }

        private static func center(_ window: NSWindow, on screen: NSScreen) {
            let visible = screen.visibleFrame
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
        }

        /// Opens a window from the Window menu, on the capture screen when there is one.
        private static func openWindow(titled title: String) async {
            openMenuWindow(titled: title)
            guard let captureScreen else { return }
            for _ in 0 ..< 20 {
                if let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) {
                    center(window, on: captureScreen)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        /// Opens the welcome window on the capture screen, playing its film (`film`) or on a page
        /// (`about`, `help`).
        private static func openWelcome(at step: String) async {
            openMenuWindow(titled: "Welcome to Redlamp")
            guard let welcome = NSApp.windows.lazy.compactMap({ $0.windowController as? WelcomeWindowController })
                .first else {
                return
            }
            if let captureScreen, let window = welcome.window {
                center(window, on: captureScreen)
            }
            for _ in 0 ..< (["about": 1, "help": 2][step] ?? 0) {
                welcome.next()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        private static func openMenuWindow(titled title: String) {
            AppDelegate.performMenuItem(titled: title)
        }

        /// The import window on `<folder>[;<destination>[;<backup>]]`, the folder shown as a card in a reader
        /// is, with the standard folders and the camera's names.
        private static func openImport(_ value: String, model: EditorModel) async {
            let folders = value.split(separator: ";").map { URL(fileURLWithPath: String($0), isDirectory: true) }
            guard let card = folders.first else { return }
            model.applyDebugCommand("action", ShortcutAction.importPhotos.rawValue)
            guard let window = await shown({ ImportWindowController.current }) else { return }
            if folders.count > 1 {
                window.prepare(
                    destination: folders[1],
                    backup: folders.count > 2 ? folders[2] : nil,
                    folders: "{date:yyyy}/{date:yyyy-MM-dd}",
                    names: "{name}",
                )
            }
            try? await window.add(card: card)
        }

        /// Import from Lightroom Classic, given `catalog` as Choose…'s open panel would give it.
        private static func openLightroom(catalog: URL, model: EditorModel) async {
            model.applyDebugCommand("action", ShortcutAction.importFromLightroom.rawValue)
            await shown { LightroomWindowController.current }?.choose(catalog: catalog)
        }

        /// The window controller `current` gives once its window shows, moved to the capture screen.
        @discardableResult
        private static func shown<Controller: NSWindowController>(_ current: () -> Controller?) async -> Controller? {
            for _ in 0 ..< 50 {
                if let controller = current(), let window = controller.window, window.isVisible {
                    if let captureScreen {
                        center(window, on: captureScreen)
                    }
                    return controller
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        /// Overlay scrollers show only while scrolling: every window's are shown again and again, as long as
        /// the app runs.
        private static func flashScrollers() {
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    @MainActor func scrollViews(in view: NSView) -> [NSScrollView] {
                        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
                    }
                    for window in NSApp.windows where window.isVisible {
                        window.contentView?.superview.map(scrollViews)?.forEach { $0.flashScrollers() }
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }

        /// Settings, from the app menu, on the capture screen when there is one. Its window is titled after
        /// its tab.
        private static func openSettings() async {
            guard let title = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
                $0.title.hasPrefix("Settings")
            })?.title else { return }
            let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            openMenuWindow(titled: title)
            guard let captureScreen else { return }
            for _ in 0 ..< 20 {
                if let window = NSApp.windows.first(where: { $0.isVisible && !shown.contains(ObjectIdentifier($0)) }) {
                    center(window, on: captureScreen)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        /// Opens the context menu of the filmstrip's `index`th photo on screen, rising from its
        /// middle as a right-click there does near the bottom of the screen, with the photo ringed.
        /// The menu holds the app until it closes, so it comes last in a script.
        /// The inspector is the scroll view furthest right in the editor window.
        /// Clicks the value field carrying `identifier`, such as `slider.basic.exposure.value`, so it
        /// shows as it does while a value is typed in.
        private static func beginTyping(in identifier: String) async {
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let root = window.contentView
            else { return }
            func find(_ view: NSView) -> NSView? {
                view.accessibilityIdentifier() == identifier ? view : view.subviews.lazy.compactMap(find).first
            }
            guard let field = find(root) else { return }
            let location = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
                ) else { continue }
                type == .leftMouseDown ? field.mouseDown(with: event) : field.mouseUp(with: event)
            }
        }

        private static func scrollInspectorToEnd() async {
            try? await Task.sleep(for: .seconds(1))
            guard let root = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView
            else { return }
            func scrollViews(in view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
            }
            guard let inspector = scrollViews(in: root)
                .filter({ !$0.isHiddenOrHasHiddenAncestor && $0.documentView != nil })
                .max(by: { $0.convert($0.bounds, to: nil).maxX < $1.convert($1.bounds, to: nil).maxX }),
                let document = inspector.documentView
            else { return }
            let clip = inspector.contentView
            let end = document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: end))
            inspector.reflectScrolledClipView(clip)
        }

        /// Settings' tab labelled `label`, chosen as a click on its toolbar item does.
        private static func showSettingsTab(_ label: String) async {
            for _ in 0 ..< 20 {
                for window in NSApp.windows where window.isVisible {
                    if let toolbar = window.toolbar, let item = toolbar.items.first(where: { $0.label == label }),
                       let action = item.action {
                        toolbar.selectedItemIdentifier = item.itemIdentifier
                        NSApp.sendAction(action, to: item.target, from: item)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        /// The Library grid scrolled as `<to>[:<seconds>]` says, where it should be at each frame a capture records.
        private static func scrollGrid(_ value: String) async {
            let parts = value.split(separator: ":").map(String.init)
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let grid = LibraryGridViews.grid(in: window), let position = LibraryGridViews.position(of: grid),
                  let amount = parts.first.flatMap(Double.init)
            else { return }
            let byRows = parts[0].hasPrefix("+") || parts[0].hasPrefix("-")
            let from = position.fraction
            let to = min(max(byRows ? from + amount * position.row : amount, 0), 1)
            let seconds = parts.count > 1 ? Double(parts[1]) ?? 2 : 2
            await DisplayFrames.run(in: window, for: seconds) { progress in
                LibraryGridViews.scroll(grid, to: from + (to - from) * (1 - cos(progress * .pi)) / 2)
            }
        }

        /// Types `text` at the end of the filter bar's text a key at a time, at a typist's pace.
        private static func find(_ text: String, model: EditorModel) async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let filters = model.libraryFilters
            else { return }
            if !filters.isBarShown {
                filters.setBarShown(true)
                try? await Task.sleep(for: .milliseconds(300))
            }
            for character in text {
                guard LibraryFilterBars.type(String(character), in: window) else { return }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        private static func showFilmstripMenu(at index: Int) async {
            try? await Task.sleep(for: .seconds(1))
            guard let root = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                  let window = root.window
            else { return }
            func cells(in view: NSView) -> [NSView] {
                (String(describing: type(of: view)) == "FilmstripCellView" ? [view] : []) + view.subviews.flatMap(cells)
            }
            let onScreen = cells(in: root).filter { !$0.isHiddenOrHasHiddenAncestor }
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            guard onScreen.indices.contains(index) else { return }
            let cell = onScreen[index]
            let middle = NSPoint(x: cell.bounds.midX, y: cell.bounds.midY)
            guard let click = NSEvent.mouseEvent(
                with: .rightMouseDown, location: cell.convert(middle, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1,
            ), let menu = cell.menu(for: click) else { return }
            // `NSMenu.popUpContextMenu` opens downwards, out of the window, when the screen has room below.
            let height = menu.size.height
            let corner = NSPoint(x: middle.x, y: cell.isFlipped ? middle.y - height : middle.y + height)
            DispatchQueue.main.async {
                cell.willOpenMenu(menu, with: click)
                menu.popUp(positioning: nil, at: corner, in: cell)
                cell.didCloseMenu(menu, with: click)
            }
        }

        /// Opens What's New from the Help menu on the capture screen, playing its film (`film`), on
        /// its highlights (`highlights`) or on a page (`page1`, `page2`, …).
        private static func openWhatsNew(at step: String) async {
            openMenuWindow(titled: WhatsNewWindowController.title)
            var whatsNew: WhatsNewWindowController?
            for _ in 0 ..< 100 where whatsNew == nil {
                try? await Task.sleep(for: .milliseconds(100))
                whatsNew = NSApp.windows.lazy.compactMap { $0.windowController as? WhatsNewWindowController }.first
            }
            guard let whatsNew else { return }
            if let captureScreen, let window = whatsNew.window {
                center(window, on: captureScreen)
            }
            let steps = step == "highlights" ? 1 : step.hasPrefix("page") ? 1 + (Int(step.dropFirst(4)) ?? 1) : 0
            for _ in 0 ..< steps {
                whatsNew.next()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        static func capture(to url: URL, withWindow: Bool = false) {
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            let rep = if withWindow, let sheet = main.attachedSheet {
                composite(sheet, over: main)
            } else {
                image(of: main.attachedSheet ?? main)
            }
            try? rep?.representation(using: .png, properties: [:])?.write(to: url)
        }

        static func image(of window: NSWindow) -> NSBitmapImageRep? {
            guard let root = window.contentView?.superview ?? window.contentView,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)
            else { return nil }
            root.cacheDisplay(in: root.bounds, to: rep)

            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                for canvas in canvases(in: root) where !canvas.isHiddenOrHasHiddenAncestor {
                    guard let image = canvas.snapshotImage() else { continue }
                    let frame = canvas.convert(canvas.bounds, to: root)
                    let rect = root.isFlipped
                        ? NSRect(
                            x: frame.minX,
                            y: root.bounds.height - frame.maxY,
                            width: frame.width,
                            height: frame.height,
                        )
                        : frame
                    context.cgContext.draw(image, in: rect)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return rep
        }

        private static func canvases(in view: NSView) -> [CanvasMetalView] {
            (view as? CanvasMetalView).map { [$0] } ?? view.subviews.flatMap(canvases)
        }
    }

    /// Calls a step at each frame a window's display draws, with the fraction of the time given that will have gone
    /// when the frame shows, the last call with 1.
    @MainActor
    private final class DisplayFrames: NSObject {
        private let seconds: Double
        private let step: (Double) -> Void
        private var started: CFTimeInterval?
        private var finished: CheckedContinuation<Void, Never>?

        private init(seconds: Double, step: @escaping (Double) -> Void) {
            self.seconds = seconds
            self.step = step
        }

        static func run(in window: NSWindow, for seconds: Double, _ step: @escaping (Double) -> Void) async {
            let frames = DisplayFrames(seconds: max(seconds, 0), step: step)
            // The link holds its target until it's invalidated.
            let link = window.displayLink(target: frames, selector: #selector(frame(_:)))
            await withCheckedContinuation { continuation in
                frames.finished = continuation
                link.add(to: .main, forMode: .common)
            }
        }

        @objc private func frame(_ link: CADisplayLink) {
            let started = started ?? link.timestamp
            self.started = started
            let progress = seconds > 0 ? min((link.targetTimestamp - started) / seconds, 1) : 1
            step(progress)
            guard progress >= 1 else { return }
            link.invalidate()
            finished?.resume()
            finished = nil
        }
    }
#endif
