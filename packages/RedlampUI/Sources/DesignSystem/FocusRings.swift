import AppKit

/// Redlamp draws no focus rings. AppKit draws one around the key window's first responder, or
/// around the text field a field editor is editing; with keyboard navigation on, every slider,
/// pop-up and button that takes focus would draw one. Installed at launch, this takes the ring
/// off whatever takes focus in any window that becomes key: the app's own, and those SwiftUI and
/// AppKit make for scenes, sheets, popovers and alerts. The ring stays off while the view has
/// focus, since SwiftUI turns a bordered text field's back on as it takes focus and each time it
/// updates. SwiftUI's own focus effects are turned off where each SwiftUI hierarchy is hosted,
/// with `focusEffectDisabled()`; `scripts/check-focus-rings.py` checks both.
@MainActor
public enum FocusRings {
    private static var keyWindowObserver: (any NSObjectProtocol)?
    private static var firstResponder: NSKeyValueObservation?
    private static var ringType: NSKeyValueObservation?

    /// From now on, no window draws a focus ring. The app calls it once, at launch.
    public static func removeEverywhere() {
        guard keyWindowObserver == nil else { return }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil,
        ) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated { window.map(watch) }
        }
        NSApp.keyWindow.map(watch)
    }

    /// Only the key window draws a ring, so its focus is followed until another window becomes key.
    static func watch(_ window: NSWindow) {
        firstResponder = window.observe(\.firstResponder, options: [.initial, .new]) { window, _ in
            MainActor.assumeIsolated { keepRingless(ringOwner(of: window.firstResponder)) }
        }
    }

    /// The view whose ring shows while `responder` has focus: a field editor's is its text field's.
    /// SwiftUI's field editor has no delegate yet as it takes focus, but it sits inside its field.
    static func ringOwner(of responder: NSResponder?) -> NSView? {
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return responder as? NSView }
        var view = editor.superview
        while let candidate = view, !(candidate is NSTextField) {
            view = candidate.superview
        }
        return view ?? editor.delegate as? NSView
    }

    private static func keepRingless(_ view: NSView?) {
        ringType = nil
        guard let view else { return }
        view.focusRingType = .none
        ringType = view.observe(\.focusRingType) { view, _ in
            MainActor.assumeIsolated {
                if view.focusRingType != .none {
                    view.focusRingType = .none
                }
            }
        }
    }
}
