import Foundation
import Synchronization

public enum PhotoStoreError: Error, Equatable, Sendable {
    /// The folder already holds a store's shards.
    case destinationHoldsAStore(URL)
    /// A shard's copy didn't read back as the shard.
    case copyDiffers(URL)
    case unreadable(URL)
}

/// Thumbnails and previews of every photo in the library (LIB-09), on the Mac's own disk, so slow,
/// network and disconnected volumes browse from it. Each is kept by the photo's content key, so a
/// rename, a move, a copy to another drive or a rebuilt index finds it again.
///
/// The store is 256 shards in `root`, one for each first byte of the key. Each is an append-only
/// pack of records (`StoreRecord`): a tier, an edit digest (LIB-17), the photo file's size and
/// modification date, and the image, HEIC or JPEG (`StoreImageEncoder`). The last record for a
/// key, tier and edit wins. A pack is mapped for reading and has a table of its records in memory,
/// 32 bytes each (`StoreTable`), saved in an index file so that opening it doesn't read every
/// record. A pack more than a third stale is rewritten with only its live records and renamed over
/// the old one, never truncated, so mappings taken before stay valid.
///
/// Grid thumbnails are kept for every photo the library holds: only `evict(keepingIndexed:)`
/// removes them, or a grid budget the user sets. Previews are kept within their budget (10 GB by
/// default), the least recently read going first. Since a pack is rewritten only once a third of it
/// is stale, the files take up to half as much again as what the budgets count.
///
/// Calls are safe from any thread at once, and each shard has its own lock: the indexer stores from
/// all its lanes while the grid reads. They touch the disk, so make them from the scheduler's lanes,
/// never the main thread.
public final class PhotoStore: Sendable {
    public enum Tier: UInt8, Sendable, Hashable, CaseIterable, Codable {
        /// Grid thumbnails, kept for every photo in the library.
        case grid = 0
        /// Previews at screen size, for the loupe and Develop.
        case preview = 1

        /// The long edge, in pixels.
        public var pixelSize: Int {
            switch self {
            case .grid: 384
            case .preview: 2048
            }
        }
    }

    /// The bytes each tier's records may take; nil for no limit.
    public struct Budgets: Sendable, Hashable {
        public var grid: Int64?
        public var preview: Int64?

        public init(grid: Int64? = nil, preview: Int64? = 10 << 30) {
            self.grid = grid
            self.preview = preview
        }

        public subscript(tier: Tier) -> Int64? {
            get { tier == .grid ? grid : preview }
            set {
                if tier == .grid {
                    grid = newValue
                } else {
                    preview = newValue
                }
            }
        }
    }

    public struct Statistics: Sendable, Hashable {
        /// Shards with a pack.
        public var shards = 0
        public var records = 0
        /// The bytes the shards' tables take in memory.
        public var tableBytes = 0
        /// The bytes of the packs and their index files.
        public var fileBytes: Int64 = 0
        public var gridBytes: Int64 = 0
        public var previewBytes: Int64 = 0

        public var tableBytesPerRecord: Double {
            records == 0 ? 0 : Double(tableBytes) / Double(records)
        }
    }

    public static let shardCount = 256
    static let packMagic: [UInt8] = Array("RLPS".utf8)
    static let packVersion: UInt32 = 1
    static let packHeaderLength = 16
    static let packExtension = "rlps"
    static let indexExtension = "rlpi"

    private let slots: [StoreSlot]
    private let state: Mutex<State>
    private let moves = Mutex(())
    private let gridBytes = Atomic<Int64>(0)
    private let previewBytes = Atomic<Int64>(0)
    private let clock: @Sendable () -> Date
    /// Packs kept open to append to, at most: a quarter of the files the process may open, up to
    /// every shard.
    private let descriptorLimit: Int
    private let descriptorCursor = Atomic(0)

    private struct State {
        var root: URL
        var budgets: Budgets
        /// Every shard was opened or found missing, so the totals count all of them.
        var measured = false
        var evicting = false
        /// Tiers a write found over budget while an eviction ran, which it looks at again before it ends.
        var evictAgain: Set<Tier> = []
        var leftoversRemoved = false
    }

