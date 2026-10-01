import AppKit
import RedlampDesign
import SwiftUI

/// SwiftUI content in an `OverlayScrollView`: a thin overlay scroller that fades once
/// scrolling stops, whatever the "Show scroll bars" setting. Give the content its own height
/// (a grouped `Form` needs `.fixedSize(horizontal: false, vertical: true)`); it fills the
/// width and scrolls when taller than the view.
struct OverlayScroll<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context _: Context) -> OverlayScrollView {
        let scrollView = OverlayScrollView()
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = host
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            host.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        return scrollView
    }

    func updateNSView(_ scrollView: OverlayScrollView, context _: Context) {
        (scrollView.documentView as? NSHostingView<Content>)?.rootView = content
    }
}
