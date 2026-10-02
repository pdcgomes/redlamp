import Foundation
import Observation
import RedlampDocument

/// How the photos changed, for views that update row by row (the filmstrip): rows removed
/// (indices before the change), rows inserted and rows whose badges changed (indices after it).
/// `reset` replaces everything, as when another folder opens.
public struct LibraryDiff: Sendable, Equatable {
    public var reset = false
    public var removed = IndexSet()
    public var inserted = IndexSet()
    public var updated = IndexSet()

    public init(reset: Bool = false, removed: IndexSet = [], inserted: IndexSet = [], updated: IndexSet = []) {
        self.reset = reset
        self.removed = removed
        self.inserted = inserted
        self.updated = updated
    }

    public var isEmpty: Bool {
        !reset && removed.isEmpty && inserted.isEmpty && updated.isEmpty
    }
}

/// The photos of the open folder, and how they got there.
///
/// Listing reads no sidecars: photos arrive from the directory listing alone, and the badges of
/// those with a sidecar follow from light probes of their `edit.json`, run in parallel, visible
/// photos first. `items` isn't observed (a badge mustn't re-render SwiftUI views); views observe
/// `count`, `revision` or `openFolder`, and the filmstrip applies `LibraryDiff`s row by row.
@MainActor
@Observable
public final class FolderLibrary {
    public private(set) var openFolder: URL?
    /// The number of photos shown.
    public private(set) var count = 0
    /// Bumped by every change to `items`.
    public private(set) var revision = 0

    @ObservationIgnored public private(set) var items: [LibraryItem] = []
    @ObservationIgnored private var positions: [URL: Int] = [:]
    @ObservationIgnored let scheduler: WorkScheduler
    @ObservationIgnored private let store = SidecarStore()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [UUID: @MainActor (LibraryDiff) -> Void] = [:]

    /// Photos per probe job: big enough that scheduling is noise, small enough that the visible
    /// ones' badges come first.
    static let probeBatch = 32

    public init(scheduler: WorkScheduler = .shared) {
        self.scheduler = scheduler
    }

    // MARK: - Reading

    public func index(of url: URL) -> Int? {
        positions[url]
    }

    public func item(for url: URL) -> LibraryItem? {
        positions[url].map { items[$0] }
    }

    /// Calls `handler` after every change, until the returned token is released.
    public func observe(_ handler: @escaping @MainActor (LibraryDiff) -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    // MARK: - Opening

    /// Lists `folder` and shows its photos, then calls `opened` with them (once, unless another
    /// folder opens first).
    func open(_ folder: URL, opened: @escaping @MainActor ([LibraryItem]) -> Void = { _ in }) {
        generation += 1
        let generation = generation
        scheduler.cancel(prefix: probeKeyPrefix(generation - 1))
        openFolder = folder
        replace(with: [])
        Task {
            let found = try? await scheduler.run(.onScreen) {
                try FolderScanner.list(folder).photos.map(LibraryItem.init)
            }
            guard self.generation == generation else { return }
            replace(with: found ?? [])
            probeSidecars(generation: generation)
            opened(items)
        }
    }

    private func replace(with items: [LibraryItem]) {
        self.items = items
        positions = Dictionary(items.enumerated().map { ($1.url, $0) }) { first, _ in first }
        publish(LibraryDiff(reset: true))
    }

    /// Adds a photo in name order (a stack document just saved).
    func insert(_ item: LibraryItem) {
        guard positions[item.url] == nil else { return }
        let index = items.firstIndex { FileOrder.precedes(item.name, $0.name) } ?? items.count
        items.insert(item, at: index)
        reindex(from: index)
        publish(LibraryDiff(inserted: [index]))
    }

    /// Changes one photo's badges.
    func update(_ url: URL, _ change: (inout LibraryItem) -> Void) {
        guard let index = positions[url] else { return }
        var item = items[index]
        change(&item)
        guard item != items[index] else { return }
        items[index] = item
        publish(LibraryDiff(updated: [index]))
    }

    private func reindex(from start: Int) {
        for index in start ..< items.count {
            positions[items[index].url] = index
        }
    }

    private func publish(_ diff: LibraryDiff) {
        count = items.count
        revision += 1
        for observer in observers.values {
            observer(diff)
        }
    }

    // MARK: - Badges

    private func probeKeyPrefix(_ generation: Int) -> String {
        "probe:\(generation):"
    }

    /// Reads the badges of every photo with a local sidecar, a batch per job, in order.
    private func probeSidecars(generation: Int) {
        let store = store
        for start in stride(from: 0, to: items.count, by: Self.probeBatch) {
            let urls = items[start ..< min(start + Self.probeBatch, items.count)].filter(\.needsSummary).map(\.url)
            guard !urls.isEmpty else { continue }
            scheduler.submit(.lookAhead, key: probeKeyPrefix(generation) + "\(start / Self.probeBatch)") {
                let summaries = urls.map { ($0, store.summary(for: $0)) }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    apply(summaries)
                }
            }
        }
    }

    private func apply(_ summaries: [(URL, SidecarSummary?)]) {
        var updated = IndexSet()
        for (url, summary) in summaries {
            guard let index = positions[url] else { continue }
            let summary = summary ?? SidecarSummary()
            guard items[index].hasEdits != summary.hasEdits || items[index].metadata != summary.metadata else {
                continue
            }
            items[index].hasEdits = summary.hasEdits
            items[index].metadata = summary.metadata
            updated.insert(index)
        }
        if !updated.isEmpty {
            publish(LibraryDiff(updated: updated))
        }
    }

    /// Reads the badges of these rows before any others still waiting.
    public func prioritize(_ rows: Range<Int>) {
        guard !rows.isEmpty else { return }
        let prefix = probeKeyPrefix(generation)
        for batch in rows.lowerBound / Self.probeBatch ... (rows.upperBound - 1) / Self.probeBatch {
            scheduler.promote(prefix + "\(batch)", to: .onScreen)
        }
    }
}

/// Keeps a `FolderLibrary.observe` handler registered while it lives.
@MainActor
public final class LibraryObservation {
    private var cancel: (() -> Void)?

    init(_ cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    public func invalidate() {
        cancel?()
        cancel = nil
    }

    isolated deinit {
        cancel?()
    }
}
