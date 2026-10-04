import AppKit
import RedlampEngine
import RedlampRecipes
import RedlampServices
import RedlampUI

/// Help › Test Your Camera…: one Camera Bench window, whose bench has an engine of its own, so
/// testing photos never disturbs the photo open in the editor. Photos decode in the decode
/// service, as the editor's do.
@MainActor
enum CameraBenchWindow {
    private static var controller: CameraBenchWindowController?

    /// Problems are reported through the editor's Report a Bug or Send Feedback, which opens
    /// over the editor window.
    static var sendFeedback: ((FeedbackPrefill) -> Void)?

    static func show(currentFolder: @escaping () -> URL?) {
        if let controller {
            controller.showWindow(nil)
            return
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let model = CameraBenchModel(
            makeBench: { try CameraBench(engine: RedlampEngine(decoder: DecodeServiceClient(), lensProfiles: .user)) },
            relay: CameraBenchRelay(client: "Redlamp/\(version) (\(build))"),
            currentFolder: currentFolder,
            version: (redlamp: version, commit: info?["RedlampCommit"] as? String),
        )
        model.onReportProblem = sendFeedback.map { send in
            { prefill in
                NSApp.windows.first { $0.windowController is EditorWindowController }?.makeKeyAndOrderFront(nil)
                send(prefill)
            }
        }
        let window = CameraBenchWindowController(model: model) { Self.controller = nil }
        controller = window
        window.showWindow(nil)
    }

    #if DEBUG || REDLAMP_PROFILING
        /// For captures, on a Retina screen when one is connected: `--camera-bench` opens the window,
        /// and `--camera-bench <folder>` tests the folder. Once the results are in,
        /// `--camera-bench-select <text>` selects the first camera mode whose camera contains the
        /// text, and `--camera-bench-report` opens What's Sent.
        static func openIfRequested(currentFolder: @escaping () -> URL?) {
            let arguments = LaunchArguments.all
            func value(after flag: String) -> String? {
                arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            }
            guard arguments.contains("--camera-bench") else { return }
            show(currentFolder: currentFolder)
            guard let controller else { return }
            if let window = controller.window,
               let visible = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 })?.visibleFrame {
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2,
                ))
            }
            guard let folder = value(after: "--camera-bench"), !folder.hasPrefix("--") else { return }
            let model = controller.model
            model.test([URL(fileURLWithPath: folder)])
            let camera = value(after: "--camera-bench-select")
            let report = arguments.contains("--camera-bench-report")
            Task {
                while model.phase != .results {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let camera,
                   let mode = model.modes.first(where: { $0.mode.camera.localizedCaseInsensitiveContains(camera) }) {
                    model.selectedMode = mode.id
                }
                model.showsReport = report
            }
        }
    #endif
}
