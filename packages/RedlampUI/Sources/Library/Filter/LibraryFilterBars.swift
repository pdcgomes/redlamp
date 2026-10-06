import AppKit

/// The filter bar in a window, for the measurements: typing into its text through the field editor,
/// as the keyboard does, and clearing it.
@_spi(Harness) public enum LibraryFilterBars {
    /// Types `text` at the end of the bar's text; false when the window shows no bar.
    @MainActor @discardableResult
    public static func type(_ text: String, in window: NSWindow) -> Bool {
        guard let editor = editor(in: window) else { return false }
        editor.insertText(text, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        return true
    }

    /// Empties the bar's text, as ⌘A and Delete do.
    @MainActor public static func clear(in window: NSWindow) {
        guard let editor = editor(in: window), !editor.string.isEmpty else { return }
        editor.selectAll(nil)
        editor.deleteBackward(nil)
    }

    /// The field editor of the bar's text, which takes the keyboard for it.
    @MainActor private static func editor(in window: NSWindow) -> NSTextView? {
        guard let bar = find(in: window.contentView) else { return nil }
        if bar.field.currentEditor() == nil {
            bar.focusText()
        }
        return bar.field.currentEditor() as? NSTextView
    }

    @MainActor private static func find(in view: NSView?) -> LibraryFilterBarView? {
        guard let view else { return nil }
        if let bar = view as? LibraryFilterBarView {
            return bar
        }
        for subview in view.subviews {
            if let bar = find(in: subview) {
                return bar
            }
        }
        return nil
    }
}
