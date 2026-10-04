import AppKit
import RedlampDesign
import SwiftUI

/// The welcome window: the film's opening with its sound, then two pages, what Redlamp is and
/// Pedro's note on how to help. It opens over the editor at the first launch (`Welcome`) and from
/// Help › Welcome to Redlamp. Escape skips the film, then closes the window.
@MainActor
public final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    let model: WelcomeModel
    private let onClose: () -> Void

    /// `film` is the app's Welcome.mp4 (video/scripts/welcome.mjs); without it the pages show
    /// straight away.
    public init(film: URL?, onClose: @escaping () -> Void) {
        model = WelcomeModel(film: film, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        self.onClose = onClose
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WelcomeView.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false,
        )
        window.title = "Welcome to Redlamp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Brand.wall.nsColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // The film fills the window, titlebar included; left to size it, SwiftUI adds the titlebar.
        let content = NSHostingView(rootView: WelcomeView(model: model))
        content.sizingOptions = []
        window.contentView = content
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak self] in self?.finish() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Opens it centred on `editor` and starts the film.
    public func present(over editor: NSWindow?) {
        guard let window else { return }
        if let editor, let screen = editor.screen ?? NSScreen.main {
            let frame = window.frame
            let visible = screen.visibleFrame
            window.setFrameOrigin(CGPoint(
                x: min(max(editor.frame.midX - frame.width / 2, visible.minX), visible.maxX - frame.width),
                y: min(max(editor.frame.midY - frame.height / 2, visible.minY), visible.maxY - frame.height),
            ))
        } else {
            window.center()
        }
        showWindow(nil)
        model.start()
    }

    /// As Return goes on: past the film, then through the pages. For captures (`welcome=` in a
    /// `DebugSnapshot` script).
    @_spi(Harness) public func next() {
        model.next()
    }

    override public func cancelOperation(_: Any?) {
        if model.step == .film {
            model.skip()
        } else {
            close()
        }
    }

    public func windowWillClose(_: Notification) {
        model.stop()
        onClose()
    }

    /// Start Editing: the window fades and the editor behind it takes over.
    private func finish() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { self.close() }
        }
    }
}
