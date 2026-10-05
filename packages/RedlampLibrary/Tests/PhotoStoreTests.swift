import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

/// The store keeps what it's given by content key, tier and edit, across reopening, compaction,
/// eviction and moves, and never trusts a shard it can't read.
struct PhotoStoreTests {
    static let modified = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A key of its own for `number`, in `shard` when given.
    static func key(_ number: Int, shard: UInt8? = nil) -> ContentKey {
        var random = SeededRandom(seed: UInt64(number), stream: 409)
        var bytes = withUnsafeBytes(of: (random.next(), random.next())) { Array($0) }
        if let shard {
            bytes[0] = shard
        }
        return ContentKey(data: Data(bytes))!
    }

    /// Bytes that differ for each key and label.
    static func payload(_ key: ContentKey, _ label: String = "", length: Int = 1000) -> Data {
        let seed = Array(key.data) + Array(label.utf8)
        return Data((0 ..< length).map { seed[$0 % seed.count] &+ UInt8(truncatingIfNeeded: $0 / seed.count) })
    }

    @discardableResult
    static func store(
        _ store: PhotoStore, _ key: ContentKey, _ label: String = "", tier: PhotoStore.Tier = .grid,
        edit: EditDigest = .unedited, length: Int = 1000,
    ) -> Data {
        let payload = payload(key, label, length: length)
        #expect(store.store(payload, for: key, tier: tier, edit: edit, size: 5000, modified: modified))
        return payload
    }

    static func pack(_ shard: Int, in folder: URL) -> URL {
        folder.appending(path: String(format: "%02x.rlps", shard))
    }

    static func index(_ shard: Int, in folder: URL) -> URL {
        folder.appending(path: String(format: "%02x.rlpi", shard))
    }

    static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    /// A record's bytes in a pack, for a payload of `length`.
    static func recordLength(_ length: Int) -> Int {
        (StoreRecord.headerLength + length + 7) / 8 * 8
    }

