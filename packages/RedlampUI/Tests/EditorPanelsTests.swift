import AppKit
import Testing
@testable import RedlampUI

/// The editor's panel columns, as its split view lays them out from the model's visibility.
@MainActor
struct EditorPanelsTests {
    /// Hidden and shown again while the window can't be seen (behind another window, or on a display
    /// that sleeps), the panels are back on the window, not left where they slide in from.
    @Test func `panels hidden and shown again while the window is covered come back onto it`() async throws {
        _ = NSApplication.shared
        let model = EditorModel(engine: StubEngine())
        let controller = EditorWindowController(
            model: model, theme: ThemeSettings(), onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        window.orderFront(nil)
        let cover = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.level = .floating
        cover.backgroundColor = .black
        cover.orderFrontRegardless()
        defer {
            cover.orderOut(nil)
            window.orderOut(nil)
        }
        // Where the window server doesn't report the window covered, the panels slide as on screen.
        for _ in 0 ..< 300 where window.occlusionState.contains(.visible) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))

        // As the regression suite's checks of Tab and F7 do: both panels hidden and shown, then the left.
        model.leftPanelVisible = false
        model.rightPanelVisible = false
        try await Task.sleep(for: .milliseconds(100))
        model.leftPanelVisible = true
        model.rightPanelVisible = true
        try await Task.sleep(for: .milliseconds(500))
        model.leftPanelVisible = false
        try await Task.sleep(for: .milliseconds(100))
        model.leftPanelVisible = true
        try await Task.sleep(for: .milliseconds(1000))

        let bounds = try #require(window.contentView?.bounds)
        let panels = try splitItems(of: window).filter { $0.behavior != .default }
        #expect(panels.count == 2)
        for item in panels {
            let view = item.viewController.view
            let frame = view.convert(view.bounds, to: nil)
            #expect(!item.isCollapsed)
            #expect(
                bounds.contains(frame),
                "\(item.behavior == .sidebar ? "the sidebar" : "the inspector") at \(frame)",
            )
        }
        #expect(model.leftPanelVisible && model.rightPanelVisible)
    }

    private func splitItems(of window: NSWindow) throws -> [NSSplitViewItem] {
        func controllers(_ controller: NSViewController) -> [NSViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        let root = try #require(window.contentViewController)
        let split = try #require(controllers(root).lazy.compactMap { $0 as? NSSplitViewController }.first)
        return split.splitViewItems
    }
}