    /// A store in `root`, read and written as it's used; `clock` dates each record's last use.
    public init(
        root: URL = LibraryPaths.standard.store, budgets: Budgets = Budgets(),
        clock: @escaping @Sendable () -> Date = { Date() },
    ) {
        slots = (0 ..< Self.shardCount).map { _ in StoreSlot(directory: root) }
        state = Mutex(State(root: root, budgets: budgets))
        self.clock = clock
        var files = rlimit()
        let allowed = getrlimit(RLIMIT_NOFILE, &files) == 0 ? Int(clamping: files.rlim_cur) : 256
        descriptorLimit = max(16, min(Self.shardCount, allowed / 4))
    }

    public var root: URL {
        state.withLock { $0.root }
    }

    public var budgets: Budgets {
        state.withLock { $0.budgets }
    }

    // MARK: - Reading

    /// Whether the store holds the key's `tier` for `edit`.
    public func contains(_ key: ContentKey, tier: Tier, edit: EditDigest = .unedited) -> Bool {
        let key = StoreKey(key)
        let variant = StoreEntry.variant(tier, edit)
        return withShard(key.shard) { shard, _ in shard.table.index(of: key, variant) != nil } ?? false
    }

    /// Whether the store holds the key's `tier` for `edit`, made from the photo file as it is now:
    /// `size` bytes, modified at `modified`.
    public func contains(
        _ key: ContentKey, tier: Tier, edit: EditDigest = .unedited, size: Int64, modified: Date,
    ) -> Bool {
        if case .found = read(StoreKey(key), tier, edit, file: (size, modified), payload: false) {
            return true
        }
        return false
    }

    /// The key's `tier` for `edit`, HEIC or JPEG.
    public func data(for key: ContentKey, tier: Tier, edit: EditDigest = .unedited) -> Data? {
        if case let .found(data) = read(StoreKey(key), tier, edit, file: nil, payload: true) {
            return data
        }
        return nil
    }
}

public extension PhotoStore {
    /// The key's `tier` for `edit`, if it was made from the photo file as it is now.
    func data(
        for key: ContentKey, tier: Tier, edit: EditDigest = .unedited, size: Int64, modified: Date,
    ) -> Data? {
        if case let .found(data) = read(StoreKey(key), tier, edit, file: (size, modified), payload: true) {
            return data
        }
        return nil
    }

    /// The record, read outside the shard's lock; one that fails its checks is removed.
    private func read(
        _ key: StoreKey, _ tier: Tier, _ edit: EditDigest, file: (size: Int64, modified: Date)?, payload: Bool,
    ) -> StoreRecord.Reading {
        let variant = StoreEntry.variant(tier, edit)
        guard let found = withShard(key.shard, { shard, now in
            shard.lookUp(key, variant, touching: payload, now: now)
        }) ?? nil else { return .none }
        let reading = StoreRecord.read(found, key: key, tier: tier, edit: edit, file: file, payload: payload)
        if case .damaged = reading {
            withShard(key.shard) { shard, now in shard.drop([found.entry], now: now) }
        }
        return reading
    }

    // MARK: - Writing

    /// Stores `payload` (HEIC or JPEG) as the key's `tier` for `edit`, made from a photo file of
    /// `size` bytes modified at `modified`, in place of what was there; whether it was stored. A
    /// tier over its budget then loses its least recently used records.
    @discardableResult
    func store(
        _ payload: Data, for key: ContentKey, tier: Tier, edit: EditDigest = .unedited, size: Int64, modified: Date,
    ) -> Bool {
        let key = StoreKey(key)
        let budget = budgets[tier]
        guard !payload.isEmpty,
              let record = StoreRecord.encode(
                  payload,
                  key: key,
                  tier: tier,
                  edit: edit,
                  size: size,
                  modified: modified,
              ),
              budget.map({ Int64(record.header.length) <= $0 }) ?? true
        else { return false }
        let batch = StoreRecord.Batch(record)
        guard withShard(key.shard, creating: true, { shard, now in shard.append(batch, now: now) }) == true else {
            return false
        }
        if let budget {
            keep(tier, within: budget)
        }
        return true
    }

