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
    ///   `mask=sky` or `mask=people:faceSkin`, and `overlay=<style>` shows masks in one of
    ///   `MaskOverlayStyle`'s modes, such as `overlay=imageOnBlack`; `palette=<steps>` drives
    ///   the command palette as the harness's `--palette-steps` does, such as
    ///   `palette=open;type:exposure;enter;right`; `quit=now` quits there and then, as ⌘Q would.
    /// - `--snapshot <path.png> [--snapshot-delay <s>] [--snapshot-quit]` writes an image of
    ///   the window without Screen Recording permission (glass materials are approximated;
    ///   `scripts/capture-screenshots.sh` uses real window captures instead). An open sheet is
    ///   captured instead of the window; `stack=open` in a script opens the Stack workspace on
    ///   the selected stack document (`stack=depth` showing the depth map, `stack=retouch`
    ///   painting one stroke from the frame under the cursor). `window=<name>` opens a window
    ///   from the Window menu by its title in kebab case, such as `window=film-looks`;
    ///   `welcome=<step>` opens the welcome window playing its film (`film`) or on a page
    ///   (`about`, `help`). `feedback=form` opens Report a Bug or Send Feedback
    ///   (`feedback=note` at its note), and `feedback=reports` Your Reports. `whats-new=<step>`
    ///   opens What's New from the Help menu playing its film (`film`), on its highlights
    ///   (`highlights`) or on a page (`page1`, `page2`, …). `filmstrip=shown` keeps the filmstrip
    ///   up with a photo selected, `extend=<n>` selects from the open photo to the nth, as ⇧-click
    ///   does, and `filmstrip-menu=<n>` opens the context menu of the nth photo on screen; the menu
    ///   holds the app, so it comes last.
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
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                capture(to: URL(fileURLWithPath: path))
                if quit {
                    NSApp.terminate(nil)
                }
            }
        }

        private static func run(_ script: String, model: EditorModel) {
            let commands = script.split(separator: ",").compactMap { command -> (String, String)? in
                let parts = command.split(separator: "=").map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
            Task { @MainActor in
                for (key, value) in commands {
                    // Edits only stick once the image has finished opening.
                    while model.info == nil || model.isLoading {
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
            case "select" where Int(value) == nil:
                await select(named: value, model: model)
            case "mask":
                await createMask(value, model: model)
            case "overlay":
                model.maskOverlayStyle = MaskOverlayStyle.allCases.first { value == "\($0)" } ?? model.maskOverlayStyle
            case "feedback" where value == "reports":
                FeedbackActions.presentReports(model: model)
            case "feedback":
                // For this launch only: the defaults are shared with an installed Redlamp.
                UserDefaults.standard.setVolatileDomain(
                    ["feedback.noteAccepted": value == "note" ? 0 : 1, "feedback.draft": Data()],
                    forName: UserDefaults.argumentDomain,
                )
                model.sendFeedback()
            case "palette":
                await drivePalette(value, model: model)
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

        /// Opens the context menu of the filmstrip's `index`th photo on screen, rising from its
        /// middle as a right-click there does near the bottom of the screen, with the photo ringed.
        /// The menu holds the app until it closes, so it comes last in a script.
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

        static func capture(to url: URL) {
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let window = Optional(main.attachedSheet ?? main),
                  let root = window.contentView?.superview ?? window.contentView,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)
            else { return }
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
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }

        private static func canvases(in view: NSView) -> [CanvasMetalView] {
            (view as? CanvasMetalView).map { [$0] } ?? view.subviews.flatMap(canvases)
        }
    }
#endif
