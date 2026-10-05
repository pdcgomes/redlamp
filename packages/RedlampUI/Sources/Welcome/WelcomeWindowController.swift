import AppKit
import SwiftUI

/// The welcome window: the film's opening with its sound, then two pages, what Redlamp is and
/// Pedro's note on how to help. It opens over the editor at the first launch (`Welcome`) and from
/// Help › Welcome to Redlamp. Escape skips the film, then closes the window.
@MainActor
public final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    let model: WelcomeModel
    private let onClose: () -> Void

    /// `film` is the app's Welcome.mp4 (video/scripts/welcome.mjs); without it, or with Reduce
    /// Motion on (the system's setting unless given), the pages show straight away.
    public init(
        film: URL?,
        reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        onClose: @escaping () -> Void,
    ) {
        model = WelcomeModel(film: film, reduceMotion: reduceMotion)
        self.onClose = onClose
        let window = FilmWindow.make(
            title: "Welcome to Redlamp",
            size: WelcomeView.size,
            content: WelcomeView(model: model),
        )
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
        FilmWindow.centre(window, over: editor)
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
