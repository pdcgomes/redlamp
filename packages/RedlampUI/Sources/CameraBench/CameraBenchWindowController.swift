import AppKit
import SwiftUI

/// The Camera Bench window (CAM-15), from Help › Test Your Camera… and the command palette.
@MainActor
public final class CameraBenchWindowController: NSWindowController, NSWindowDelegate {
    public let model: CameraBenchModel
    private let onClose: () -> Void

    public init(model: CameraBenchModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        window.title = "Camera Bench"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.contentView = NSHostingView(rootView: CameraBenchView(model: model) { [weak self] in self?.choose() }
            .tint(Theme.nativeTint))
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Photos or folders to test.
    func choose() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Test"
        panel.message = "Choose raw photos from your camera, or a folder of them."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let urls = self.map({ _ in panel.urls }) else { return }
            MainActor.assumeIsolated { self?.model.test(urls) }
        }
    }

    public func windowWillClose(_: Notification) {
        model.cancel()
        onClose()
    }
}
