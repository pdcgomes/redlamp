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
            let sheet = await makeSheet(model: model, context: context, windowShot: shot, prefill: prefill)
            sheet.onSent = { report, result in
                if case let .filed(number, url) = result {
                    history.record(report, number: number, url: url)
                }
            }
            sheet.onQueue = { history.enqueue($0) }
            show(over: window, model: model, size: FeedbackSheet.size) { close, height in
                FeedbackSheet(sheet: sheet, height: height, dismiss: close, showReports: {
                    close()
                    presentReports(model: model, history: history)
                })
            }
            sheet.log = await AppLogTail.entries(since: sessionStart)
        }
    }

    /// The sheet's model as Report a Bug builds it: what the editor shows now, the Mac's
    /// details, and the relay it sends to.
    @_spi(Harness) public static func makeSheet(
        model: EditorModel, context: FeedbackContext? = nil, windowShot: FeedbackReport.Screenshot? = nil,
        prefill: FeedbackPrefill? = nil,
    ) async -> FeedbackSheetModel {
        let context = context ?? FeedbackContext.capture(from: model)
        let models = await model.engine.models()
        let system = SystemSnapshot.capture(models: models)
        return FeedbackSheetModel(
            context: context, system: system, windowShot: windowShot, prefill: prefill,
            sender: FeedbackRelay(client: client), dryRun: !FeedbackRelay.sendsLive,
        )
    }

    public static func presentReports(model: EditorModel, history: FeedbackHistory = .shared) {
        guard !model.isModalDialogOpen, let window = editorWindow else { return }
        model.isModalDialogOpen = true
        show(over: window, model: model, size: YourReportsView.size) { close, _ in
            YourReportsView(history: history, dismiss: close)
        }
    }

    /// "Redlamp/0.2.1-prealpha (412)", sent with every request to the relay.
    private static var client: String {
        let info = Bundle.main.infoDictionary
        return "Redlamp/\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private static var editorWindow: NSWindow? {
        EditorWindowController.frontWindow
    }

    /// Shows `content` in a sheet `size` big, or less tall on a short window: `content` is given
    /// the sheet's close action and its height.
    private static func show(
        over window: NSWindow, model: EditorModel, size: CGSize,
        content: (@escaping () -> Void, CGFloat) -> some View,
    ) {
        let height = window.sheetHeight(fitting: size.height)
        let sheetWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size.width, height: height),
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
        sheetWindow.contentViewController = NSHostingController(rootView: content(close, height)
            .tint(Theme.nativeTint)
            .focusEffectDisabled())
        window.beginSheet(sheetWindow)
    }
}
