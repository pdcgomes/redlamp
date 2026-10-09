import AppKit
import Foundation
import RedlampCanvas
import RedlampEngineAPI
import SwiftUI
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

    /// #358: Tab hides the side panels for a bigger view of the photo, as in Lightroom. At Fit the photo
    /// grows into the room they leave and is rendered again at its new size; F7 and F8 give one side's.
    @Test func `hiding the side panels gives the photo their room, rendered again at its new size`() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.pixelSize = PixelSize(width: 6000, height: 4000)
        let model = EditorModel(engine: engine)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1400, height: 640), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: EditorContentView(model: model, theme: ThemeSettings(), onOpen: {}),
        )
        defer { window.contentView = nil }
        model.select(folder.appending(path: "IMG_0001.ARW"))
        let canvas = model.canvas
        func eventually(_ condition: () -> Bool) async throws {
            for _ in 0 ..< 400 where !condition() {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        /// At Fit, rendered at the size the stage needs.
        func rendered() -> Bool {
            engine.lastRender?.targetSize == canvas.renderTarget.size
        }

        try await eventually {
            canvas.imageSize == engine.pixelSize && canvas.viewSize.width > 0 && canvas.stageInsets.leading > 0
                && rendered()
        }
        let shown = canvas.stageInsets
        let fit = canvas.imageRect(in: canvas.viewSize)
        let size = canvas.renderTarget.size
        #expect(shown.leading == PanelMetrics.inset + PanelMetrics.sidebarNominal + PanelMetrics.inset)
        #expect(shown.trailing == PanelMetrics.inspectorNominal + PanelMetrics.inset)

        #expect(model.perform(.toggleSidePanels))
        try await eventually { canvas.stageInsets != shown && rendered() }
        #expect(!model.leftPanelVisible && !model.rightPanelVisible)
        #expect(canvas.stageInsets == StageInsets(
            leading: PanelMetrics.inset, trailing: PanelMetrics.inset, top: shown.top, bottom: shown.bottom,
        ))
        let grown = canvas.imageRect(in: canvas.viewSize)
        let stage = canvas.stage(in: canvas.viewSize)
        #expect(grown.width > fit.width && grown.height > fit.height, "\(grown.size), from \(fit.size)")
        #expect(abs(grown.width - stage.width) < 0.5 || abs(grown.height - stage.height) < 0.5, "it fills the stage")
        #expect(rendered() && canvas.renderTarget.size.width > size.width, "rendered at \(canvas.renderTarget.size)")

        #expect(model.perform(.toggleSidePanels))
        try await eventually { canvas.stageInsets == shown && rendered() }
        #expect(canvas.imageRect(in: canvas.viewSize) == fit, "Tab again gives the panels their room back")
        #expect(canvas.renderTarget.size == size)

        #expect(model.perform(.toggleLeftPanel))
        try await eventually { canvas.stageInsets != shown }
        #expect(canvas.stageInsets.leading == PanelMetrics.inset && canvas.stageInsets.trailing == shown.trailing)
        #expect(model.perform(.toggleLeftPanel))
        #expect(model.perform(.toggleRightPanel))
        try await eventually { canvas.stageInsets.trailing != shown.trailing }
        #expect(canvas.stageInsets.leading == shown.leading && canvas.stageInsets.trailing == PanelMetrics.inset)
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
