import Foundation

/// Launch options, from the command line or a one-shot `/tmp/redlamp-harness-args` file
/// (consumed on launch) for scripts that start the harness with `open`:
///
/// - `--scene <id>` opens a scene.
/// - `--parity-mode side|difference|onion|flicker` sets how parity scenes compare.
/// - `--background panel|canvas|black` sets the stage surface.
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
}
