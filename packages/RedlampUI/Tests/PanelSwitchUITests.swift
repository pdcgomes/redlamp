import AppKit
import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Develop panels' switches (UX-30): a header's switch turns its panel off or on as one
/// History step, without expanding it.
@MainActor
struct PanelSwitchUITests {
    /// An open photo, and its Detail panel as the inspector builds it, in a window so the header
    /// follows the edit.
    private func openEditor() async throws -> (EditorModel, PanelSectionView, NSWindow, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        model.setValue(.sharpenAmount, 70)
        model.expandedPanels = []
        let panel = PanelSectionView(panel: .detail, model: model, rows: [NSView()])
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 316, height: 200), styleMask: [.borderless], backing: .buffered,
            defer: true,
        )
        window.contentView = panel
        return (model, panel, window, {
            window.contentView = nil
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private func panelSwitch(in panel: PanelSectionView) throws -> NSView {
        let header = try #require(panel.subviews.first { $0.accessibilityIdentifier() == "panel.detail.header" })
        return try #require(header.subviews.first { $0.accessibilityIdentifier() == "panel.detail.switch" })
    }

    private func click(_ view: NSView) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        ))
        view.mouseDown(with: event)
    }

    /// The header follows the edit on the next main-actor turn.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test func `clicking the switch turns the panel off in one step, without expanding it`() async throws {
        let (model, panel, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let toggle = try panelSwitch(in: panel)
        #expect(toggle.toolTip == "Turn Detail off")
        #expect(toggle.accessibilityLabel() == "Detail" && toggle.accessibilityRole() == .checkBox)
        let steps = model.history.count
        try click(toggle)
        #expect(!model.isOn(.detail))
        #expect(model.history.count == steps + 1 && model.history.last?.name == "Detail Off")
        #expect(model.expandedPanels.isEmpty, "the switch doesn't expand the panel")
        #expect(model.value(.sharpenAmount) == 70, "the panel keeps its settings")
        #expect(model.isEdited(.detail), "the edited dot still shows")
        try await settle()
        #expect(toggle.toolTip == "Turn Detail on")
        #expect(toggle.accessibilityValue() as? Int == 0)

        model.undo()
        #expect(model.isOn(.detail))
        model.redo()
        #expect(!model.isOn(.detail))
        try click(toggle)
        #expect(model.isOn(.detail) && model.history.last?.name == "Detail On")
    }

    @Test func `changing a setting of a panel that's off turns it on in that change's step`() async throws {
        let (model, _, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.setPanel(.detail, on: false)
        let steps = model.history.count
        model.setValue(.noiseLuminance, 30)
        #expect(model.isOn(.detail))
        #expect(model.history.count == steps + 1 && model.history.last?.title == ParameterID.noiseLuminance.displayName)
        model.undo()
        #expect(!model.isOn(.detail) && model.value(.noiseLuminance) == 0)

        model.setPanel(.toneCurve, on: false)
        model.setPointCurve([CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)])
        #expect(model.isOn(.toneCurve))
    }

    @Test func `resetting a panel from its header and Reset All turn it back on`() async throws {
        let (model, panel, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.setPanel(.detail, on: false)
        let header = try #require(panel.subviews.first { $0.accessibilityIdentifier() == "panel.detail.header" })
        let doubleClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 2, pressure: 1,
        ))
        header.mouseDown(with: doubleClick)
        #expect(model.isOn(.detail) && model.value(.sharpenAmount) == 40)
        #expect(model.history.last?.name == "Reset Detail")

        model.setPanel(.effects, on: false)
        model.setPanel(.lens, on: false)
        model.resetAll()
        #expect(model.panelsOff.isEmpty)

        // A panel already at its defaults still comes back on.
        model.setPanel(.calibration, on: false)
        model.resetPanel(.calibration)
        #expect(model.isOn(.calibration) && model.history.last?.name == "Reset Calibration")
    }

    @Test func `the header's menu turns the panel off and on`() async throws {
        let (model, panel, _, cleanup) = try await openEditor()
        defer { cleanup() }
        var menu = try #require(panel.headerMenu?())
        try menu.performActionForItem(at: #require(menu.items.firstIndex { $0.title == "Turn Detail Off" }))
        #expect(!model.isOn(.detail))
        menu = try #require(panel.headerMenu?())
        try menu.performActionForItem(at: #require(menu.items.firstIndex { $0.title == "Turn Detail On" }))
        #expect(model.isOn(.detail))
    }

    @Test func `Basic has no switch, and every other panel's settings are its switch's`() {
        let model = EditorModel(engine: StubEngine())
        #expect(PanelID.basic.switchable == nil && model.isOn(.basic))
        model.setPanel(.basic, on: false)
        #expect(model.history.count <= 1, "Basic can't be turned off")
        let basic = PanelSectionView(panel: .basic, model: model, rows: [])
        let header = basic.subviews.first { $0.accessibilityIdentifier() == "panel.basic.header" }
        #expect(header?.subviews.isEmpty == true)
        for panel in PanelID.allCases where panel != .basic {
            let switchable = panel.switchable
            #expect(switchable != nil, "\(panel)")
            #expect(Set(panel.parameters).isSubset(of: switchable?.parameters ?? []), "\(panel)")
            #expect(switchable?.name == panel.title)
        }
    }
}
