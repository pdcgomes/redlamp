import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

/// Writers, readers, compaction, eviction and closing all at once neither corrupt the store nor
/// crash it.
struct PhotoStoreConcurrencyTests {
    static let writers = 8
    static let readers = 8
    static let keysPerWriter = 48
    static let versions = 30

    /// Version `version` of the key's image: the version, then bytes of the key's, its length
    /// varying with the version.
    static func payload(_ key: ContentKey, _ version: Int) -> Data {
        let length = 300 + (version * 397 + Int(key.data[1]) * 13) % 2500
        var data = withUnsafeBytes(of: UInt16(version).littleEndian) { Data($0) }
        data += PhotoStoreTests.payload(key, "v\(version)", length: length)
        return data
    }

    /// The version `data` is of the key's image, if it's one whole.
    static func version(of data: Data, for key: ContentKey) -> Int? {
        guard data.count > 2 else { return nil }
        let version = Int(data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) })
        return data == payload(key, version) ? version : nil
    }

    @Test func `concurrent writers and readers neither corrupt nor crash`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url, budgets: .init(grid: nil, preview: 300_000))
        // Sixteen shards, so records are stored over often enough to compact them.
        let keys = (0 ..< Self.writers * Self.keysPerWriter).map { PhotoStoreTests.key($0, shard: UInt8($0 % 16)) }
        let modified = PhotoStoreTests.modified
        let corrupt = Atomic(0)
        let reads = Atomic(0)
        DispatchQueue.concurrentPerform(iterations: Self.writers + Self.readers + 2) { role in
            var random = SeededRandom(seed: UInt64(role), stream: 3)
            if role < Self.writers {
                let mine = keys[role * Self.keysPerWriter ..< (role + 1) * Self.keysPerWriter]
                for version in 0 ..< Self.versions {
                    for key in mine.shuffled(using: &random) {
                        store.store(Self.payload(key, version), for: key, tier: .grid, size: 1, modified: modified)
                        if version % 5 == 0 {
                            store.store(
                                Self.payload(key, version),
                                for: key,
                                tier: .preview,
                                size: 1,
                                modified: modified,
                            )
                        }
                    }
                }
            } else if role < Self.writers + Self.readers {
                for _ in 0 ..< 4000 {
                    let key = keys[random.int(below: keys.count)]
                    for tier in PhotoStore.Tier.allCases {
                        guard let data = store.data(for: key, tier: tier) else { continue }
                        reads.add(1, ordering: .relaxed)
                        if Self.version(of: data, for: key) == nil {
                            corrupt.add(1, ordering: .relaxed)
                        }
                    }
                }
            } else if role == Self.writers + Self.readers {
                for _ in 0 ..< 20 {
                    store.compact()
                    store.evict(keepingIndexed: { _ in true })
                    _ = store.statistics()
                }
            } else {
                for _ in 0 ..< 10 {
                    store.close()
                    usleep(5000)
                }
            }
        }
        #expect(corrupt.load(ordering: .relaxed) == 0)
        #expect(reads.load(ordering: .relaxed) > 1000)
        func check(_ store: PhotoStore) {
            for key in keys {
                let grid = store.data(for: key, tier: .grid)
                #expect(grid.flatMap { Self.version(of: $0, for: key) } == Self.versions - 1)
                if let preview = store.data(for: key, tier: .preview) {
                    #expect(Self.version(of: preview, for: key) != nil)
                }
            }
            #expect(store.size(of: .preview) <= 300_000)
        }
        check(store)
        store.close()
        check(PhotoStore(root: folder.url))
    }
}