    /// Removes every tier and edit of the key.
    func remove(_ key: ContentKey) {
        let key = StoreKey(key)
        withShard(key.shard) { shard, now in shard.remove(key, tier: nil, edit: .unedited, now: now) }
    }

    /// Removes the key's `tier` for `edit`.
    func remove(_ key: ContentKey, tier: Tier, edit: EditDigest = .unedited) {
        let key = StoreKey(key)
        withShard(key.shard) { shard, now in shard.remove(key, tier: tier, edit: edit, now: now) }
    }

    /// The edits the store holds the key's renders of, in either tier.
    func edits(of key: ContentKey) -> Set<EditDigest> {
        let key = StoreKey(key)
        return withShard(key.shard) { shard, now in Set(shard.edits(of: key, now: now).map(\.edit)) } ?? []
    }

    /// Removes the key's renders of every edit but `keeping`'s, in both tiers, and returns how many
    /// records went: a photo's earlier edits, once it's rendered with its new one (LIB-17). The
    /// unedited photo's tiers stay.
    @discardableResult
    func removeEdits(of key: ContentKey, keeping: Set<EditDigest> = []) -> Int {
        let key = StoreKey(key)
        return withShard(key.shard) { shard, now -> Int in
            let gone = shard.edits(of: key, now: now).filter { !keeping.contains($0.edit) }.map(\.entry)
            guard !gone.isEmpty else { return 0 }
            _ = shard.drop(gone, now: now)
            return gone.count
        } ?? 0
    }

    // MARK: - Budgets

    /// The bytes the tier's records take.
    func size(of tier: Tier) -> Int64 {
        if !state.withLock({ $0.measured }) {
            open()
        }
        return total(tier)
    }

    /// Sets the tier's budget, nil for none; a tier over its new budget loses its least recently
    /// used records now.
    func setBudget(_ bytes: Int64?, for tier: Tier) {
        state.withLock { $0.budgets[tier] = bytes }
        if let bytes {
            keep(tier, within: bytes)
        }
    }

    /// Removes every record of the keys `isIndexed` says the library no longer holds, and returns
    /// how many keys went.
    @discardableResult
    func evict(keepingIndexed isIndexed: (ContentKey) -> Bool) -> Int {
        open()
        var removed = 0
        for number in 0 ..< Self.shardCount {
            guard let keys = withShard(number, { shard, _ in shard.table.keys }) else { continue }
            let gone = keys.filter { !isIndexed($0.contentKey) }
            if !gone.isEmpty {
                removed += withShard(number) { shard, now in shard.remove(keys: gone, now: now) } ?? 0
            }
        }
        return removed
    }

    /// Rewrites every shard with stale records, and returns the bytes that freed.
    @discardableResult
    func compact() -> Int64 {
        var freed: Int64 = 0
        for number in 0 ..< Self.shardCount {
            freed += withShard(number) { shard, now -> Int64 in
                let before = shard.end
                return shard.stale > 0 && shard.compact(now: now) ? Int64(before - shard.end) : 0
            } ?? 0
        }
        return freed
    }

    /// Once the tier is over `budget`, evicts its least recently used records down to nine tenths
    /// of it, one eviction at a time. A write that finds one running leaves it its tier to look at
    /// again before it ends, so no tier stays over its budget after its last write.
    private func keep(_ tier: Tier, within budget: Int64) {
        if !state.withLock({ $0.measured }) {
            open()
        }
        guard total(tier) > budget, state.withLock({ state in
            guard !state.evicting else {
                state.evictAgain.insert(tier)
                return false
            }
            state.evicting = true
            return true
        }) else { return }
        var tiers: Set<Tier> = [tier]
        while !tiers.isEmpty {
            for tier in tiers {
                if let budget = budgets[tier], total(tier) > budget {
                    evictLeastRecentlyUsed(tier, downTo: budget / 10 * 9)
                }
            }
            tiers = state.withLock { state in
                defer { state.evictAgain = [] }
                if state.evictAgain.isEmpty {
                    state.evicting = false
                }
                return state.evictAgain
            }
        }
    }

