import AppKit
import SwiftUI

/// Opens Report a Bug or Send Feedback over the editor. The window is captured first, so its
/// screenshot shows what the person was looking at rather than the sheet.
@MainActor
public enum FeedbackActions {
    /// Called with each report the relay files, for Your Reports.
    public static var onFiled: ((FeedbackReport, Int, URL) -> Void)?

    public static func present(model: EditorModel, prefill: FeedbackPrefill? = nil) {
        guard !model.isModalDialogOpen,
              let window = NSApp.keyWindow ?? NSApp.mainWindow
              ?? NSApp.windows.first(where: { $0.isVisible && $0.windowController is EditorWindowController })
        else { return }
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
                sender: FeedbackRelay(client: "Redlamp/\(system.version)"), dryRun: !FeedbackRelay.sendsLive,
            )
            sheet.onSent = { report, result in
                if case let .filed(number, url) = result {
                    onFiled?(report, number, url)
                }
            }
            show(sheet, over: window, model: model)
            sheet.log = await AppLogTail.entries(since: sessionStart)
        }
    }

    private static func show(_ sheet: FeedbackSheetModel, over window: NSWindow, model: EditorModel) {
        let sheetWindow = RinglessWindow(
            contentRect: CGRect(origin: .zero, size: FeedbackSheet.size),
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
        sheetWindow.contentViewController = NSHostingController(rootView: FeedbackSheet(sheet: sheet, dismiss: close)
            .tint(Theme.nativeTint)
            .focusEffectDisabled())
        window.beginSheet(sheetWindow)
    }
}
