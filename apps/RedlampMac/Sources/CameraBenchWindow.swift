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
        let window = CameraBenchWindowController(model: model) { Self.controller = nil }
        controller = window
        window.showWindow(nil)
    }
}
