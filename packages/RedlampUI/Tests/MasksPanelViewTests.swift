import AppKit
import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Masking tool's panels in AppKit keep their rows while masks change, put the pickers and
/// messages where the design has them, collapse by their headers, keep their column measured, and
/// end a row's preview with the row.
@MainActor
struct MasksPanelViewTests {
    /// An editor with a photo open, in a temporary folder its sidecar can be written to.
    private func openEditor() async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        model.activeTool = .masking
        return (model, { try? FileManager.default.removeItem(at: folder) })
    }

    private func window(_ content: NSView, height: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 316, height: height), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        return window
    }

    /// Lets the panel's tracker, and SwiftUI inside its rows, catch up.
    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 12 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The Masks panel's rows above its last, New Mask and Mask Presets.
    private func content(_ masks: PanelSectionView) -> [NSView] {
        Array(masks.rows.dropLast())
    }

    private func draw(_ x: Double, in model: EditorModel, window: NSWindow) async throws {
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: x, y: 0.5), radiusX: 0.1, radiusY: 0.1)))
        model.finishDrawing()
        try await settle(window)
    }

    @Test func `the Masks panel keeps its rows as masks are drawn and selected`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await settle(window)
        let masks = panel.masksPanel
        #expect(panel.arrangedViews.elementsEqual([masks], by: ===), "with no masks, the Masks panel alone")
        let newMask = try #require(masks.rows.last)
        #expect(content(masks).count == 1, "holding the picker")
        let picker = try #require(content(masks).first)

        try await draw(0.3, in: model, window: window)
        let first = try #require(model.selectedMaskID)
        let panels = panel.arrangedViews
        #expect(panels.count == 3, "Masks, the mask's own panel and its Adjustments")
        #expect(panels.first === masks, "the Masks panel outlives the first mask")
        #expect(content(masks).count == 1 && content(masks).first !== picker, "the list takes the picker's place")
        let list = try #require(content(masks).first)
        let firstEditor = Array(panels.dropFirst())

        try await draw(0.7, in: model, window: window)
        #expect(panel.arrangedViews.first === masks && content(masks).first === list, "the Masks panel and its list")
        #expect(panel.arrangedViews[1] !== firstEditor[0], "the new mask gets its own panels")

        model.selectMask(first)
        try await settle(window)
        #expect(panel.arrangedViews.dropFirst().elementsEqual(firstEditor, by: ===), "going back reuses its panels")

        let second = try #require(model.maskOutlines.last?.id)
        model.selectMask(second)
        try await settle(window)
        let secondEditor = Array(panel.arrangedViews.dropFirst())
        model.toggleMaskVisibility(second)
        try await settle(window)
        #expect(panel.arrangedViews.dropFirst().elementsEqual(secondEditor, by: ===), "hiding the mask keeps them")
        model.setMaskInverted(second, true)
        try await settle(window)
        #expect(panel.arrangedViews.dropFirst().elementsEqual(secondEditor, by: ===), "inverting the whole mask too")

        model.renameMask(second, to: "Renamed")
        try await settle(window)
        let renamedEditor = try #require(panel.arrangedViews.dropFirst().first)
        #expect(renamedEditor !== secondEditor[0], "renaming the mask rebuilds the panel titled with its name")

        let component = try #require(model.selectedOutline?.components.first?.id)
        model.setComponentInverted(component, in: second, true)
        try await settle(window)
        let invertedEditor = try #require(panel.arrangedViews.dropFirst().first)
        #expect(invertedEditor !== renamedEditor, "inverting a component rebuilds them")

        model.deleteMask(second)
        try await settle(window)
        model.undo()
        try await settle(window)
        model.selectMask(second)
        try await settle(window)
        #expect(
            panel.arrangedViews.dropFirst().first !== invertedEditor,
            "a deleted mask's panels are rebuilt after undo",
        )

        model.selectMask(nil)
        try await settle(window)
        #expect(panel.arrangedViews.elementsEqual([masks], by: ===), "with no mask selected, the Masks panel alone")
        #expect(content(masks).count == 2 && content(masks).first === list, "saying under the list to select one")

        model.deleteAllMasks()
        try await settle(window)
        #expect(panel.arrangedViews.elementsEqual([masks], by: ===))
        #expect(content(masks).elementsEqual([picker], by: ===), "the picker comes back")
        #expect(masks.rows.last === newMask, "above New Mask, which stays throughout")
    }

    @Test func `choosing an effect moves the mask's sliders and keeps its settings`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await draw(0.5, in: model, window: window)
        let mask = try #require(model.selectedMaskID)
        let panels = panel.arrangedViews
        let dodge = try #require(MaskEffect.builtIn.first { $0.name == "Dodge" })

        model.applyMaskEffect(dodge, to: mask)
        try await settle(window)
        #expect(model.sliderValue(.localExposure) == 0.35)
        #expect(panel.arrangedViews.elementsEqual(panels, by: ===), "an effect changes only the sliders' values")
        model.undo()
        try await settle(window)
        #expect(model.sliderValue(.localExposure) == 0)
        #expect(panel.arrangedViews.elementsEqual(panels, by: ===))
    }

    @Test func `the drawing hint, messages and the pickers go where the design has them`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await draw(0.4, in: model, window: window)
        let masks = panel.masksPanel
        let list = try #require(content(masks).first)
        let mask = try #require(model.selectedMaskID)

        model.startDrawing(.brush, addingTo: mask)
        try await settle(window)
        #expect(content(masks).count == 2 && content(masks)[1] === list, "the hint at the top of the Masks panel")
        model.cancelDrawing()
        try await settle(window)
        #expect(content(masks).elementsEqual([list], by: ===))

        model.maskMessage = "Sky masks need a photo with sky in it."
        try await settle(window)
        #expect(content(masks).count == 2 && content(masks)[1] === list, "the message is at the top of the list")
        model.maskMessage = nil
        try await settle(window)

        let panels = panel.arrangedViews
        model.openPeoplePicker(.new)
        try await settle(window)
        #expect(panel.arrangedViews.elementsEqual([masks], by: ===), "the People picker puts the mask's panels away")
        #expect(content(masks).count == 1 && content(masks).first !== list, "and takes the list's place")
        model.closePeoplePicker()
        try await settle(window)
        #expect(panel.arrangedViews.elementsEqual(panels, by: ===), "and gives them back, the mask's kept")
        #expect(content(masks).elementsEqual([list], by: ===))

        model.openLandscapePicker(.component(.add, target: mask))
        try await settle(window)
        #expect(panel.arrangedViews.elementsEqual([masks], by: ===), "the Landscape picker puts them away")
        #expect(content(masks).count == 1 && content(masks).first !== list, "and takes the list's place")
        model.closeLandscapePicker()
        try await settle(window)
        #expect(panel.arrangedViews.elementsEqual(panels, by: ===), "and gives them back")
    }

    @Test func `the panels collapse by their headers, and the Masks panel opens for what it has to show`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await draw(0.4, in: model, window: window)
        let mask = try #require(model.selectedMaskID)
        let header = Metrics.panelHeaderHeight
        let cards = panel.arrangedViews.compactMap { $0 as? PanelSectionView }
        #expect(cards.count == 3 && cards.allSatisfy { $0.height(forWidth: 300) > header }, "all three open")

        model.toggleMaskPanel(.adjustments, solo: false)
        try await settle(window)
        #expect(cards[2].height(forWidth: 300) == header, "Adjustments collapsed to its header")
        #expect(cards[1].height(forWidth: 300) > header)
        model.toggleMaskPanel(.mask, solo: true)
        try await settle(window)
        #expect(model.expandedMaskPanels == [.mask], "Option-click leaves only the mask's own panel open")
        #expect(cards[0].height(forWidth: 300) == header)

        model.maskMessage = "Sky masks need a photo with sky in it."
        try await settle(window)
        #expect(cards[0].height(forWidth: 300) > header, "a message opens the Masks panel")
        model.maskMessage = nil
        try await settle(window)
        #expect(cards[0].height(forWidth: 300) == header, "and it closes again after")

        #expect(model.editedAdjustments(of: mask).isEmpty)
        model.setSliderValue(.localExposure, 0.5)
        #expect(model.editedAdjustments(of: mask) == [ParameterID.localExposure.spec.label], "Adjustments' Edited chip")
        model.resetMaskAdjustments(mask)
        #expect(model.editedAdjustments(of: mask).isEmpty)
    }

    @Test func `New Mask shows only once there are masks, as the picker makes the first`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await settle(window)
        func views(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(views)
        }
        func shows(_ identifier: String) -> Bool {
            views(in: panel).contains { $0.accessibilityIdentifier() == identifier }
        }
        #expect(!shows("masks.new") && shows("masks.presets"), "Mask Presets alone under the picker")
        try await draw(0.3, in: model, window: window)
        #expect(shows("masks.new") && shows("masks.presets"), "New Mask beside Mask Presets under the list")
    }

    @Test func `an offer of models shows once over a photo's first mask picker`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        model.offeredModels = (MaskEditingTests.skyModels, .sky)
        try await settle(window)
        func views(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(views)
        }
        let downloads = views(in: panel).filter { $0.accessibilityIdentifier() == "masks.download" }
        #expect(
            model.maskOutlines.isEmpty && content(panel.masksPanel).count == 2,
            "the messages and the picker, above New Mask",
        )
        #expect(downloads.count == 1, "the messages offer the models, and the picker under them doesn't again")
    }

    @Test func `the Masks panel's column is re-measured when a mask comes back`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let scroll = PanelColumnScrollView(views: [MasksPanelView(model: model)])
        let window = window(scroll, height: 600)
        defer { window.orderOut(nil) }
        func measured() -> Bool {
            let document = scroll.document
            return document.frame.height == document.height(forWidth: document.frame.width)
        }
        try await draw(0.3, in: model, window: window)
        let kept = try #require(model.selectedMaskID)
        try await draw(0.7, in: model, window: window)
        let other = try #require(model.selectedMaskID)
        model.selectMask(kept)
        try await settle(window)
        #expect(measured())

        model.deleteMask(other)
        try await settle(window)
        #expect(model.selectedMaskID == kept)
        #expect(measured(), "the list is a row shorter")
        let shorter = scroll.document.frame.height
        model.undo()
        try await settle(window)
        #expect(model.maskOutlines.count == 2)
        #expect(measured(), "the list is a row longer again")
        #expect(scroll.document.frame.height > shorter)
    }

    /// #364 in the AppKit panel: a component's row goes with the settings it was in, and its
    /// preview with it. SwiftUI reads hovers from the real pointer, so each hover is set as the
    /// row reports it.
    @Test func `a mask's or a component's preview ends with its row`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await draw(0.3, in: model, window: window)
        try await draw(0.7, in: model, window: window)
        let (left, right) = (model.masks[0].id, model.masks[1].id)

        model.hoveredMaskID = left
        model.deleteMask(left)
        try await settle(window)
        #expect(model.hoveredMaskID == nil, "the deleted mask's row went, and its preview with it")
        model.undo()
        try await settle(window)
        #expect(model.maskOverlayShown == right, "back again, the mask isn't under the pointer")

        model.selectMask(right)
        model.startDrawing(.linear, operation: .subtract, addingTo: right)
        model.beginDrawing(.linear(LinearMask(start: ImagePoint(x: 0.7, y: 0.2), end: ImagePoint(x: 0.7, y: 0.4))))
        model.finishDrawing()
        let component = try #require(model.recipe.mask(right)?.components.last?.id)
        try await settle(window)
        model.hoveredComponentID = component
        model.deleteComponent(component, in: right)
        try await settle(window)
        #expect(model.hoveredComponentID == nil, "the deleted component's row went, and its preview with it")
        model.undo()
        try await settle(window)
        #expect(model.componentPreview(in: model.recipe) == nil)
    }
}
