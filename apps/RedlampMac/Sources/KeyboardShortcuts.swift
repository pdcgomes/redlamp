import AppKit
import RedlampUI

/// Lightroom Classic's single-key Develop shortcuts.
///
/// Menu key equivalents without modifiers would fire while typing in a value field, so
/// these go through a local event monitor that steps aside whenever text is being edited.
@MainActor
final class KeyboardShortcuts {
    private var monitor: Any?

    func install(model: EditorModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard modifiers.isEmpty else { return event }
            return Self.handle(event, model: model) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent, model: EditorModel) -> Bool {
        switch event.keyCode {
        case 53: // Escape
            if model.eyedropperActive {
                model.eyedropperActive = false
                return true
            }
            if model.activeTool != .edit {
                model.activeTool = .edit
                return true
            }
            return false
        case 48: // Tab
            let visible = model.leftPanelVisible || model.rightPanelVisible
            model.leftPanelVisible = !visible
            model.rightPanelVisible = !visible
            if event.modifierFlags.contains(.shift) {
                model.filmstripVisible = !visible
            }
            return true
        case 123: // ←
            model.selectPrevious()
            return true
        case 124: // →
            model.selectNext()
            return true
        default:
            break
        }

        let shifted = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "\\":
            model.showBefore.toggle()
        case "j":
            model.showClipping.toggle()
        case "z":
            model.canvas.toggleZoom(at: nil)
        case "w" where shifted:
            model.activeTool = model.activeTool == .masking ? .edit : .masking
        case "w":
            if model.info?.supportsWhiteBalance == true {
                model.eyedropperActive.toggle()
            }
        case "r":
            model.activeTool = model.activeTool == .crop ? .edit : .crop
        case "q":
            model.activeTool = model.activeTool == .heal ? .edit : .heal
        case "d":
            model.activeTool = .edit
        default:
            return false
        }
        return true
    }
}
