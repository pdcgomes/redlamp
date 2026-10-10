import AppKit
import Foundation
import RedlampCanvas
import RedlampEngineAPI
import SwiftUI
import Testing
@testable import RedlampUI

/// The editor's canvas spans the window under the side panels, which float over it, and AppKit
/// tells every tracking area under the pointer about it, whatever covers the view the area is on.
/// The pointer over the Masks panel must preview only what it's over in the panel: the canvas's
/// pins beneath it previewed their masks there, so the overlay showed another mask than the one
/// chosen in the list (#364).
@MainActor
struct PointerOverPanelTests {
    private struct Editor {
        let model: EditorModel
        /// Kept for the window's life: it owns the window and its trackers.
        let controller: EditorWindowController
        let window: NSWindow
        /// The canvas's hosting view, which spans the window.
        let canvas: NSView
        let pointer: TrackingPointer
        let cleanup: () -> Void
    }

    /// The editor window, never put on screen, with a 6000 × 4000 photo open in the Masking tool.
    private func openEditor() async throws -> Editor {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = GatedEngine()
        engine.sendsFrames = true
        engine.base.pixelSize = PixelSize(width: 6000, height: 4000)
        let model = EditorModel(engine: engine)
        model.leftPanelVisible = true
        model.rightPanelVisible = true
        let controller = EditorWindowController(
            model: model, theme: ThemeSettings(), onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        window.setContentSize(CGSize(width: 1600, height: 1000))
        let cleanup = {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            model.select(folder.appending(path: "IMG_0364.ARW"))
            for _ in 0 ..< 400 where !model.hasFrame {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(model.hasFrame)
            model.activeTool = .masking
            let content = try #require(Self.splitItems(of: window).first { $0.behavior == .default })
            // Develop's own view, in the modules' container, which isn't flipped as the canvas is.
            let modules = try #require(content.viewController as? ModuleContentController)
            let editor = Editor(
                model: model, controller: controller, window: window, canvas: modules.developView,
                pointer: TrackingPointer(window: window), cleanup: cleanup,
            )
            try await settle(editor)
            return editor
        } catch {
            cleanup()
            throw error
        }
    }

    private func settle(_ editor: Editor) async throws {
        for _ in 0 ..< 20 {
            editor.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A radial mask around `center`; the new mask is selected.
    @discardableResult
    private func radial(_ model: EditorModel, at center: ImagePoint, radius: Double = 0.1) throws -> UUID {
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: center, radiusX: radius, radiusY: radius)))
        model.finishDrawing()
        return try #require(model.selectedMaskID)
    }

    /// Where `point` of the photo is in the window.
    private func location(of point: ImagePoint, in editor: Editor) -> NSPoint {
        let rect = editor.model.canvas.imageRect(in: editor.canvas.bounds.size)
        let view = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        return editor.canvas.convert(view, to: nil)
    }

    /// A point of the canvas in the window, near the top of the stage, away from the masks' pins.
    private func awayFromPins(_ editor: Editor) -> NSPoint {
        let stage = editor.model.canvas.stage(in: editor.canvas.bounds.size)
        return editor.canvas.convert(CGPoint(x: stage.midX, y: stage.minY + 30), to: nil)
    }

    /// The middle of the inspector's view carrying `identifier`, in the window. SwiftUI's hosting
    /// views aren't asked for theirs: answering builds their accessibility, which takes seconds.
    private func location(of identifier: String, in editor: Editor) throws -> NSPoint {
        let inspector = try #require(Self.splitItems(of: editor.window).first { $0.behavior == .inspector })
        func search(_ view: NSView) -> NSView? {
            if !String(describing: type(of: view)).hasPrefix("NSHostingView"),
               view.accessibilityIdentifier() == identifier, !view.isHiddenOrHasHiddenAncestor {
                return view
            }
            return view.subviews.lazy.compactMap(search).first
        }
        let view = try #require(search(inspector.viewController.view), "\(identifier) isn't in the inspector")
        try #require(!view.visibleRect.isEmpty, "\(identifier) is scrolled out of sight")
        let frame = view.convert(view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func inspectorFrame(_ editor: Editor) throws -> NSRect {
        let inspector = try #require(Self.splitItems(of: editor.window).first { $0.behavior == .inspector })
        let view = inspector.viewController.view
        return view.convert(view.bounds, to: nil)
    }

    /// Drags the selected mask's Exposure, as its slider does, and lets go.
    private func adjustExposure(_ editor: Editor, by amount: Double) {
        let model = editor.model
        model.beginEdit(.localExposure)
        model.setValue(.localExposure, model.value(.localExposure) + amount)
        #expect(model.maskOverlayShown == nil, "the overlay is off while the mask's adjustment is dragged")
        model.endEdit()
    }

    /// The report's steps: several masks, chosen in turn in the list with the overlay on, and
    /// each one's Exposure dragged, the pointer never leaving the panel. Up to 0.2.8 each pin's
    /// hover covered the whole canvas, and so the window; the topmost pin's mask showed instead.
    @Test func `the overlay shows the mask chosen in the list while the pointer stays in the panel`() async throws {
        let editor = try await openEditor()
        defer { editor.cleanup() }
        let model = editor.model
        // Three masks, as the report's Background, cup and pen, each with its pin in the photo.
        let masks = try [0.08, 0.14, 0.2].map { try radial(model, at: ImagePoint(x: 0.5, y: 0.5), radius: $0) }
        try await settle(editor)

        // The pointer crosses the photo, away from the pins, into the panel.
        editor.pointer.move(to: location(of: ImagePoint(x: 0.15, y: 0.2), in: editor))
        try await settle(editor)
        #expect(model.maskOverlayShown == masks[2], "over the photo, away from the pins")

        for mask in [masks[1], masks[0], masks[2], masks[1]] {
            // Chosen in the list: the pointer on its row previews it, and a click selects it.
            try editor.pointer.move(to: location(of: "masks.row.\(mask.uuidString)", in: editor))
            try await settle(editor)
            #expect(model.maskOverlayShown == mask, "the row under the pointer previews its mask")
            model.selectMask(mask)
            try editor.pointer.move(to: location(of: "slider.local.exposure.track", in: editor))
            try await settle(editor)
            #expect(model.maskOverlayShown == mask, "on the Exposure slider, the overlay is the chosen mask's")
            adjustExposure(editor, by: 0.5)
            #expect(model.maskOverlayShown == mask, "after dragging Exposure, the chosen mask's overlay is back")
        }

        editor.pointer.move(to: location(of: ImagePoint(x: 0.15, y: 0.2), in: editor))
        try await settle(editor)
        #expect(model.maskOverlayShown == masks[1], "back over the photo, away from the pins")
    }

    /// Zoomed in, the photo runs under the inspector, and so can another mask's pin. The pointer
    /// over the panel there is over the panel, not the pin, so the selected mask's overlay stays.
    @Test func `a pin under the inspector doesn't preview its mask while the pointer is over the panel`() async throws {
        let editor = try await openEditor()
        defer { editor.cleanup() }
        let model = editor.model
        // The other mask's pin goes where it covers most, in the middle of the photo; the selected
        // mask's own handles are well away from it.
        let other = try radial(model, at: ImagePoint(x: 0.5, y: 0.5))
        let selected = try radial(model, at: ImagePoint(x: 0.3, y: 0.5))
        await model.refreshMaskThumbnails()
        try await settle(editor)
        let pinPoint = try #require(model.maskPins[other])

        // At 1:1, the pin is panned under the selected mask's Exposure slider.
        let slider = try location(of: "slider.local.exposure.track", in: editor)
        try #require(inspectorFrame(editor).contains(slider))
        model.canvas.zoom = .oneToOne
        try await settle(editor)
        let canvas = model.canvas
        let rect = canvas.imageRect(in: editor.canvas.bounds.size)
        let target = editor.canvas.convert(slider, from: nil)
        canvas.center = CGPoint(
            x: canvas.center.x + (rect.minX + pinPoint.x * rect.width - target.x) / rect.width,
            y: canvas.center.y + (rect.minY + pinPoint.y * rect.height - target.y) / rect.height,
        )
        try await settle(editor)
        let pin = location(of: pinPoint, in: editor)
        try #require(
            abs(pin.x - slider.x) < 1 && abs(pin.y - slider.y) < 1,
            "the pin is at \(pin), the slider at \(slider)",
        )

        // The pointer comes from the photo onto the slider, over the other mask's pin.
        editor.pointer.move(to: awayFromPins(editor))
        try await settle(editor)
        #expect(model.maskOverlayShown == selected, "over the photo, away from the pins")
        editor.pointer.move(to: slider)
        try await settle(editor)
        #expect(model.maskOverlayShown == selected, "the pointer is over the panel, not the pin under it")
        adjustExposure(editor, by: 0.5)
        editor.pointer.move(to: NSPoint(x: slider.x + 2, y: slider.y))
        try await settle(editor)
        #expect(model.maskOverlayShown == selected, "after dragging Exposure, the selected mask's overlay is back")

        // The other mask's row still previews it, and only while the pointer is on the row.
        try editor.pointer.move(to: location(of: "masks.row.\(other.uuidString)", in: editor))
        try await settle(editor)
        #expect(model.maskOverlayShown == other, "the row under the pointer previews its mask")
        editor.pointer.move(to: slider)
        try await settle(editor)
        #expect(model.maskOverlayShown == selected, "off the row, the selected mask's overlay is back")

        // Back on the photo, the pin previews its mask as before.
        model.canvas.zoom = .fit
        try await settle(editor)
        editor.pointer.move(to: location(of: pinPoint, in: editor))
        try await settle(editor)
        #expect(model.maskOverlayShown == other, "the pointer on the pin, over the photo, previews its mask")
    }

    private static func splitItems(of window: NSWindow) throws -> [NSSplitViewItem] {
        func controllers(_ controller: NSViewController) -> [NSViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        let root = try #require(window.contentViewController)
        let split = try #require(controllers(root).lazy.compactMap { $0 as? NSSplitViewController }.first)
        return split.splitViewItems
    }
}

/// The pointer as AppKit reports it to tracking areas, which a test can't move: every area the
/// point is in hears of it, whatever covers the area's view. An area it comes into gets
/// `mouseEntered`, one it leaves `mouseExited`, and those it's in that ask for moves `mouseMoved`.
/// SwiftUI's hovers start from such an entered event, which carries its tracking area.
@MainActor
final class TrackingPointer {
    private let window: NSWindow
    private var inside: [ObjectIdentifier: (area: NSTrackingArea, owner: NSResponder)] = [:]

    init(window: NSWindow) {
        self.window = window
    }

    /// Moves the pointer to `point`, in the window's coordinates.
    func move(to point: NSPoint) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        var under: [ObjectIdentifier: (area: NSTrackingArea, owner: NSResponder)] = [:]
        var order: [ObjectIdentifier] = []
        func collect(_ view: NSView) {
            guard !view.isHidden else { return }
            for area in view.trackingAreas where isActive(area) {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(view.convert(point, from: nil)), let owner = area.owner as? NSResponder else {
                    continue
                }
                under[ObjectIdentifier(area)] = (area, owner)
                order.append(ObjectIdentifier(area))
            }
            view.subviews.forEach(collect)
        }
        collect(root)
        for (id, left) in inside where under[id] == nil {
            if left.area.options.contains(.mouseEnteredAndExited), let event = event(.mouseExited, point, left.area) {
                left.owner.mouseExited(with: event)
            }
        }
        for id in order where inside[id] == nil {
            guard let entered = under[id], entered.area.options.contains(.mouseEnteredAndExited),
                  let event = event(.mouseEntered, point, entered.area) else { continue }
            entered.owner.mouseEntered(with: event)
        }
        inside = under
        for id in order {
            guard let area = under[id], area.area.options.contains(.mouseMoved), let event = event(.mouseMoved, point)
            else { continue }
            area.owner.mouseMoved(with: event)
        }
    }

    private func isActive(_ area: NSTrackingArea) -> Bool {
        let options = area.options
        if options.contains(.activeAlways) {
            return true
        }
        if options.contains(.activeInActiveApp) {
            return NSApp.isActive
        }
        if options.contains(.activeInKeyWindow) {
            return window.isKeyWindow
        }
        return false
    }

    private func event(_ type: NSEvent.EventType, _ point: NSPoint, _ area: NSTrackingArea? = nil) -> NSEvent? {
        let time = ProcessInfo.processInfo.systemUptime
        guard let area else {
            return NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
            )
        }
        return NSEvent.enterExitEvent(
            with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
            userData: nil,
        )
    }
}