    /// Drops the tier's least recently used records until it takes `target` bytes or fewer.
    private func evictLeastRecentlyUsed(_ tier: Tier, downTo target: Int64) {
        var candidates: [(entry: StoreEntry, shard: Int)] = []
        for number in 0 ..< Self.shardCount {
            let entries = withShard(number) { shard, _ in shard.table.entries.filter { $0.tier == tier } } ?? []
            candidates += entries.map { ($0, number) }
        }
        candidates.sort { ($0.entry.used, $0.shard, $0.entry.location) < ($1.entry.used, $1.shard, $1.entry.location) }
        var excess = total(tier) - target
        var victims = [[StoreEntry]](repeating: [], count: Self.shardCount)
        for candidate in candidates {
            guard excess > 0 else { break }
            victims[candidate.shard].append(candidate.entry)
            excess -= Int64(candidate.entry.length)
        }
        for (number, entries) in victims.enumerated() where !entries.isEmpty {
            withShard(number) { shard, now in shard.drop(entries, now: now) }
        }
    }

    // MARK: - Shards

    /// Opens every shard now, rather than as each is first used, and measures the store.
    func open() {
        let root = state.withLock { state -> URL? in
            guard !state.leftoversRemoved else { return nil }
            state.leftoversRemoved = true
            return state.root
        }
        if let root {
            StoreFiles.removeLeftovers(in: root)
        }
        DispatchQueue.concurrentPerform(iterations: Self.shardCount) { number in
            withShard(number) { _, _ in }
        }
        state.withLock { $0.measured = true }
    }

    /// Writes each open shard's index file and closes it (tests, and when the app quits); the store
    /// opens them again as they're used.
    func close() {
        let now = Self.seconds(clock())
        DispatchQueue.concurrentPerform(iterations: Self.shardCount) { number in
            slots[number].state.withLock { slot in
                if var shard = slot.shard {
                    if !shard.isIndexCurrent {
                        shard.writeIndex(now: now)
                    }
                    add(TierBytes() - shard.live)
                }
                slot.shard = nil
                slot.absent = false
            }
        }
        state.withLock { $0.measured = false }
    }

    func statistics() -> Statistics {
        open()
        var statistics = Statistics(gridBytes: total(.grid), previewBytes: total(.preview))
        for number in 0 ..< Self.shardCount {
            guard let shard = withShard(number, { shard, _ in
                (records: shard.table.count, table: shard.table.footprint, files: shard.fileBytes)
            }) else { continue }
            statistics.shards += 1
            statistics.records += shard.records
            statistics.tableBytes += shard.table
            statistics.fileBytes += shard.files
        }
        return statistics
    }

    /// Runs `body` on the shard under its lock, opening it first (making it, when `creating`); nil
    /// when it has no pack. The store's totals follow what `body` changes.
    @discardableResult
    private func withShard<T: Sendable>(
        _ number: Int, creating: Bool = false, _ body: (inout StoreShard, UInt32) -> T,
    ) -> T? {
        let now = Self.seconds(clock())
        let result = slots[number].state.withLock { slot -> T? in
            guard openShard(&slot, number, creating: creating, now: now) else { return nil }
            return run(body, on: &slot.shard!, now: now)
        }
        if StoreDescriptor.openCount.load(ordering: .relaxed) > descriptorLimit {
            closeDescriptors(sparing: number)
        }
        return result
    }

    /// `body` on `shard` in place, not on a copy, which would retain the shard's objects on every call.
    private func run<T>(_ body: (inout StoreShard, UInt32) -> T, on shard: inout StoreShard, now: UInt32) -> T {
        let before = shard.live
        let result = body(&shard, now)
        add(shard.live - before)
        return result
    }

