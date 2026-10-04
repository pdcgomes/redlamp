import Foundation

/// When the welcome window (`WelcomeWindowController`) opens by itself: at the first launch after
/// a new welcome, and never for launches made by tooling, such as captures and measurements, which
/// it would get in the way of. Help › Welcome to Redlamp opens it at any time.
public enum Welcome {
    /// Raised when the welcome changes enough to show again to everyone who has seen it.
    static let version = 1
    static let shownKey = "welcome.shown"
    /// The flags of `DebugSnapshot`, `DebugPerformance` and `DebugDecodeCheck`.
    static let toolingArguments: Set<String> = [
        "--script",
        "--snapshot",
        "--sweep",
        "--folders-perf",
        "--browse",
        "--decode-check",
    ]

    /// `--welcome` opens it whatever has been seen.
    public static func opensAtLaunch(arguments: [String], defaults: UserDefaults = .standard) -> Bool {
        if arguments.contains("--welcome") {
            return true
        }
        if arguments.contains(where: toolingArguments.contains) {
            return false
        }
        return defaults.integer(forKey: shownKey) < version
    }

    public static func markShown(in defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: shownKey)
    }
}
