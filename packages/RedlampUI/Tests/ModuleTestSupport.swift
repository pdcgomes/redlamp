import AppKit
import CoreGraphics
import Foundation
import RedlampDocument
import Synchronization
@testable import RedlampUI

/// A folder of photos open in an editor, with the window's module views around it, for the module and grid
/// tests. Thumbnails are made, and counted, by a closure of its own.
@MainActor
final class ModuleFixture {
    let folder = FileManager.default.temporaryDirectory.appending(path: "modules-\(UUID().uuidString)")
    let packs = FileManager.default.temporaryDirectory.appending(path: "modules-packs-\(UUID().uuidString)")
    let engine = StubEngine()
    /// Thumbnails decoded from the photos.
    let decoded = Counter()
    let model: EditorModel
    private(set) var photos: [URL] = []
    /// The module views shown, kept as the window's split view keeps them.
    private(set) var shown: [ModuleWindow] = []

    final class Counter: Sendable {
        private let count = Mutex(0)

        var value: Int {
            count.withLock { $0 }
        }

        func increment() {
            count.withLock { $0 += 1 }
        }
    }

    init() {
        let decoded = decoded
        let loader = ThumbnailLoader(packs: ThumbnailPacks(directory: packs)) { _, size in
            decoded.increment()
            return Self.image(size)
        }
        model = EditorModel(engine: engine, thumbnailLoader: loader)
        _ = NSApplication.shared
    }

    nonisolated static func image(_ size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: size, height: size * 2 / 3, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { return nil }
        return context.makeImage()
    }

    /// Opens a folder of `count` photos, the first selected and open.
    func open(count: Int, subfolder: Int = 0) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..< count {
            let url = folder.appending(path: String(format: "IMG_%05d.ARW", index))
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
            photos.append(url)
        }
        if subfolder > 0 {
            let below = folder.appending(path: "Below")
            try FileManager.default.createDirectory(at: below, withIntermediateDirectories: true)
            for index in 0 ..< subfolder {
                FileManager.default.createFile(
                    atPath: below.appending(path: String(format: "SUB_%05d.ARW", index)).path, contents: Data([1]),
                )
            }
        }
        model.open([folder])
        try await eventually { self.model.library.count == count && self.model.info?.url == self.photos.first }
    }

    /// The window's middle and both side panels as the app builds them, with a plain view for Develop's
    /// middle (its canvas is Metal's), in a window of their own.
    func showModules() -> ModuleWindow {
        let content = ModuleContentController(
            model: model, theme: ThemeSettings(), develop: PlainViewController(),
        )
        let left = ModuleColumnView(
            model: model, develop: SidebarColumnView(model: model), library: LibraryFoldersColumn(model: model),
        )
        let right = ModuleColumnView(
            model: model, develop: InspectorColumnView(model: model), library: LibraryInfoColumn(model: model),
        )
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        content.view.frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        left.frame = CGRect(x: 0, y: 0, width: 250, height: 900)
        right.frame = CGRect(x: 1284, y: 0, width: 316, height: 900)
        for view in [content.view, left, right] {
            root.addSubview(view)
        }
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.contentView = root
        window.makeFirstResponder(content.view)
        root.layoutSubtreeIfNeeded()
        let modules = ModuleWindow(window: window, content: content, left: left, right: right)
        shown.append(modules)
        return modules
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A turn of the main run loop, for the views' trackers to follow the model.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    func cleanUp() {
        for modules in shown {
            modules.window.contentView = nil
        }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: packs)
    }
}

@MainActor
struct ModuleWindow {
    let window: NSWindow
    let content: ModuleContentController
    let left: ModuleColumnView
    let right: ModuleColumnView

    var grid: LibraryGridView {
        content.library.grid
    }

    /// Every view the modules are made of, by identity: none is made again by a switch.
    var identities: [ObjectIdentifier] {
        [
            content.view, content.developView, content.library, content.library.grid, content.library.loupe,
            content.library.grid.content, content.library.toolbar, left.develop, left.library, right.develop,
            right.library,
        ].map(ObjectIdentifier.init)
    }
}

final class PlainViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 900))
    }
}
