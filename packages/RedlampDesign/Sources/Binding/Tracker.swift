import Foundation
import Observation

/// Keeps an AppKit view in step with `@Observable` state, without SwiftUI.
///
/// `update` runs once now, then again whenever anything it read changes, which touches
/// exactly the views that show that value, instead of a view-graph update across a whole
/// window. Changes are applied on the next main-actor turn (observation reports them
/// before the new value is stored), and a burst of changes applies once.
@MainActor
public final class Tracker {
    private var update: (@MainActor () -> Void)?

    public init(_ update: @escaping @MainActor () -> Void) {
        self.update = update
        run()
    }

    /// Stops updating. Views cancel their trackers when they leave the window.
    public func cancel() {
        update = nil
    }

    private func run() {
        guard let update else { return }
        withObservationTracking(update) { [weak self] in
            Task { @MainActor in self?.run() }
        }
    }
}
