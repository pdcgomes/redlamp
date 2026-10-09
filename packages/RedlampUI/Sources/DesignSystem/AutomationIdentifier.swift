import AppKit
import SwiftUI

@_spi(Harness) public extension View {
    /// The identifier VoiceOver and the regression suite find a SwiftUI control by. SwiftUI's
    /// controls aren't views of their own, and it builds no accessibility until an assistive app
    /// asks, so an empty view behind the control carries the identifier too, where the suite's
    /// driver finds it among the window's views.
    func automationIdentifier(_ identifier: String) -> some View {
        accessibilityIdentifier(identifier)
            .background(AutomationMarker(identifier: identifier).allowsHitTesting(false))
    }
}

/// An empty view the size of what it's behind, carrying an identifier. Clicks pass through it,
/// and VoiceOver skips it.
private struct AutomationMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> MarkerView {
        let view = MarkerView()
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: MarkerView, context _: Context) {
        view.setAccessibilityIdentifier(identifier)
    }

    final class MarkerView: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
}