    @Test func `a stored record reads back as it was stored, and only for its own file`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let key = Self.key(1)
        #expect(store.data(for: key, tier: .grid) == nil && !store.contains(key, tier: .grid))
        let payload = Self.payload(key)
        #expect(store.store(payload, for: key, tier: .grid, size: 1234, modified: Self.modified))
        #expect(store.contains(key, tier: .grid) && store.data(for: key, tier: .grid) == payload)
        #expect(store.contains(key, tier: .grid, size: 1234, modified: Self.modified))
        #expect(store.data(for: key, tier: .grid, size: 1234, modified: Self.modified) == payload)
        #expect(!store.contains(key, tier: .grid, size: 1235, modified: Self.modified))
        #expect(store.data(for: key, tier: .grid, size: 1234, modified: Self.modified + 1) == nil)
        #expect(!store.contains(Self.key(2), tier: .grid) && !store.contains(key, tier: .preview))
        #expect(!store.store(Data(), for: key, tier: .grid, size: 1, modified: Self.modified))
        #expect(FileManager.default.fileExists(atPath: Self.pack(Int(key.data[0]), in: folder.url).path))
        #expect(store.statistics().records == 1)
    }

    @Test func `the last record for a key wins`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let key = Self.key(3)
        Self.store(store, key, "first", length: 800)
        Self.store(store, key, "second", length: 3000)
        let last = Self.store(store, key, "third", length: 1500)
        #expect(store.data(for: key, tier: .grid) == last)
        #expect(store.size(of: .grid) == Int64(Self.recordLength(1500)))
        store.close()
        let reopened = PhotoStore(root: folder.url)
        #expect(reopened.data(for: key, tier: .grid) == last)
        #expect(reopened.statistics().records == 1)
    }

    @Test func `tiers and edit digests are separate`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let key = Self.key(4)
        let brighter = EditDigest(hashing: Data(#"{"exposure":1}"#.utf8))
        let darker = EditDigest(hashing: Data(#"{"exposure":-1}"#.utf8))
        let stored: [(PhotoStore.Tier, EditDigest, Data)] = [
            (.grid, .unedited, Self.store(store, key, "grid")),
            (.preview, .unedited, Self.store(store, key, "preview", tier: .preview, length: 4000)),
            (.grid, brighter, Self.store(store, key, "grid brighter", edit: brighter)),
            (.grid, darker, Self.store(store, key, "grid darker", edit: darker)),
            (.preview, brighter, Self.store(store, key, "preview brighter", tier: .preview, edit: brighter)),
        ]
        for (tier, edit, payload) in stored {
            #expect(store.data(for: key, tier: tier, edit: edit) == payload, "\(tier) \(edit)")
        }
        #expect(store.data(for: key, tier: .preview, edit: darker) == nil)

        store.remove(key, tier: .grid, edit: brighter)
        #expect(!store.contains(key, tier: .grid, edit: brighter))
        #expect(store.data(for: key, tier: .grid, edit: darker) == stored[3].2)
        #expect(store.data(for: key, tier: .preview, edit: brighter) == stored[4].2)
        store.close()
        let reopened = PhotoStore(root: folder.url)
        #expect(!reopened.contains(key, tier: .grid, edit: brighter))
        #expect(reopened.data(for: key, tier: .grid) == stored[0].2)
        reopened.remove(key)
        #expect(PhotoStore.Tier.allCases.allSatisfy { tier in
            [EditDigest.unedited, brighter, darker].allSatisfy { !reopened.contains(key, tier: tier, edit: $0) }
        })
        #expect(reopened.size(of: .grid) == 0 && reopened.size(of: .preview) == 0)
    }

    @Test func `an edit whose digest begins as another's never reads the other's image`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let key = Self.key(5)
        let first = try #require(EditDigest(data: Data([0xAB, 0xCD, 0xEF, 0x12] + Array(repeating: 1, count: 12))))
        let second = try #require(EditDigest(data: Data([0xAB, 0xCD, 0xEF, 0x12] + Array(repeating: 2, count: 12))))
        Self.store(store, key, "first", edit: first)
        let later = Self.store(store, key, "second", edit: second)
        #expect(store.data(for: key, tier: .grid, edit: first) == nil)
        #expect(store.data(for: key, tier: .grid, edit: second) == later)
    }

    @Test func `a reopened store finds everything, from its index files or from the packs alone`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let edit = EditDigest(hashing: Data("crop".utf8))
        var expected: [(ContentKey, PhotoStore.Tier, EditDigest, Data)] = []
        for number in 0 ..< 2000 {
            let key = Self.key(number)
            expected.append((key, .grid, .unedited, Self.store(store, key, length: 200 + number % 300)))
            if number % 10 == 0 {
                expected.append((key, .preview, .unedited, Self.store(store, key, "p", tier: .preview, length: 3000)))
            }
            if number % 7 == 0 {
                expected.append((key, .grid, edit, Self.store(store, key, "e", edit: edit)))
            }
        }
        for number in stride(from: 0, to: 2000, by: 50) {
            store.remove(Self.key(number), tier: .grid)
        }
        let removed = Set(stride(from: 0, to: 2000, by: 50).map { Self.key($0) })
        let present = expected.filter { !($0.1 == .grid && $0.2 == .unedited && removed.contains($0.0)) }
        func check(_ store: PhotoStore, _ records: [(ContentKey, PhotoStore.Tier, EditDigest, Data)]) {
            #expect(records.allSatisfy { store.data(for: $0.0, tier: $0.1, edit: $0.2) == $0.3 })
            #expect(removed.allSatisfy { !store.contains($0, tier: .grid) })
            #expect(store.statistics().records == records.count)
        }
        let size = store.size(of: .grid)
        store.close()
        let shards = (0 ..< 256).filter { FileManager.default.fileExists(atPath: Self.pack($0, in: folder.url).path) }
        #expect(shards.count > 200)
        #expect(shards.allSatisfy { FileManager.default.fileExists(atPath: Self.index($0, in: folder.url).path) })
        check(PhotoStore(root: folder.url), present)
        #expect(PhotoStore(root: folder.url).size(of: .grid) == size)

        for shard in shards {
            try FileManager.default.removeItem(at: Self.index(shard, in: folder.url))
        }
        let scanned = PhotoStore(root: folder.url)
        check(scanned, present)
        #expect(scanned.size(of: .grid) == size)
        scanned.close()

        let unclosed = PhotoStore(root: folder.url)
        var added = present
        for number in 2000 ..< 2300 {
            let key = Self.key(number)
            added.append((key, PhotoStore.Tier.grid, EditDigest.unedited, Self.store(unclosed, key)))
        }
        check(PhotoStore(root: folder.url), added)
    }

    @Test func `compaction keeps live records and drops stale ones`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let keys = (0 ..< 20).map { Self.key($0, shard: 7) }
        let pack = Self.pack(7, in: folder.url)
        let record = Self.recordLength(2000)
        for key in keys {
            Self.store(store, key, "v1", length: 2000)
        }
        #expect(Self.size(pack) == PhotoStore.packHeaderLength + 20 * record)
        var latest = [ContentKey: Data]()
        for key in keys.prefix(10) {
            latest[key] = Self.store(store, key, "v2", length: 2000)
        }
        // 10 of 30 records stale: not yet more than a third.
        #expect(Self.size(pack) == PhotoStore.packHeaderLength + 30 * record)
        let generation = try Data(contentsOf: pack).subdata(in: 8 ..< 16)
        latest[keys[10]] = Self.store(store, keys[10], "v2", length: 2000)
        #expect(Self.size(pack) == PhotoStore.packHeaderLength + 20 * record)
        #expect(try Data(contentsOf: pack).subdata(in: 8 ..< 16) != generation)
        for key in keys {
            #expect(store.data(for: key, tier: .grid) == (latest[key] ?? Self.payload(key, "v1", length: 2000)))
        }

        store.remove(keys[0])
        #expect(store.compact() == Int64(record + StoreRecord.headerLength))
        #expect(Self.size(pack) == PhotoStore.packHeaderLength + 19 * record)
        #expect(store.compact() == 0)
        store.close()
        let reopened = PhotoStore(root: folder.url)
        #expect(!reopened.contains(keys[0], tier: .grid))
        #expect(keys.dropFirst().allSatisfy { reopened.data(for: $0, tier: .grid) != nil })
        #expect(reopened.size(of: .grid) == Int64(19 * record))
    }

    @Test func `previews over their budget go least recently used first, and grid thumbnails stay`() throws {
        let folder = try TemporaryFolder()
        let clock = StoreTestClock()
        let record = Self.recordLength(2000)
        let store = PhotoStore(
            root: folder.url, budgets: .init(grid: nil, preview: Int64(10 * record)), clock: clock.now,
        )
        let keys = (0 ..< 11).map { Self.key(100 + $0) }
        for key in keys.prefix(10) {
            clock.advance(10)
            Self.store(store, key, "preview", tier: .preview, length: 2000)
            Self.store(store, key, "grid", length: 2000)
        }
        clock.advance(100)
        #expect(store.data(for: keys[0], tier: .preview) != nil)
        clock.advance(1)
        #expect(store.data(for: keys[1], tier: .preview) != nil)
        clock.advance(10)
        Self.store(store, keys[10], "preview", tier: .preview, length: 2000)

        let kept = keys.map { store.contains($0, tier: .preview) }
        #expect(kept == [true, true, false, false, true, true, true, true, true, true, true])
        #expect(store.size(of: .preview) == Int64(9 * record))
        #expect(keys.prefix(10).allSatisfy { store.contains($0, tier: .grid) })
        store.close()
        let reopened = PhotoStore(root: folder.url)
        #expect(keys.map { reopened.contains($0, tier: .preview) } == kept)

        reopened.setBudget(Int64(3 * record), for: .preview)
        #expect(reopened.size(of: .preview) <= Int64(3 * record))
        #expect(reopened.contains(keys[10], tier: .preview) && !reopened.contains(keys[4], tier: .preview))
        #expect(!reopened.store(
            Data(count: 4 * record),
            for: keys[5],
            tier: .preview,
            size: 1,
            modified: Self.modified,
        ))
    }

    @Test func `grid thumbnails go only for photos no longer indexed, or under a budget the user sets`() throws {
        let folder = try TemporaryFolder()
        let clock = StoreTestClock()
        let store = PhotoStore(root: folder.url, clock: clock.now)
        let keys = (0 ..< 40).map { Self.key(200 + $0) }
        for key in keys {
            clock.advance(1)
            Self.store(store, key)
        }
        for key in keys.prefix(5) + keys.suffix(5) {
            Self.store(store, key, "preview", tier: .preview)
        }
        let indexed = Set(keys.prefix(30))
        #expect(store.evict(keepingIndexed: { indexed.contains($0) }) == 10)
        #expect(keys.prefix(30).allSatisfy { store.contains($0, tier: .grid) })
        #expect(keys.suffix(10).allSatisfy { !store.contains($0, tier: .grid) && !store.contains($0, tier: .preview) })
        #expect(keys.prefix(5).allSatisfy { store.contains($0, tier: .preview) })
        #expect(store.evict(keepingIndexed: { indexed.contains($0) }) == 0)

        clock.advance(100)
        for key in keys.suffix(15).prefix(5) {
            #expect(store.data(for: key, tier: .grid) != nil)
        }
        let record = Int64(Self.recordLength(1000))
        store.setBudget(10 * record, for: .grid)
        #expect(store.size(of: .grid) <= 10 * record)
        #expect(keys.suffix(15).prefix(5).allSatisfy { store.contains($0, tier: .grid) })
        #expect(!store.contains(keys[0], tier: .grid) && store.contains(keys[0], tier: .preview))
        store.close()
        let reopened = PhotoStore(root: folder.url)
        #expect(reopened.size(of: .grid) <= 10 * record)
        #expect(keys.suffix(15).prefix(5).allSatisfy { reopened.contains($0, tier: .grid) })
    }

    @Test func `a truncated shard is rewritten with the records before the cut`() throws {
        let folder = try TemporaryFolder()
        let keys = (0 ..< 10).map { Self.key($0, shard: 3) }
        let pack = Self.pack(3, in: folder.url)
        let store = PhotoStore(root: folder.url)
        for key in keys {
            Self.store(store, key)
        }
        store.close()
        let generation = try Data(contentsOf: pack).subdata(in: 8 ..< 16)
        let handle = try FileHandle(forWritingTo: pack)
        try handle.truncate(atOffset: UInt64(Self.size(pack) - 500))
        try handle.close()

        let reopened = PhotoStore(root: folder.url)
        #expect(keys.prefix(9).allSatisfy { reopened.data(for: $0, tier: .grid) == Self.payload($0) })
        #expect(!reopened.contains(keys[9], tier: .grid))
        #expect(Self.size(pack) == PhotoStore.packHeaderLength + 9 * Self.recordLength(1000))
        let rewritten = try Data(contentsOf: pack)
        #expect(Array(rewritten.prefix(4)) == Array("RLPS".utf8) && rewritten.subdata(in: 8 ..< 16) != generation)
        Self.store(reopened, keys[9])
        reopened.close()
        #expect(keys.allSatisfy { PhotoStore(root: folder.url).data(for: $0, tier: .grid) == Self.payload($0) })
    }

    @Test func `a file that isn't a pack is replaced, not trusted`() throws {
        let folder = try TemporaryFolder()
        var random = SeededRandom(seed: 5)
        let garbage = Data((0 ..< 10000).map { _ in UInt8(truncatingIfNeeded: random.next()) })
        try garbage.write(to: Self.pack(5, in: folder.url))
        try garbage.prefix(500).write(to: Self.index(5, in: folder.url))
        try Data().write(to: Self.pack(6, in: folder.url))
        var header = Data("RLPS".utf8)
        header += withUnsafeBytes(of: UInt32(1).littleEndian) { Data($0) }
        header += withUnsafeBytes(of: UInt64(42).littleEndian) { Data($0) }
        try (header + garbage).write(to: Self.pack(8, in: folder.url))

        let store = PhotoStore(root: folder.url)
        for shard: UInt8 in [5, 6, 8] {
            let key = Self.key(Int(shard), shard: shard)
            #expect(!store.contains(key, tier: .grid))
            let pack = try Data(contentsOf: Self.pack(Int(shard), in: folder.url))
            #expect(pack.count == PhotoStore.packHeaderLength && Array(pack.prefix(4)) == Array("RLPS".utf8))
            Self.store(store, key)
        }
        store.close()
        let reopened = PhotoStore(root: folder.url)
        for shard: UInt8 in [5, 6, 8] {
            let key = Self.key(Int(shard), shard: shard)
            #expect(reopened.data(for: key, tier: .grid) == Self.payload(key))
        }
    }

    @Test func `a damaged record or index file isn't trusted`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let damaged = (0 ..< 5).map { Self.key($0, shard: 9) }
        let indexed = (0 ..< 5).map { Self.key($0, shard: 10) }
        for key in damaged + indexed {
            Self.store(store, key)
        }
        store.close()
        let pack = Self.pack(9, in: folder.url)
        var bytes = try Data(contentsOf: pack)
        bytes[PhotoStore.packHeaderLength + 2 * Self.recordLength(1000) + StoreRecord.headerLength + 100] ^= 0x40
        try bytes.write(to: pack)
        try Data(repeating: 7, count: 300).write(to: Self.index(10, in: folder.url))

        let reopened = PhotoStore(root: folder.url)
        #expect(reopened.contains(damaged[2], tier: .grid))
        #expect(reopened.data(for: damaged[2], tier: .grid) == nil)
        #expect(!reopened.contains(damaged[2], tier: .grid))
        #expect([0, 1, 3, 4].allSatisfy { reopened.data(for: damaged[$0], tier: .grid) == Self.payload(damaged[$0]) })
        #expect(indexed.allSatisfy { reopened.data(for: $0, tier: .grid) == Self.payload($0) })
        reopened.close()
        #expect(!PhotoStore(root: folder.url).contains(damaged[2], tier: .grid))
    }

    @Test func `moving the store keeps everything, and its old files go`() throws {
        let folder = try TemporaryFolder()
        let source = folder.url.appending(path: "Store", directoryHint: .isDirectory)
        let destination = folder.url.appending(path: "Elsewhere/Thumbnails", directoryHint: .isDirectory)
        let store = PhotoStore(root: source)
        let edit = EditDigest(hashing: Data("black and white".utf8))
        var expected: [(ContentKey, PhotoStore.Tier, EditDigest, Data)] = []
        for number in 0 ..< 600 {
            let key = Self.key(number)
            expected.append((key, .grid, .unedited, Self.store(store, key)))
            if number % 6 == 0 {
                expected.append((key, .preview, .unedited, Self.store(store, key, "p", tier: .preview, length: 5000)))
                expected.append((key, .grid, edit, Self.store(store, key, "e", edit: edit)))
            }
        }
        let size = store.size(of: .preview)
        let packs = try FileManager.default.contentsOfDirectory(atPath: source.path).count { $0.hasSuffix(".rlps") }
        try store.move(to: destination)
        #expect(store.root == destination)
        #expect(expected.allSatisfy { store.data(for: $0.0, tier: $0.1, edit: $0.2) == $0.3 })
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let moved = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(moved.count(where: { $0.hasSuffix(".rlps") }) == packs && packs > 200)
        #expect(!moved.contains(where: { $0.hasPrefix(".") }))

        let late = Self.key(9999)
        expected.append((late, .grid, .unedited, Self.store(store, late)))
        store.close()
        let reopened = PhotoStore(root: destination)
        #expect(expected.allSatisfy { reopened.data(for: $0.0, tier: $0.1, edit: $0.2) == $0.3 })
        #expect(reopened.size(of: .preview) == size)
    }

    @Test func `moving to a folder that holds a store fails and leaves the store where it was`() throws {
        let folder = try TemporaryFolder()
        let source = folder.url.appending(path: "Store", directoryHint: .isDirectory)
        let other = folder.url.appending(path: "Other", directoryHint: .isDirectory)
        let store = PhotoStore(root: source)
        let key = Self.key(1)
        let payload = Self.store(store, key)
        let otherStore = PhotoStore(root: other)
        Self.store(otherStore, Self.key(2))
        otherStore.close()

        #expect(throws: PhotoStoreError.destinationHoldsAStore(other)) { try store.move(to: other) }
        #expect(store.root == source && store.data(for: key, tier: .grid) == payload)
        #expect(!PhotoStore(root: other).contains(key, tier: .grid))
    }

    @Test func `a table takes under 40 bytes a record`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let payload = Data(repeating: 1, count: 100)
        for number in 0 ..< 30000 {
            store.store(payload, for: Self.key(number), tier: .grid, size: 1, modified: Self.modified)
        }
        let written = store.statistics()
        #expect(written.records == 30000 && written.tableBytesPerRecord < 40, "\(written.tableBytesPerRecord)")
        store.close()
        let reopened = PhotoStore(root: folder.url).statistics()
        #expect(reopened.records == 30000 && reopened.tableBytesPerRecord < 40, "\(reopened.tableBytesPerRecord)")
    }
}

/// A clock the test moves on.
final class StoreTestClock: Sendable {
    private let time = Mutex(PhotoStoreTests.modified)

    var now: @Sendable () -> Date {
        { [self] in time.withLock { $0 } }
    }

    func advance(_ seconds: TimeInterval) {
        time.withLock { $0 += seconds }
    }
}
