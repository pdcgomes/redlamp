import AppKit
import SwiftUI

/// The What's New window (UX-14), the welcome window's size and look: the film's rise, the
/// highlights, then a page each. It opens over the editor after an update (`WhatsNew`) and from
/// Help › What's New in Redlamp. Return and → go on, ← goes back, and Escape closes it.
@MainActor
public final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    public static let title = "What's New in Redlamp"

    let model: WhatsNewModel
    private let onClose: () -> Void

    /// `film` is the app's Welcome.mp4; without it the highlights show straight away. `onAction`
    /// runs a page's button once the window has closed.
    public init(
        pages: WhatsNewPages, film: URL?,
        onAction: @escaping (WhatsNewItem.Action) -> Void, onClose: @escaping () -> Void,
    ) {
        model = WhatsNewModel(
            pages: pages, film: film, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        )
        self.onClose = onClose
        let window = FilmWindow.make(title: Self.title, size: WelcomeView.size, content: WhatsNewView(model: model))
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak self] in self?.finish() }
        // Closing can release the window's owner, so the action is held here.
        model.onAction = { [weak self, onAction] action in
            self?.close()
            onAction(action)
        }
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

    /// As Return goes on: past the film, then through the pages. For captures (`whats-new=` in a
    /// `DebugSnapshot` script).
    @_spi(Harness) public func next() {
        model.next()
    }

    override public func cancelOperation(_: Any?) {
        close()
    }

    override public func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: model.back()
        case .rightArrow?: model.next()
        default: super.keyDown(with: event)
        }
    }

    public func windowWillClose(_: Notification) {
        model.stop()
        onClose()
    }

    /// Done: the window fades and the editor behind it takes over.
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
