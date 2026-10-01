import Foundation
import Sparkle

/// Sparkle's updater, in the builds that update themselves: those made by `mise run release`,
/// the only ones with a feed URL in Info.plist.
@MainActor
@Observable
final class Updates {
    /// False while a check is under way.
    private(set) var canCheck = false
    /// Sparkle's own setting, which it keeps in user defaults.
    private(set) var checksAutomatically = false

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init?() {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty else {
            return nil
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.checksAutomatically = updater.automaticallyChecksForUpdates }
            },
        ]
    }

    func check() {
        controller.checkForUpdates(nil)
    }

    /// Sparkle asks for this to be set only when the user changes it.
    func setChecksAutomatically(_ checks: Bool) {
        controller.updater.automaticallyChecksForUpdates = checks
    }
}
