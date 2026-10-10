#if DEBUG || REDLAMP_PROFILING
    import AppKit
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// Records in the run's failures folder what the app was like as `name` failed: the editor
        /// window's state (`<name>.json`) and, with `window`, the whole editor window as it draws
        /// itself, panels included (`<name>-window.png`). Returns the state's file.
        @discardableResult
        func recordFailure(_ name: String, _ failure: String, window: Bool = true) -> URL {
            let folder = runDirectory.appending(path: "failures")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = FailureRecord.fileName(name)
            var state = (try? main { EditorState.describe($0) }) ?? ["state": "the main thread didn't answer"]
            state["failure"] = failure
            if window {
                let shot = folder.appending(path: "\(base)-window.png")
                let drawn = try? main { _ in Views.editorWindow.map { Snapshot.capture($0, to: shot) } }
                state["windowSnapshot"] = drawn == true ? shot.lastPathComponent : "none"
            }
            let url = folder.appending(path: "\(base).json")
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
            }
            return url
        }
    }

    enum FailureRecord {
        /// A step's or a scenario's name as a file name.
        static func fileName(_ name: String) -> String {
            String(name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
        }
    }

    /// The editor window's state, as JSON values: what's active and in front, what has the keyboard,
    /// what Develop shows, and where the panels are against what the model says.
    @MainActor
    enum EditorState {
        static func describe(_ model: EditorModel) -> [String: Any] {
            let editor = Views.editorWindow
            var state: [String: Any] = [
                "app": [
                    "active": NSApp.isActive,
                    "keyWindow": NSApp.keyWindow.map(Views.describe) ?? "none",
                    "mainWindow": NSApp.mainWindow.map(Views.describe) ?? "none",
                    "modalWindow": NSApp.modalWindow.map(Views.describe) ?? "none",
                    // A modal session or a menu's tracking runs the main thread in a mode of its own.
                    "runLoopMode": RunLoop.current.currentMode?.rawValue ?? "none",
                    "screens": NSScreen.screens.map { "\($0.localizedName) \(Views.describe($0.frame))" },
                    "displaysAsleep": Displays.allAsleep,
                    "screenLocked": Displays.screenLocked,
                ],
                "windows": NSApp.windows.filter(\.isVisible).map(window),
                "develop": [
                    "module": model.module.rawValue,
                    "libraryView": model.libraryView.rawValue,
                    "photo": model.selection?.lastPathComponent ?? "none",
                    "photoOpen": model.info != nil,
                    "loading": model.isLoading,
                    "rendered": model.hasFrame,
                    "error": model.errorMessage ?? "none",
                    "modalDialog": model.isModalDialogOpen,
                    "tool": "\(model.activeTool)",
                    "drawing": model.drawingKind.map { "\($0)" } ?? "none",
                ],
                "source": [
                    "folder": model.folder?.path ?? "none",
                    "includesSubfolders": model.library.includesSubfolders,
                    "recentlyTrashed": model.library.showsRecentlyTrashed,
                    "listing": model.library.isListing,
                    "photos": model.items.count,
                ],
                "panels": [
                    "left": model.leftPanelVisible,
                    "right": model.rightPanelVisible,
                    "filmstrip": model.filmstripVisible,
                    "filmstripHidesAutomatically": model.filmstripHidesAutomatically,
                    "expanded": model.expandedPanels.map(\.rawValue).sorted(),
                    "presenting": model.isPresenting,
                    "lightsOut": model.lightsOut,
                    "infoOverlay": model.infoOverlay,
                    "shortcuts": model.showShortcuts,
                    "palette": model.commandPalette != nil,
                    "showBefore": model.showBefore,
                ],
            ]
            // What the app did last, which a scenario's clean-up after the failure doesn't take away, each at the time
            // of day the run's events are on.
            let time = DateFormatter()
            time.dateFormat = "HH:mm:ss.SSS"
            state["activity"] = model.activity.events.suffix(24).map { event in
                "\(time.string(from: event.time)) \(event.kind.rawValue): \(event.text)"
                    + (event.count > 1 ? " ×\(event.count)" : "")
            }
            if let editor {
                var window = window(editor)
                window["firstResponder"] = editor.firstResponder.map(Views.describe) ?? "none"
                window["contentBounds"] = Views.describe(editor.contentView?.bounds ?? .zero)
                window["toolbarVisible"] = editor.toolbar?.isVisible ?? false
                window["split"] = splitItems(in: editor)
                state["editor"] = window
            }
            if let press = Views.lastPress {
                // What the press found then, and what's at the same place now.
                let now = editor?.contentView?.superview?.hitTest(press.location)
                state["lastPress"] = [
                    "kind": press.kind, "location": Views.describe(press.location), "window": press.window,
                    "found": press.found, "sentTo": press.sentTo,
                    "foundNow": Views.ancestry(now).joined(separator: " in "),
                    "secondsAgo": Date().timeIntervalSince(press.time),
                ]
            }
            return state
        }

        private static func window(_ window: NSWindow) -> [String: Any] {
            [
                "title": window.title,
                "class": "\(type(of: window))",
                "controller": window.windowController.map { "\(type(of: $0))" } ?? "none",
                "number": window.windowNumber,
                "level": window.level.rawValue,
                "frame": Views.describe(window.frame),
                "key": window.isKeyWindow,
                "main": window.isMainWindow,
                "sheet": window.isSheet,
                "attachedSheet": window.attachedSheet.map(Views.describe) ?? "none",
                "occlusionVisible": window.occlusionState.contains(.visible),
                "onActiveSpace": window.isOnActiveSpace,
                "fullScreen": window.styleMask.contains(.fullScreen),
                "alpha": Double(window.alphaValue),
                "ignoresMouseEvents": window.ignoresMouseEvents,
            ]
        }

        /// The split view's items, as AppKit has them, and where their views are in the window.
        private static func splitItems(in window: NSWindow) -> [[String: Any]] {
            let bounds = window.contentView?.bounds ?? .zero
            return Views.splitItems(in: window).map { item in
                let view = item.viewController.view
                let frame = view.convert(view.bounds, to: nil)
                return [
                    "behavior": item.behavior == .sidebar ? "sidebar" : item.behavior == .inspector ? "inspector"
                        : "content",
                    "collapsed": item.isCollapsed,
                    "frame": Views.describe(frame),
                    "inWindow": bounds.intersection(frame).width > 1,
                    "hidden": view.isHiddenOrHasHiddenAncestor,
                    "alpha": Double(view.alphaValue),
                ]
            }
        }
    }

    extension Views {
        /// The last press the driver sent, for a failure's record.
        struct Press {
            var kind: String
            var location: NSPoint
            var window: String
            /// What the window's hit test found under it.
            var found: String
            /// The view the events went to straight, or the window.
            var sentTo: String
            var time: Date
        }

        static var lastPress: Press?

        /// The panels and the canvas between them: the items of the window's split view.
        static func splitItems(in window: NSWindow) -> [NSSplitViewItem] {
            func controllers(_ controller: NSViewController) -> [NSViewController] {
                [controller] + controller.children.flatMap(controllers)
            }
            guard let root = window.contentViewController else { return [] }
            return controllers(root).lazy.compactMap { $0 as? NSSplitViewController }.first?.splitViewItems ?? []
        }

        static func describe(_ responder: NSResponder) -> String {
            if let window = responder as? NSWindow {
                return "\(type(of: window)) '\(window.title)' #\(window.windowNumber)"
            }
            if let text = responder as? NSTextView, text.isFieldEditor, let field = text.delegate as? NSView {
                return "the field editor of \(describe(field))"
            }
            guard let view = responder as? NSView else { return "\(type(of: responder))" }
            let identifier = view.accessibilityIdentifier()
            return identifier.isEmpty ? "\(type(of: view))" : "\(type(of: view)) \(identifier)"
        }

        /// A view and the views it's in, up to the first above it that carries an identifier.
        static func ancestry(_ view: NSView?) -> [String] {
            var chain: [String] = []
            var next = view
            while let view = next, chain.count < 12 {
                chain.append(describe(view))
                if !view.accessibilityIdentifier().isEmpty, chain.count > 1 {
                    break
                }
                next = view.superview
            }
            return chain.isEmpty ? ["nothing"] : chain
        }

        nonisolated static func describe(_ rect: NSRect) -> String {
            "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
        }

        nonisolated static func describe(_ point: NSPoint) -> String {
            "\(Int(point.x)),\(Int(point.y))"
        }
    }
#endif
