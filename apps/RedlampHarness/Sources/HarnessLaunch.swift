import AppKit
import RedlampDesign

/// Launch options, from the command line or a one-shot `/tmp/redlamp-harness-args` file
/// (consumed on launch) for scripts that start the harness with `open`:
///
/// - `--scene <id>` opens a scene.
/// - `--parity-mode side|difference|onion|flicker` sets how parity scenes compare.
/// - `--background panel|canvas|black` sets the stage surface.
/// - `--theme <id>`, `--appearance dark|light` and `--tint 0...1` pick the theme, and
///   `--native-tint` gives native controls its accent.
/// - `--stage-only` hides the scene list and the inspector.
/// - `--window <width>x<height>` sizes the window in points and moves it to a Retina screen
///   when one is connected, so captures come out at 2x even when the main display is 1x.
enum HarnessLaunch {
    static let arguments: [String] = {
        var arguments = CommandLine.arguments
        let path = "/tmp/redlamp-harness-args"
        if let line = try? String(contentsOfFile: path, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: path)
            arguments += line.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return arguments
    }()

    static func value(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    static var stageOnly: Bool {
        arguments.contains("--stage-only")
    }

    @MainActor
    static func placeWindowIfRequested() async {
        let size = value(after: "--window")?.split(separator: "x").compactMap { Double($0) }
        guard let size, size.count == 2 else { return }
        // Once the window is on screen: showing it restores its saved frame over any earlier one.
        var window: NSWindow?
        for _ in 0 ..< 50 {
            window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
            if window != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.backingScaleFactor > 1 } ?? window.screen
        guard let area = screen?.visibleFrame else { return }
        // A scripted size isn't the user's: keep it out of the saved frame.
        window.setFrameAutosaveName("")
        window.setFrame(
            NSRect(x: area.midX - size[0] / 2, y: area.midY - size[1] / 2, width: size[0], height: size[1]),
            display: true,
        )
    }

    static var themeSelection: ThemeSelection {
        var selection = ThemeSelection()
        if let id = value(after: "--theme"), ThemeCatalog.families.contains(where: { $0.id == id }) {
            selection.familyID = id
        }
        if let appearance = value(after: "--appearance").flatMap(ThemeAppearance.init(rawValue:)) {
            selection.appearance = appearance
        }
        if let tint = value(after: "--tint").flatMap(Double.init) {
            selection.tint = min(max(tint, 0), 1)
        }
        selection.tintsNativeControls = arguments.contains("--native-tint")
        return selection
    }
}
