#if DEBUG
    import AppKit
    import RedlampCanvas
    import RedlampUI

    /// Development aids for screenshots and visual checks:
    ///
    /// - `--script "<key=value,…>"` applies scripted state after launch (see
    ///   `EditorModel.applyDebugCommand`), e.g. `select=3,exposure=0.5,panel=all`.
    /// - `--snapshot <path.png> [--snapshot-delay <s>] [--snapshot-quit]` writes an image of
    ///   the window without Screen Recording permission (glass materials are approximated;
    ///   `scripts/capture-screenshots.sh` uses real window captures instead).
    @MainActor
    enum DebugSnapshot {
        static func scheduleIfRequested(model: EditorModel) {
            let arguments = CommandLine.arguments
            func value(after flag: String) -> String? {
                arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            }

            if let script = value(after: "--script") {
                NSApp.activate()
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
                    model.applyDebugCommand(key, value)
                    if key == "select" {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        }

        static func capture(to url: URL) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
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
