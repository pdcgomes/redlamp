#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampCanvas
    import RedlampEngineAPI
    import RedlampUI

    /// Development aids for screenshots and visual checks:
    ///
    /// - `--script "<key=value,…>"` applies scripted state after launch (see
    ///   `EditorModel.applyDebugCommand`), e.g. `select=3,exposure=0.5,panel=all`. `select`
    ///   also takes a file name, and `mask=<kind>[:<part>]` computes an AI mask, such as
    ///   `mask=sky` or `mask=people:faceSkin`.
    /// - `--snapshot <path.png> [--snapshot-delay <s>] [--snapshot-quit]` writes an image of
    ///   the window without Screen Recording permission (glass materials are approximated;
    ///   `scripts/capture-screenshots.sh` uses real window captures instead). An open sheet is
    ///   captured instead of the window; `stack=open` in a script opens the Stack workspace on
    ///   the selected stack document (`stack=depth` showing the depth map, `stack=retouch`
    ///   painting one stroke from the frame under the cursor). `window=<name>` opens a window
    ///   from the Window menu by its title in kebab case, such as `window=film-looks`.
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
            case "select" where Int(value) == nil:
                guard let item = model.items.first(where: { $0.url.lastPathComponent == value }) else { return true }
                model.select(item.url)
                try? await Task.sleep(for: .milliseconds(200))
            case "mask":
                let parts = value.split(separator: ":").map(String.init)
                guard let kind = MaskKind(rawValue: parts[0]) else { return true }
                let part = parts.count > 1 ? PersonPart(rawValue: parts[1]) : nil
                await model.createAIMask(kind, part: part ?? .entirePerson)
            default:
                return false
            }
            return true
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

        private static func openMenuWindow(titled title: String) {
            func find(_ menu: NSMenu) -> (NSMenu, Int)? {
                for (index, item) in menu.items.enumerated() {
                    if item.title == title {
                        return (menu, index)
                    }
                    if let found = item.submenu.flatMap(find) {
                        return found
                    }
                }
                return nil
            }
            guard let menu = NSApp.mainMenu, let (owner, index) = find(menu) else { return }
            owner.performActionForItem(at: index)
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
