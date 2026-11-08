import AppKit
import CoreGraphics
import RedlampCanvas
import Testing
@testable import RedlampUI

/// Cropping fits the photo a little smaller, so its corner handles can't reach the toolbar, where
/// a drag moves the window, or the window's edges, where it resizes it.
struct CropStageTests {
    private static func stageInsets(cropping: Bool, panels: Bool = false, presenting: Bool = false) -> StageInsets {
        PanelMetrics.stageInsets(
            toolbarHeight: 52, presenting: presenting, leftPanel: panels, rightPanel: panels, filmstrip: nil,
            cropping: cropping,
        )
    }

    @Test func `the crop handles' click areas stop short of the toolbar and the window's edges`() {
        let insets = Self.stageInsets(cropping: true)
        #expect(insets.top - CropOverlayView.cornerClickReach > 52)
        #expect(insets.leading > CropOverlayView.cornerClickReach)
        #expect(insets.trailing > CropOverlayView.cornerClickReach)
        #expect(insets.bottom > CropOverlayView.cornerClickReach)
    }

    @Test func `cropping keeps the panels' width, moving only the gaps to the toolbar and the edges`() {
        let insets = Self.stageInsets(cropping: true, panels: true)
        let editing = Self.stageInsets(cropping: false, panels: true)
        let extra = PanelMetrics.cropClearance - PanelMetrics.inset
        #expect(insets.top == editing.top + PanelMetrics.cropClearance)
        #expect(insets.leading == editing.leading + extra)
        #expect(insets.trailing == editing.trailing + extra)
        #expect(insets.bottom == editing.bottom + extra)
    }

    @Test func `presenting still gives the photo the whole window`() {
        #expect(Self.stageInsets(cropping: true, presenting: true) == .zero)
    }

    @MainActor
    @Test func `the editor shrinks the stage on entering the crop tool and restores it on leaving`() async throws {
        _ = NSApplication.shared
        let model = EditorModel(engine: StubEngine())
        let controller = EditorWindowController(
            model: model, theme: ThemeSettings(), onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let editing = model.canvas.stageInsets

        model.activeTool = .crop
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.canvas.stageInsets.top == editing.top + PanelMetrics.cropClearance)

        model.activeTool = .edit
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.canvas.stageInsets == editing)
    }
}
