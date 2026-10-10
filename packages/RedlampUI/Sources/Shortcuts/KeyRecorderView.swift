import AppKit
import SwiftUI

/// Where Settings › Shortcuts records a key (LIB-36): while it has the keyboard, the next key pressed, with its
/// modifiers, is taken as the key, whatever the menus or the editor would do with it; ⌘Q and Esc included. A text
/// view, so the editor's key monitor steps aside for it as it does for text being edited.
final class KeyRecorderView: NSTextView {
    /// Whether a key is being recorded, which keeps the menu bar's key handling (`MenuBarKeys`) out of the way.
    static var isRecording = false

    var onKey: ((KeyCombo) -> Void)?
    var onModifiers: ((NSEvent.ModifierFlags) -> Void)?
    var onEnd: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        Self.isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        Self.isRecording = false
        onModifiers?([])
        onEnd?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let combo = KeyCombo(event: event) else {
            NSSound.beep()
            return
        }
        onKey?(combo)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        onModifiers?(event.modifierFlags.intersection([.control, .option, .shift, .command]))
    }

    override func draw(_: NSRect) {}
}

/// The recorder in a SwiftUI view: it takes the keyboard while `isRecording`, and gives it back after.
struct KeyRecorder: NSViewRepresentable {
    let isRecording: Bool
    let onKey: (KeyCombo) -> Void
    let onModifiers: (NSEvent.ModifierFlags) -> Void
    let onEnd: () -> Void

    func makeNSView(context _: Context) -> KeyRecorderView {
        let view = KeyRecorderView(frame: .zero)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.focusRingType = .none
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: KeyRecorderView, context _: Context) {
        view.onKey = onKey
        view.onModifiers = onModifiers
        view.onEnd = onEnd
        let isFirstResponder = view.window?.firstResponder === view
        guard isRecording != isFirstResponder else { return }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if isRecording, window.firstResponder !== view {
                window.makeFirstResponder(view)
            } else if !isRecording, window.firstResponder === view {
                window.makeFirstResponder(nil)
            }
        }
    }
}
