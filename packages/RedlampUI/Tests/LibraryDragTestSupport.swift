import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// A folder of small JPEGs on the external disk's scratch folder, indexed and shown from the library in Library's
/// grid, with the left and right columns beside it in a window, for Library's drags (LIB-21, LIB-23, LIB-26): drags
/// follow a synthetic mouse through the window as the regression suite's do (`SimulatedDrag`). Removed with what it
/// made.
@MainActor
final class DragSandbox {
    let base = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
        .appending(path: "drags-\(UUID().uuidString)", directoryHint: .isDirectory)
    /// Folders' choices, in a suite of their own that goes with the sandbox.
    let suite = "drags-\(UUID().uuidString)"
    private(set) lazy var defaults = UserDefaults(suiteName: suite)
    private(set) var library: FolderLibrary!
    private(set) var service: LibraryService!
    private(set) var model: EditorModel!
    private(set) var modules: ModuleWindow?

    var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    func photo(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    func folder(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .isDirectory)
    }

    var grid: LibraryGridView {
        modules!.grid
    }

    var window: NSWindow {
        modules!.window
    }

    /// Writes `photos` directly in the root and makes the empty `folders` in it, indexes them, opens the root in
    /// Library's grid, its own photos alone, and shows the window with Folders' rows open.
    func open(photos: [String], folders: [String] = []) async throws {
        LibraryDrags.simulates = true
        for path in folders {
            try FileManager.default.createDirectory(at: folder(path), withIntermediateDirectories: true)
        }
        try writePhotos(photos)
        library = FolderLibrary(defaults: defaults)
        library.setIncludesSubfolders(false)
        library.add([root])
        service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars,
        ) { url, size in StoreThumbnailMaker.imageIO(url, nil, size) }
        library.attach(service)
        try await SourcesSandbox.eventually { await self.service.canShow(self.root, includingSubfolders: false) }
        model = EditorModel(engine: StubEngine(), library: library)
        model.open([root])
        try await eventually { self.library.isShownFromLibrary && self.model.items.count == photos.count }
        try #require(library.isShownFromLibrary && model.items.count == photos.count, "the root shown from the library")
        library.setExpanded(root, true)
        model.showModule(.library)
        modules = show()
        try await eventually { folders.allSatisfy { self.view("folders." + self.folder($0).path) != nil } }
        try #require(folders.allSatisfy { view("folders." + folder($0).path) != nil }, "Folders lists the folders")
        layOut()
        try await eventually { self.grid.cells.count == photos.count }
    }

    /// Lays the window out, as its display cycle would: the columns size their documents to their rows.
    func layOut() {
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Small JPEGs at `paths` below the root, each its own colour, so each has its own content key.
    func writePhotos(_ paths: [String], from first: Int = 0) throws {
        for (offset, path) in paths.enumerated() {
            let url = photo(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try SourcesSandbox.jpeg(number: first + offset).write(to: url)
        }
    }

    /// The window's middle between both side panels, as the app builds them.
    private func show() -> ModuleWindow {
        let content = ModuleContentController(model: model, theme: ThemeSettings(), develop: PlainViewController())
        let left = ModuleColumnView(
            model: model, develop: SidebarColumnView(model: model), library: LibraryFoldersColumn(model: model),
        )
        let right = ModuleColumnView(
            model: model, develop: InspectorColumnView(model: model), library: LibraryInfoColumn(model: model),
        )
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let root = NSView(frame: frame)
        content.view.frame = CGRect(x: 250, y: 0, width: 1034, height: 900)
        left.frame = CGRect(x: 0, y: 0, width: 250, height: 900)
        right.frame = CGRect(x: 1284, y: 0, width: 316, height: 900)
        for view in [content.view, left, right] {
            root.addSubview(view)
        }
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        window.makeFirstResponder(content.view)
        root.layoutSubtreeIfNeeded()
        return ModuleWindow(window: window, content: content, left: left, right: right)
    }

    func close() {
        modules?.window.contentView = nil
        LibrarySandbox.remove(base, closing: [service])
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// Waits for the panels' changes asked for to be made, then counts the library again until `condition` holds:
    /// what changed reaches the query engine a moment after its batch.
    func made(seconds: Double = 30, until condition: (LibrarySources) -> Bool) async throws {
        await model.libraryPanels.written()
        let sources = model.librarySources
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            await service.settled()
            sources.recount()
            await sources.counted()
            if condition(sources) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func eventually(seconds: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Views

    /// The view on screen carrying `identifier`: the module not shown stays in place, transparent.
    func view(_ identifier: String) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            guard !view.isHidden, view.alphaValue > 0 else { return nil }
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            return view.subviews.lazy.compactMap(search).first
        }
        return modules.flatMap { $0.window.contentView.map(search) } ?? nil
    }

    /// The first view of type `T` on screen.
    func first<T: NSView>(_: T.Type) -> T? {
        func search(_ view: NSView) -> T? {
            guard !view.isHidden, view.alphaValue > 0 else { return nil }
            if let match = view as? T {
                return match
            }
            return view.subviews.lazy.compactMap(search).first
        }
        return modules.flatMap { $0.window.contentView.map(search) } ?? nil
    }

    /// The middle of the view carrying `identifier`, in the window.
    func middle(of identifier: String) throws -> CGPoint {
        let found = try #require(view(identifier), "\(identifier) is in the window")
        let frame = found.convert(found.bounds, to: nil)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The middle of `name`'s cell in the grid, in the window.
    func cell(_ name: String) throws -> CGPoint {
        let row = try #require(library.index(of: photo(name)), "\(name) is in the grid")
        let frame = grid.gridLayout.frame(forItem: row)
        return grid.content.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    // MARK: - The mouse

    func mouse(
        _ type: NSEvent.EventType, at location: CGPoint, modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1,
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1,
        ))
    }

    /// Presses `name` in the grid, as `modifiers` say, without letting go.
    func press(_ name: String, modifiers: NSEvent.ModifierFlags = []) throws {
        try grid.content.mouseDown(with: mouse(.leftMouseDown, at: cell(name), modifiers: modifiers))
    }

    /// Clicks `name` in the grid.
    func click(_ name: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let location = try cell(name)
        try grid.content.mouseDown(with: mouse(.leftMouseDown, at: location, modifiers: modifiers))
        try grid.content.mouseUp(with: mouse(.leftMouseUp, at: location, modifiers: modifiers))
    }

    /// Moves the press on the grid to `end`, in steps, holding `modifiers`, as the mouse does; with `release`, lets
    /// go there.
    func drag(
        from start: CGPoint, to end: CGPoint, modifiers: NSEvent.ModifierFlags = [], release: Bool = true,
    ) throws {
        for step in 1 ... 8 {
            let t = CGFloat(step) / 8
            let location = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            try grid.content.mouseDragged(with: mouse(.leftMouseDragged, at: location, modifiers: modifiers))
        }
        if release {
            try grid.content.mouseUp(with: mouse(.leftMouseUp, at: end, modifiers: modifiers))
        }
    }

    /// Lets go of the press at `location`.
    func release(at location: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws {
        try grid.content.mouseUp(with: mouse(.leftMouseUp, at: location, modifiers: modifiers))
    }

    /// Presses `view` in its middle and moves the press to `end` in steps, holding `modifiers`; with `release`, lets
    /// go there. The events go to `view`, as the window sends a press's drags and release to the view it pressed.
    func drag(
        _ view: NSView, to end: CGPoint, modifiers: NSEvent.ModifierFlags = [], release: Bool = true,
    ) throws {
        let frame = view.convert(view.bounds, to: nil)
        let start = CGPoint(x: frame.midX, y: frame.midY)
        try view.mouseDown(with: mouse(.leftMouseDown, at: start, modifiers: modifiers))
        for step in 1 ... 8 {
            let t = CGFloat(step) / 8
            let location = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            try view.mouseDragged(with: mouse(.leftMouseDragged, at: location, modifiers: modifiers))
        }
        if release {
            try view.mouseUp(with: mouse(.leftMouseUp, at: end, modifiers: modifiers))
        }
    }

    /// Waits for the panels' changes asked for, the lists holding them and the panels showing them.
    func panelsWritten() async throws {
        await model.libraryPanels.written()
        await service.settled()
        try await Task.sleep(for: .milliseconds(30))
        await model.libraryPanels.refreshed()
        await model.libraryPanels.keywordsRead()
    }

    /// The keywords `name`'s sidecar holds, sorted.
    func keywords(_ name: String) -> [String] {
        (SidecarStore().load(for: photo(name))?.metadata?.keywords ?? []).sorted()
    }

    // MARK: - Files

    /// The files directly in the folder at `path` below the root ("" for the root), sorted.
    func files(in path: String = "") -> [String] {
        let url = path.isEmpty ? root : folder(path)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func shownNames() -> [String] {
        model.items.map(\.name)
    }

    /// Returns once the file steps asked for are made.
    func filesMade(count: Int) async throws {
        try await eventually { self.model.fileUndoCount + self.model.fileRedoCount >= count }
        await model.filesMade()
    }

    /// Clicks the grid's toolbar's Stop, beside a batch's progress.
    func pressStop() throws {
        let stop = try #require(view("library.toolbar.stop"), "the toolbar shows Stop")
        let frame = stop.convert(stop.bounds, to: nil)
        try stop.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: frame.midX, y: frame.midY)))
    }

    /// Runs `body`, then removes what the library's batches left in the Trash, the real one, whatever `body` did.
    func emptyingTrash(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await emptyTrash()
            throw error
        }
        await emptyTrash()
    }

    private func emptyTrash() async {
        await model.filesMade()
        for place in await service.trashedPlaces() {
            try? FileManager.default.removeItem(atPath: place)
        }
    }
}
