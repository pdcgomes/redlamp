import AppKit
import Carbon.HIToolbox
import RedlampDocument
import RedlampEngineAPI
import SwiftUI
import Testing
@testable import RedlampUI

/// The Export dialog on a window shorter than itself (#290): it fits on the window, and its
/// settings scroll to the last one above the Cancel and Export buttons.
@MainActor
struct ExportSheetTests {
    /// The dialog at `height`, in a window of its own.
    private func dialog(
        height: CGFloat, onCancel: @escaping () -> Void = {},
        onExport: @escaping (ExportSettings, UUID?, URL) -> Void = { _, _, _ in },
    ) async throws -> NSWindow {
        _ = NSApplication.shared
        let name = "ExportSheetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let sheet = ExportSheet(
            photo: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/IMG_0001.ARW"),
            photoSize: PixelSize(width: 6000, height: 4000), store: ExportPresetStore(defaults: defaults),
            height: height, onCancel: onCancel, onExport: onExport,
        )
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: ExportSheet.size.width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.contentViewController = NSHostingController(rootView: sheet)
        try await settle(window)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func views<T: NSView>(_: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(T.self, in: $0) }
    }

    private func key(_ code: Int, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code),
        ))
    }

    @Test func `a short dialog's settings scroll in one scroll view, down to the last setting`() async throws {
        let window = try await dialog(height: 560)
        defer { window.contentViewController = nil }
        let root = try #require(window.contentView)
        let hit = try #require(root.hitTest(NSPoint(x: root.bounds.midX, y: root.bounds.midY)))
        var scrollViews: [NSScrollView] = []
        var view: NSView? = hit
        while let next = view {
            if let scroll = next as? NSScrollView {
                scrollViews.append(scroll)
            }
            view = next.superview
        }
        // A scroll view inside another takes the scroll wheel from it, whether or not it has
        // anything to scroll.
        let scroll = try #require(scrollViews.first)
        #expect(scrollViews.count == 1, "\(scrollViews.count) scroll views under the pointer")
        let clip = scroll.contentView
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > clip.bounds.height + 200, "the settings are taller than the dialog")
        #expect(window.contentLayoutRect.contains(scroll.convert(scroll.bounds, to: nil)))

        let lowest = Self.views(NSControl.self, in: document).map { $0.convert($0.bounds, to: document) }
            .max { document.isFlipped ? $0.maxY < $1.maxY : $0.minY > $1.minY }
        let frame = try #require(lowest, "the settings have controls")
        #expect(!clip.documentVisibleRect.contains(frame), "the last setting starts out of view")
        document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
        try await settle(window)
        #expect(clip.documentVisibleRect.contains(frame), "\(frame) outside \(clip.documentVisibleRect)")
    }

    @Test func `the dialog fits on the editor window at its smallest, and keeps its height on a tall one`(
    ) async throws {
        let controller = EditorWindowController(
            model: EditorModel(engine: StubEngine()), theme: ThemeSettings(),
            onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        window.setContentSize(window.contentMinSize)
        window.orderFront(nil)
        try await settle(window)
        let height = window.sheetHeight(fitting: ExportSheet.size.height)
        #expect(height < ExportSheet.size.height, "the editor's smallest window is shorter than the dialog")

        let sheet = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: ExportSheet.size.width, height: height), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.beginSheet(sheet, completionHandler: nil)
        try await settle(sheet)
        #expect(window.frame.contains(sheet.frame), "\(sheet.frame) hangs past \(window.frame)")
        window.endSheet(sheet)

        // macOS keeps a window on screen within the screen, and CI's runner's is shorter than this.
        window.orderOut(nil)
        window.setContentSize(CGSize(width: 1600, height: 1000))
        try await settle(window)
        #expect(window.sheetHeight(fitting: ExportSheet.size.height) == ExportSheet.size.height)
    }

    @Test func `Return exports and Escape cancels a short dialog`() async throws {
        var exported: URL?
        var cancelled = false
        let window = try await dialog(
            height: 560, onCancel: { cancelled = true }, onExport: { _, _, url in exported = url },
        )
        defer { window.contentViewController = nil }
        let returnKey = try key(kVK_Return, "\r")
        let escapeKey = try key(kVK_Escape, "\u{1B}")
        #expect(window.performKeyEquivalent(with: returnKey))
        #expect(exported?.lastPathComponent == "IMG_0001-redlamp.jpg")
        #expect(window.performKeyEquivalent(with: escapeKey))
        #expect(cancelled)
    }

    /// Tab goes through every control or only the text fields, by the Mac's Keyboard
    /// Navigation setting; either way it ends on Resolution, below the fold.
    @Test func `Tab reaches the lowest field and scrolls it into view`() async throws {
        let window = try await dialog(height: 560)
        defer { window.contentViewController = nil }
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await settle(window)
        let root = try #require(window.contentView)
        let scroll = try #require(root.hitTest(NSPoint(x: root.bounds.midX, y: root.bounds.midY))?.enclosingScrollView)
        let document = try #require(scroll.documentView)
        let fields = Self.views(NSTextField.self, in: document).filter(\.isEditable)
        let lowest = try #require(fields.max { $0.convert($0.bounds, to: document).maxY < $1.convert(
            $1.bounds,
            to: document,
        ).maxY })
        #expect(!scroll.contentView.documentVisibleRect.contains(lowest.convert(lowest.bounds, to: document)))
        let tab = try key(kVK_Tab, "\t")
        var focused: NSTextField?
        for _ in 0 ..< 30 where focused !== lowest {
            window.sendEvent(tab)
            try await settle(window)
            focused = (window.firstResponder as? NSTextView)?.delegate as? NSTextField
        }
        #expect(focused === lowest)
        let frame = lowest.convert(lowest.bounds, to: document)
        #expect(
            scroll.contentView.documentVisibleRect.contains(frame),
            "\(frame) outside \(scroll.contentView.documentVisibleRect)",
        )
    }
}
