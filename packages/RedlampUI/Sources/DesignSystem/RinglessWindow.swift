import AppKit

/// A window that draws no focus rings. With keyboard navigation on, every slider, picker and
/// button that takes focus would draw one. AppKit draws a ring only around the first
/// responder, so each view loses its ring as it takes focus (a text field's ring belongs to
/// the field, not to the field editor that becomes first responder).
public final class RinglessWindow: NSWindow {
    private var focusObservation: NSKeyValueObservation?

    override public init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool,
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        focusObservation = observe(\.firstResponder, options: [.initial, .new]) { window, _ in
            MainActor.assumeIsolated { window.removeFocusRing() }
        }
    }

    private func removeFocusRing() {
        var view = firstResponder as? NSView
        if let editor = view as? NSTextView, editor.isFieldEditor {
            view = editor.delegate as? NSView
        }
        view?.focusRingType = .none
    }
}
