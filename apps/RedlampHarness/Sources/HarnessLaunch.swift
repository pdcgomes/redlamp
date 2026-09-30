import Foundation
import RedlampDesign

/// Launch options, from the command line or a one-shot `/tmp/redlamp-harness-args` file
/// (consumed on launch) for scripts that start the harness with `open`:
///
/// - `--scene <id>` opens a scene.
/// - `--parity-mode side|difference|onion|flicker` sets how parity scenes compare.
/// - `--background panel|canvas|black` sets the stage surface.
/// - `--theme <id>`, `--appearance dark|light` and `--tint 0...1` pick the theme, and
///   `--native-tint` gives native controls its accent.
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
