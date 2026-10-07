import AppKit
@_spi(Harness) import RedlampUI

/// Routes Develop shortcuts from the keyboard to the registry (`ShortcutAction`).
///
/// ⌘ combos belong to the menu bar (see `AppCommands`), which gives them menu items and
/// native key equivalents. Everything else (single keys, Shift-keys, Tab, F-keys) is handled
/// here, because menu key equivalents without ⌘ would fire while typing in a value field.
/// The monitor steps aside whenever text is being edited.
@MainActor
final class KeyboardShortcuts {
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var spaceMonitor: Any?
    private var resignObserver: Any?

    func install(model: EditorModel) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handle(event, model: model) ? nil : event
        }
        // Space held in a tool pans the photo; letting it go without a click or drag toggles the zoom.
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { event in
            guard model.isSpacePanning else { return event }
            if event.type == .leftMouseDown {
                model.noteSpacePanUse()
                return event
            }
            guard event.keyCode == 49 else { return event }
            model.endSpacePan()
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main,
        ) { _ in
            MainActor.assumeIsolated { model.cancelSpacePan() }
        }
        // Holding Option shows "Reset …" group titles, as in Lightroom.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let option = event.modifierFlags.contains(.option)
            if model.optionKeyHeld != option {
                model.optionKeyHeld = option
            }
            return event
        }
    }

    private static func handle(_ event: NSEvent, model: EditorModel) -> Bool {
        // The command palette handles its own keys, even if focus has left its field, and a
        // sheet (the Export dialog) or the welcome window keeps its keys from the editor behind it.
        if NSApp.keyWindow?.firstResponder is NSTextView || model.commandPalette != nil || model.isModalDialogOpen
            || NSApp.keyWindow?.sheetParent != nil || NSApp.keyWindow?.attachedSheet != nil
            || NSApp.keyWindow?.windowController is WelcomeWindowController
            || NSApp.keyWindow?.windowController is ImportWindowController {
            return false
        }
        let flags = event.modifierFlags
        guard !flags.contains(.command), !flags.contains(.control), let key = key(for: event) else { return false }
        if key == .space, !flags.contains(.shift), !flags.contains(.option),
           model.isSpacePanning || model.hasToolOverlay {
            if !event.isARepeat {
                model.beginSpacePan()
            }
            return true
        }
        let combo = KeyCombo(key, shift: flags.contains(.shift), option: flags.contains(.option))
        guard let (action, shifted) = ShortcutAction.resolve(combo, in: model.module), !action.isMenuShortcut
        else { return false }
        return model.perform(action, shifted: shifted)
    }

    /// The unshifted key, so Shift-1 reads as "1" with Shift held.
    private static func key(for event: NSEvent) -> KeyCombo.Key? {
        switch event.keyCode {
        case 48: return .tab
        case 53: return .escape
        case 51, 117: return .delete
        case 49: return .space
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 120: return .function(2)
        case 96: return .function(5)
        case 97: return .function(6)
        case 98: return .function(7)
        case 100: return .function(8)
        default:
            guard let characters = event.characters(byApplyingModifiers: []), let first = characters.first else {
                return nil
            }
            return .character(Character(first.lowercased()))
        }
    }
}
