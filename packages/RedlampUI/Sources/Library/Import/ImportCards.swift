import AppKit
import Foundation
import RedlampLibrary

/// The cards on this Mac (LIB-27): those in when it starts, and each inserted or taken out since, as the
/// import window's From lists them. A volume is a card when it comes out or ejects and holds a `DCIM`
/// folder (`ImportSource`); telling it reads the volume's top folder, off the main thread.
@MainActor
final class ImportCards {
    static let shared = ImportCards()

    /// Leaves this Mac's volumes alone: no card is listed, and none inserted is heard of. The regression
    /// suite sets it, so a run never reads a card someone left in.
    static var ignoresVolumes = false

    private var found: [ImportSource] = []

    var cards: [ImportSource] {
        Self.ignoresVolumes ? [] : found
    }

    /// A card was inserted: the app opens the import window on it when Settings says so.
    var onInserted: ((ImportSource) -> Void)?
    /// Tells a volume mounted at a URL from a card: nil when it isn't one.
    let resolve: @Sendable (URL) -> ImportSource?
    private var observers: [UUID: @MainActor ([ImportSource]) -> Void] = [:]
    private var notifications: [any NSObjectProtocol] = []

    init(resolve: @escaping @Sendable (URL) -> ImportSource? = ImportCards.card(at:)) {
        self.resolve = resolve
    }

    nonisolated static func card(at url: URL) -> ImportSource? {
        guard let source = try? ImportSource.at(url), source.kind == .card else { return nil }
        return source
    }

    /// Follows the volumes mounted and unmounted, and lists the cards already in.
    func start() {
        guard notifications.isEmpty, !Self.ignoresVolumes else { return }
        let center = NSWorkspace.shared.notificationCenter
        notifications = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    if let url {
                        self.mounted(url)
                    }
                }
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    if let url {
                        self.unmounted(url)
                    }
                }
            },
        ]
        Task {
            let mounted = await Task.detached(priority: .utility) { ImportSource.mountedCards() }.value
            guard !Self.ignoresVolumes else { return }
            for card in mounted where !found.contains(where: { $0.id == card.id }) {
                found.append(card)
            }
            notify()
        }
    }

    /// A volume was mounted at `url`: a card joins the list, and the app hears of it.
    func mounted(_ url: URL) {
        guard !Self.ignoresVolumes else { return }
        let resolve = resolve
        Task {
            guard let card = await Task.detached(priority: .userInitiated, operation: { resolve(url) }).value,
                  !found.contains(where: { $0.id == card.id })
            else { return }
            found.append(card)
            notify()
            onInserted?(card)
        }
    }

    /// The volume at `url` went: its card leaves the list.
    func unmounted(_ url: URL) {
        let path = LibraryService.path(url)
        let before = found.count
        found.removeAll { LibraryService.path($0.medium.root) == path || LibraryService.path($0.url) == path }
        if found.count != before {
            notify()
        }
    }

    /// Calls `handler` with the cards whenever they change, until the token is released.
    func observe(_ handler: @escaping @MainActor ([ImportSource]) -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    private func notify() {
        for observer in observers.values {
            observer(cards)
        }
    }

    /// Ejects the card's volume, off the main thread, as Finder's Eject does.
    nonisolated static func eject(_ card: ImportSource) async throws {
        let root = card.medium.root
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: root)
        }.value
    }
}
