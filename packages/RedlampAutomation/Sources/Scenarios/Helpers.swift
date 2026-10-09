#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import ImageIO
    import RedlampDocument
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI
    import Synchronization

    /// What the app owns that scenarios need beside the editor: its theme and its export presets.
    public struct AutomationHost: @unchecked Sendable {
        public let theme: ThemeSettings
        public let exports: ExportPresetStore

        public init(theme: ThemeSettings, exports: ExportPresetStore) {
            self.theme = theme
            self.exports = exports
        }
    }

    final class Flag: Sendable {
        private let value = Mutex(false)
        func set() {
            value.withLock { $0 = true }
        }

        var isSet: Bool {
            value.withLock { $0 }
        }
    }

    extension RunningApp {
        /// Runs the model's async work on the main thread and waits for it to finish.
        func run(
            _ what: String,
            timeout: Double = 60,
            _ work: @escaping @MainActor (EditorModel) async -> Void,
        ) throws {
            let done = Flag()
            post { model in
                Task { @MainActor in
                    await work(model)
                    done.set()
                }
            }
            try wait(what, timeout: timeout) { _ in done.isSet }
        }

        /// Waits until the canvas is laid out with the photo shown, so zooming has steps to take and
        /// showing the photo no longer resets the zoom.
        func waitForCanvas() throws {
            try wait("the canvas laid out with the photo") { model in
                model.canvas.viewSize.width > 0 && model.canvas.imageSize.width > 0 && model.hasFrame
            }
            pause(0.2)
        }

        func openWorking() throws {
            try open(workingPhoto())
        }

        /// Opens a raw other than the working one, for a photo's own state.
        func openRaw(_ index: Int) throws {
            let raws = ["arw", "raf", "cr3", "nef", "dng"]
            try wait("the folder's photos", timeout: 30) { !$0.items.isEmpty }
            let names = try photoNames().filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }
            guard !names.isEmpty else { throw ScenarioFailure("The folder has no raws") }
            try open(names[index % names.count])
        }

        /// Runs `change` and waits for the frame it causes.
        func expectRenders(_ what: String, _ change: () throws -> Void) throws {
            let before = try frames()
            try change()
            try expectRendered(after: before, what)
        }

        /// Sets a parameter as a scenario's set-up, and waits for the frame.
        func set(_ parameter: ParameterID, _ value: Double) throws {
            if try abs(self.value(parameter) - value) < 1e-9 {
                return
            }
            try expectRenders("\(parameter.spec.label) at \(value)") {
                try main { $0.setSliderValue(parameter, value) }
            }
        }

        /// Draws a gradient on the photo: dragged on the canvas when the run allows focus
        /// (SwiftUI gestures need a key window), otherwise through the shape the drag would make.
        func drawGradient(_ kind: MaskKind, operation: MaskOperation = .add, addingTo target: UUID? = nil) throws {
            if target == nil {
                try press(kind == .linear ? .linearMask : .radialMask)
            } else {
                try main { $0.startDrawing(kind, operation: operation, addingTo: target) }
            }
            try drawArmedGradient(kind)
        }

        /// Draws the gradient a key, a menu or the Masks panel's picker armed, as `drawGradient` does.
        func drawArmedGradient(_ kind: MaskKind) throws {
            let before = try main { $0.masks.flatMap(\.components).count }
            if try focus() {
                try drag(.canvas, from: CGPoint(x: 0.45, y: 0.35), by: CGVector(dx: 60, dy: -80))
                covered(.mask(kind), via: .mouse)
            } else {
                try main { model in
                    let shape: MaskShape = kind == .linear
                        ? .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0.2), end: ImagePoint(x: 0.5, y: 0.6)))
                        : .radial(RadialMask(
                            center: ImagePoint(x: 0.5, y: 0.5),
                            radiusX: 0.2,
                            radiusY: 0.15,
                            feather: 50,
                        ))
                    model.beginDrawing(shape)
                    model.finishDrawing()
                }
                covered(.mask(kind), via: .model)
            }
            do {
                try wait("the \(kind) gradient to be drawn") { $0.masks.flatMap(\.components).count > before }
            } catch {
                let state = try main { model in
                    "tool \(model.activeTool), armed \(String(describing: model.drawingKind)), \(model.masks.count) masks, "
                        + "\(model.selection?.lastPathComponent ?? "no photo"), read-only \(model.isReadOnly), "
                        + "first responder \(Views.editorWindow?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none")"
                }
                throw ScenarioFailure("\(error) (\(state))")
            }
        }

        /// The file `url` holds: its type, size, bits per component and colour space name.
        func imageProperties(_ url: URL) -> (type: String, width: Int, height: Int, depth: Int, space: String)? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return (type, image.width, image.height, image.bitsPerComponent, (image.colorSpace?.name as String?) ?? "")
        }

        /// Exports the open photo with `settings` to the run's exports folder, through the
        /// editor's own export.
        func export(_ settings: ExportSettings, as name: String) throws -> URL {
            let folder = runDirectory.appending(path: "exports")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "\(name).\(settings.format.fileExtension)")
            try? FileManager.default.removeItem(at: url)
            let failure = Mutex<String?>(nil)
            try run("the \(name) export", timeout: 120) { model in
                do {
                    try await model.export(settings, to: url)
                } catch {
                    failure.withLock { $0 = "\(error)" }
                }
            }
            if let message = failure.withLock({ $0 }) {
                throw ScenarioFailure("Exporting \(name) failed: \(message)")
            }
            try expect(FileManager.default.fileExists(atPath: url.path), "\(name) wasn't written")
            return url
        }

        /// A key in the open command palette, through the handler its key events call (the
        /// palette takes keys only through its focused field, which a background window lacks).
        func paletteKey(_ key: PaletteKey) throws {
            let handled = try main { $0.commandPalette?.handle(key) ?? false }
            try expect(handled, "The palette didn't take \(key)")
            pause(0.15)
        }

        /// Runs `action` from the command palette, as a person without its key would.
        func runFromPalette(_ action: ShortcutAction) throws {
            let mark = try mark()
            try press(.commandPalette)
            try wait("the palette") { $0.commandPalette != nil }
            try main { $0.commandPalette?.setText(action.title) }
            pause(0.3)
            try paletteKey(.submit)
            try expectPerformed(action, since: mark)
            covered(.action(action), via: .palette)
            if try main({ $0.commandPalette != nil }) {
                try paletteKey(.escape)
            }
        }

        /// The name of every window but the editor's that's on screen.
        func otherWindows() throws -> [String] {
            try main { _ in
                NSApp.windows.filter { $0.isVisible && !($0.windowController is EditorWindowController) && !$0.isSheet }
                    .map(\.title)
            }
        }
    }
#endif
