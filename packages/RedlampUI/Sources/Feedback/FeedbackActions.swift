import AppKit
import SwiftUI

/// Opens Report a Bug or Send Feedback and Your Reports over the editor. The window is captured
/// first, so its screenshot shows what the person was looking at rather than the sheet.
@MainActor
public enum FeedbackActions {
    private static var activation: NSObjectProtocol?

    /// Connects Your Reports to the relay at launch: queued reports go out, and the issues'
    /// state is checked, now and whenever Redlamp becomes active (at most every six hours).
    public static func start(history: FeedbackHistory = .shared) {
        let relay = FeedbackRelay(client: client)
        history.source = relay
        history.sender = relay
        let check: @MainActor () -> Void = {
            Task {
                await history.sendQueued()
                await history.refresh()
            }
        }
        check()
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main,
        ) { _ in
            MainActor.assumeIsolated { check() }
        }
    }

    public static func present(
        model: EditorModel,
        prefill: FeedbackPrefill? = nil,
        history: FeedbackHistory = .shared,
    ) {
        guard !model.isModalDialogOpen, let window = editorWindow else { return }
        let context = FeedbackContext.capture(from: model)
        let sessionStart = model.activity.events.first?.time ?? Date(timeIntervalSinceNow: -3600)
        model.isModalDialogOpen = true
        let windowNumber = window.windowNumber
        Task {
            async let shot = Screenshots.capture(windowNumber: windowNumber)
            let models = await model.engine.models()
            let system = SystemSnapshot.capture(models: models)
            let sheet = await FeedbackSheetModel(
                context: context, system: system, windowShot: shot, prefill: prefill,
                sender: FeedbackRelay(client: client), dryRun: !FeedbackRelay.sendsLive,
            )
            sheet.onSent = { report, result in
                if case let .filed(number, url) = result {
                    history.record(report, number: number, url: url)
                }
            }
            sheet.onQueue = { history.enqueue($0) }
            show(over: window, model: model, size: FeedbackSheet.size) { close in
                FeedbackSheet(sheet: sheet, dismiss: close, showReports: {
                    close()
                    presentReports(model: model, history: history)
                })
            }
            sheet.log = await AppLogTail.entries(since: sessionStart)
        }
    }

    public static func presentReports(model: EditorModel, history: FeedbackHistory = .shared) {
        guard !model.isModalDialogOpen, let window = editorWindow else { return }
        model.isModalDialogOpen = true
        show(over: window, model: model, size: YourReportsView.size) { close in
            YourReportsView(history: history, dismiss: close)
        }
    }

    /// "Redlamp/0.2.1-prealpha (412)", sent with every request to the relay.
    private static var client: String {
        let info = Bundle.main.infoDictionary
        return "Redlamp/\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// The window in front, or the editor's when the app isn't (as in scripted captures).
    private static var editorWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.windowController is EditorWindowController }
    }

    private static func show(
        over window: NSWindow, model: EditorModel, size: CGSize, content: (@escaping () -> Void) -> some View,
    ) {
        let sheetWindow = RinglessWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let close = { [weak window, weak sheetWindow] in
            model.isModalDialogOpen = false
            if let window, let sheetWindow {
                window.endSheet(sheetWindow)
            }
        }
        sheetWindow.contentViewController = NSHostingController(rootView: content(close)
            .tint(Theme.nativeTint)
            .focusEffectDisabled())
        window.beginSheet(sheetWindow)
    }
}