    /// Closes other shards' descriptors, skipping any in use, until the process is within the limit.
    private func closeDescriptors(sparing number: Int) {
        for _ in 0 ..< Self.shardCount {
            guard StoreDescriptor.openCount.load(ordering: .relaxed) > descriptorLimit else { return }
            let candidate = descriptorCursor.add(1, ordering: .relaxed).newValue % Self.shardCount
            if candidate != number {
                _ = slots[candidate].state.withLockIfAvailable { slot in slot.shard?.closeDescriptor() }
            }
        }
    }

    private func openShard(_ slot: inout StoreSlot.State, _ number: Int, creating: Bool, now: UInt32) -> Bool {
        guard slot.shard == nil else { return true }
        guard creating || !slot.absent,
              let opened = StoreShard.open(number, in: slot.directory, creating: creating, now: now)
        else {
            slot.absent = !creating
            return false
        }
        slot.shard = opened
        slot.absent = false
        add(opened.live)
        return true
    }

    private func add(_ delta: TierBytes) {
        if delta.grid != 0 {
            gridBytes.add(delta.grid, ordering: .relaxed)
        }
        if delta.preview != 0 {
            previewBytes.add(delta.preview, ordering: .relaxed)
        }
    }

    private func total(_ tier: Tier) -> Int64 {
        tier == .grid ? gridBytes.load(ordering: .relaxed) : previewBytes.load(ordering: .relaxed)
    }

    internal static func seconds(_ date: Date) -> UInt32 {
        UInt32(clamping: Int(date.timeIntervalSinceReferenceDate.rounded(.down)))
    }

    // MARK: - Moving

    /// Moves the store to `destination`, a folder on any disk: each shard is copied there and the
    /// copy checked byte for byte before the shard reads and writes it, then the old files are
    /// removed. A shard waits while it's copied; the others read and write as usual. Throws, with
    /// the store left where it was, when a copy fails or `destination` holds a store already.
    func move(to destination: URL) throws {
        try moves.withLock { _ in
            let source = root
            guard destination.standardizedFileURL.path != source.standardizedFileURL.path else { return }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            guard !names.contains(where: { !$0.hasPrefix(".") && $0.hasSuffix(".\(Self.packExtension)") }) else {
                throw PhotoStoreError.destinationHoldsAStore(destination)
            }
            let now = Self.seconds(clock())
            var moved = 0
            do {
                for number in 0 ..< Self.shardCount {
                    try slots[number].state.withLock { slot in
                        slot.absent = false
                        if openShard(&slot, number, creating: false, now: now) {
                            try slot.shard!.move(to: destination, now: now)
                        }
                        slot.directory = destination
                    }
                    moved += 1
                }
            } catch {
                for number in 0 ..< moved {
                    slots[number].state.withLock { slot in
                        if let shard = slot.shard {
                            add(TierBytes() - shard.live)
                        }
                        slot.shard = nil
                        slot.absent = false
                        slot.directory = source
                    }
                    try? FileManager.default.removeItem(at: StoreShard.packURL(number, in: destination))
                    try? FileManager.default.removeItem(at: StoreShard.indexURL(number, in: destination))
                }
                throw error
            }
            state.withLock { $0.root = destination }
            for number in 0 ..< Self.shardCount {
                try? FileManager.default.removeItem(at: StoreShard.packURL(number, in: source))
                try? FileManager.default.removeItem(at: StoreShard.indexURL(number, in: source))
            }
            StoreFiles.removeLeftovers(in: source, now: .distantFuture)
            if (try? FileManager.default.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: source)
            }
        }
    }
}

/// A shard's place in the store: the folder its files are in, and the shard once it's open.
final class StoreSlot: Sendable {
    struct State {
        var directory: URL
        var shard: StoreShard?
        /// No pack was there when last looked for: reads don't look again until one is stored.
        var absent = false
    }

    let state: Mutex<State>

    init(directory: URL) {
        state = Mutex(State(directory: directory))
    }
}
