import Foundation

/// The bytes a tier's records take.
struct TierBytes: Equatable {
    var grid: Int64 = 0
    var preview: Int64 = 0

    subscript(tier: PhotoStore.Tier) -> Int64 {
        get { tier == .grid ? grid : preview }
        set {
            if tier == .grid {
                grid = newValue
            } else {
                preview = newValue
            }
        }
    }

    static func - (lhs: TierBytes, rhs: TierBytes) -> TierBytes {
        TierBytes(grid: lhs.grid - rhs.grid, preview: lhs.preview - rhs.preview)
    }
}

/// One of the store's 256 shards: its pack, mapped, and the table of the records it holds. Every
/// call is made under its slot's lock.
///
/// Records are appended in one write each, with `O_APPEND`, through a descriptor the shard keeps
/// from its first write. The pack is rewritten with only its live records, and renamed over the
/// old one, once more than a third of it is stale, and its index file is written whenever
/// `indexInterval` records (or a quarter of the table) were appended since the last, after a
/// compaction, and when the store closes.
struct StoreShard {
    /// Records appended between index files, at least.
    static let indexInterval = 1024
    /// As long as a table's 32-bit offsets reach.
    static let maxPackLength = Int(UInt32.max) * StoreRecord.alignment

    let number: Int
    private(set) var directory: URL
    private(set) var generation: UInt64
    private(set) var mapping: StoreMapping
    /// The file the pack's path named when this process last wrote or mapped it.
    private(set) var identity: FileIdentity
    private var descriptor: StoreDescriptor?
    private(set) var table = StoreTable()
    /// The pack's length, as far as this process knows.
    private(set) var end = PhotoStore.packHeaderLength
    /// Bytes of the pack no entry points at: records stored over or removed, and the removals.
    private(set) var stale = 0
    private(set) var live = TierBytes()
    private(set) var indexBytes = 0
    private(set) var isIndexCurrent = true
    /// False once an append left part of a record that couldn't be rewritten away.
    private(set) var isWritable = true
    private var appendedSinceIndex = 0

    private init(number: Int, directory: URL, generation: UInt64, mapping: StoreMapping) {
        self.number = number
        self.directory = directory
        self.generation = generation
        self.mapping = mapping
        identity = mapping.identity
    }

    static func name(_ number: Int) -> String {
        String(format: "%02x", number)
    }

    static func packURL(_ number: Int, in directory: URL) -> URL {
        directory.appending(path: "\(name(number)).\(PhotoStore.packExtension)")
    }

    static func indexURL(_ number: Int, in directory: URL) -> URL {
        directory.appending(path: "\(name(number)).\(PhotoStore.indexExtension)")
    }

    var packURL: URL {
        Self.packURL(number, in: directory)
    }

    var indexURL: URL {
        Self.indexURL(number, in: directory)
    }

    var fileBytes: Int64 {
        Int64(end + indexBytes)
    }

    var hasDescriptor: Bool {
        descriptor != nil
    }

    /// Closes the pack's descriptor until the shard next writes.
    mutating func closeDescriptor() {
        descriptor = nil
    }

    // MARK: - Opening

    /// The shard's pack in `directory`, its table read from its index file and the records written
    /// after it. A file that isn't a pack (`RLPS`, version 1) is replaced by a new one, renamed over
    /// it rather than truncated, which would break another process's mapping; a pack whose records
    /// stop short of its end is rewritten with those before. Nil when there's no pack and
    /// `creating` is false, or it can't be read or made.
    static func open(_ number: Int, in directory: URL, creating: Bool, now: UInt32) -> StoreShard? {
        let pack = packURL(number, in: directory)
        var mapping = StoreMapping(url: pack)
        var generation = mapping.flatMap(Self.generation)
        var created: StoreDescriptor?
        if generation == nil {
            let exists = FileManager.default.fileExists(atPath: pack.path)
            guard exists || creating else { return nil }
            if !exists {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            created = StoreFiles.replace(pack, with: header(newGeneration()), exclusive: !exists)
            if created != nil {
                try? FileManager.default.removeItem(at: indexURL(number, in: directory))
            }
            mapping = StoreMapping(url: pack)
            generation = mapping.flatMap(Self.generation)
        }
        guard let mapping, let generation else { return nil }
        var shard = StoreShard(number: number, directory: directory, generation: generation, mapping: mapping)
        if let created, created.identity == mapping.identity {
            shard.descriptor = created
        }
        var start = PhotoStore.packHeaderLength
        var used: UInt32 = 0
        if let data = try? Data(contentsOf: shard.indexURL),
           let contents = StoreIndexFile.decode(data, generation: generation, packLength: mapping.count) {
            shard.table = contents.table
            shard.stale = contents.stale
            shard.indexBytes = data.count
            start = contents.covered
            used = contents.written
            for entry in contents.table.entries {
                shard.live[entry.tier] += Int64(entry.length)
            }
        }
        let (end, records) = shard.scan(from: start, used: used)
        shard.end = end
        if end < mapping.count {
            shard.isIndexCurrent = false
            if !shard.compact(now: now) {
                shard.isWritable = false
            }
        } else if records > 0 || shard.indexBytes == 0 {
            shard.appendedSinceIndex = records
            shard.isIndexCurrent = false
        }
        return shard
    }

    /// A pack's generation, if it's one this version reads.
    private static func generation(of mapping: StoreMapping) -> UInt64? {
        let bytes = mapping.bytes
        guard bytes.count >= PhotoStore.packHeaderLength, Array(bytes.prefix(4)) == PhotoStore.packMagic,
              UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) == PhotoStore.packVersion
        else { return nil }
        return UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
    }

    private static func newGeneration() -> UInt64 {
        UInt64.random(in: 1 ... .max)
    }

    private static func header(_ generation: UInt64) -> Data {
        var header = Data(PhotoStore.packMagic)
        withUnsafeBytes(of: PhotoStore.packVersion.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: generation.littleEndian) { header.append(contentsOf: $0) }
        return header
    }

    /// Reads the records from `start` into the table, each last used at `used`, up to the first
    /// that isn't whole: where that is, and how many it read.
    private mutating func scan(from start: Int, used: UInt32) -> (end: Int, records: Int) {
        let mapping = mapping
        return withExtendedLifetime(mapping) {
            var offset = start
            var records = 0
            while offset / StoreRecord.alignment <= Int(UInt32.max),
                  let header = StoreRecord.header(in: mapping.bytes, at: offset) {
                apply(header, at: offset, used: used)
                offset += header.length
                records += 1
            }
            return (offset, records)
        }
    }

    private mutating func apply(_ header: StoreRecord.Header, at offset: Int, used: UInt32) {
        if header.isRemoval {
            applyRemoval(header)
            stale += header.length
            return
        }
        let entry = StoreEntry(
            high: header.key.high, low: header.key.low, variant: header.variant, used: used,
            location: UInt32(offset / StoreRecord.alignment), length: UInt32(header.length),
        )
        if let replaced = table.upsert(entry) {
            discount(replaced)
        }
        live[header.tier] += Int64(header.length)
    }

    private mutating func applyRemoval(_ header: StoreRecord.Header) {
        if header.removesEveryVariant {
            for removed in table.removeAll(header.key) {
                discount(removed)
            }
        } else if let index = table.index(of: header.key, header.variant) {
            discount(table.remove(at: index))
        }
    }

    private mutating func discount(_ entry: StoreEntry) {
        stale += Int(entry.length)
        live[entry.tier] -= Int64(entry.length)
    }

    /// Opens the pack again from its file, which another process replaced.
    private mutating func reload(now: UInt32) -> Bool {
        descriptor = nil
        guard let reopened = Self.open(number, in: directory, creating: true, now: now) else { return false }
        self = reopened
        return true
    }

    /// Maps the pack again, now that it's longer.
    private mutating func remap(now: UInt32) -> Bool {
        guard let fresh = descriptor.flatMap({ StoreMapping(descriptor: $0.descriptor) }) ?? StoreMapping(url: packURL)
        else { return false }
        guard fresh.identity == identity else { return reload(now: now) }
        mapping = fresh
        return true
    }

    // MARK: - Reading

    /// The entry for the key's tier and edit and a mapping that holds its record, last used `now`
    /// when `touching`.
    mutating func lookUp(_ key: StoreKey, _ variant: UInt32, touching: Bool, now: UInt32) -> StoreLookup? {
        guard var index = table.index(of: key, variant) else { return nil }
        if table[index].offset + Int(table[index].length) > mapping.count {
            guard remap(now: now), let found = table.index(of: key, variant),
                  table[found].offset + Int(table[found].length) <= mapping.count
            else { return nil }
            index = found
        }
        if touching, table[index].used != now {
            table[index].used = now
            isIndexCurrent = false
        }
        return StoreLookup(entry: table[index], mapping: mapping)
    }

    /// The header of `entry`'s record, if it's mapped and whole.
    private func header(of entry: StoreEntry) -> StoreRecord.Header? {
        withExtendedLifetime(mapping) { StoreRecord.header(in: mapping.bytes, at: entry.offset) }
    }

    // MARK: - Writing

    /// Appends `batch` in one write and adds its records to the table; false when it wasn't
    /// written, and the table is as it was.
    mutating func append(_ batch: StoreRecord.Batch, now: UInt32) -> Bool {
        guard isWritable, !batch.isEmpty else { return false }
        for attempt in 0 ..< 2 {
            guard end + batch.bytes.count <= Self.maxPackLength else { return false }
            if descriptor == nil {
                let opened = StoreDescriptor(url: packURL)
                guard let opened, opened.identity == identity else {
                    guard attempt == 0, reload(now: now) else { return false }
                    continue
                }
                descriptor = opened
            }
            switch descriptor!.append(batch.bytes) {
            case let .at(offset):
                guard offset >= end, offset % StoreRecord.alignment == 0 else {
                    // After bytes this process didn't write and can't place: rewritten without them.
                    isIndexCurrent = false
                    guard compact(now: now), attempt == 0 else { return false }
                    continue
                }
                stale += offset - end
                var at = offset
                for header in batch.headers {
                    apply(header, at: at, used: now)
                    at += header.length
                }
                end = at
                appendedSinceIndex += batch.headers.count
                isIndexCurrent = false
                if stale * 3 > end {
                    compact(now: now)
                } else if appendedSinceIndex >= max(Self.indexInterval, table.count / 4) {
                    writeIndex(now: now)
                }
                return true
            case let .failed(partial):
                if partial {
                    isIndexCurrent = false
                    isWritable = compact(now: now)
                }
                return false
            }
        }
        return false
    }

    /// Removes what `removals` name and appends them, so the pack agrees when it's next read. When
    /// they can't be written they're removed from the table anyway, which the index file keeps.
    mutating func remove(_ removals: StoreRecord.Batch, now: UInt32) {
        guard !removals.isEmpty, !append(removals, now: now) else { return }
        for header in removals.headers {
            applyRemoval(header)
        }
        isIndexCurrent = false
    }

    /// Removes the key's record of `tier` and `edit`, or with no tier every one of the key's;
    /// whether there was any.
    mutating func remove(_ key: StoreKey, tier: PhotoStore.Tier?, edit: EditDigest, now: UInt32) -> Bool {
        var batch = StoreRecord.Batch()
        if let tier {
            guard table.index(of: key, StoreEntry.variant(tier, edit)) != nil else { return false }
            batch.append(StoreRecord.removal(of: key, tier: tier, edit: edit))
        } else {
            guard holds(key) else { return false }
            batch.append(StoreRecord.removal(of: key))
        }
        remove(batch, now: now)
        return true
    }

    /// Removes every record of each of `keys`; how many of them had any.
    mutating func remove(keys: [StoreKey], now: UInt32) -> Int {
        var batch = StoreRecord.Batch()
        for key in keys where holds(key) {
            batch.append(StoreRecord.removal(of: key))
        }
        remove(batch, now: now)
        return batch.headers.count
    }

    /// Whether the table has any tier or edit of `key`.
    func holds(_ key: StoreKey) -> Bool {
        let start = table.lowerBound(key, 0)
        return start < table.count && table[start].key == key
    }

    /// Removes those of `entries` still in the table as they were; the bytes they took.
    mutating func drop(_ entries: [StoreEntry], now: UInt32) -> Int64 {
        var batch = StoreRecord.Batch()
        var dropped: Int64 = 0
        for entry in entries {
            guard let index = table.index(of: entry.key, entry.variant), table[index].location == entry.location
            else { continue }
            let edit = header(of: entry)?.edit ?? EditDigest(high: UInt64(entry.variant & 0x7FFF_FFFF) << 33, low: 0)
            batch.append(StoreRecord.removal(of: entry.key, tier: entry.tier, edit: edit))
            dropped += Int64(entry.length)
        }
        remove(batch, now: now)
        return dropped
    }

    // MARK: - Compacting and the index file

    /// Writes the live records to a new pack, synced and renamed over this one, then its index
    /// file. Records whose checksums fail are left out.
    @discardableResult
    mutating func compact(now: UInt32) -> Bool {
        guard mapping.count >= end || remap(now: now), mapping.count >= end else { return false }
        let generation = Self.newGeneration()
        guard let file = StagingFile(beside: packURL) else { return false }
        file.write(Self.header(generation))
        let mapping = mapping
        var locations = [UInt32](repeating: 0, count: table.count)
        var damaged: [Int] = []
        var offset = PhotoStore.packHeaderLength
        withExtendedLifetime(mapping) {
            let bytes = mapping.bytes
            for index in table.entries.indices.sorted(by: { table[$0].location < table[$1].location }) {
                let entry = table[index]
                guard let header = StoreRecord.header(in: bytes, at: entry.offset), header.length == Int(entry.length),
                      header.key == entry.key, header.variant == entry.variant, !header.isRemoval,
                      StoreChecksum.of(StoreRecord.payload(in: bytes, at: entry.offset, header: header))
                      == header.payloadChecksum
                else {
                    damaged.append(index)
                    continue
                }
                file.write(UnsafeRawBufferPointer(rebasing: bytes[entry.offset ..< entry.offset + header.length]))
                locations[index] = UInt32(offset / StoreRecord.alignment)
                offset += header.length
            }
        }
        guard let descriptor = file.finish(over: packURL, sync: true) else { return false }
        guard let fresh = StoreMapping(descriptor: descriptor.descriptor) else { return reload(now: now) }
        for index in table.entries.indices {
            table[index].location = locations[index]
        }
        for index in damaged.sorted(by: >) {
            let entry = table.remove(at: index)
            live[entry.tier] -= Int64(entry.length)
        }
        self.generation = generation
        self.descriptor = descriptor
        self.mapping = fresh
        identity = descriptor.identity
        end = offset
        stale = 0
        writeIndex(now: now)
        return true
    }

    /// Writes the table to the index file, renamed over the last.
    @discardableResult
    mutating func writeIndex(now: UInt32) -> Bool {
        let data = StoreIndexFile.encode(generation: generation, covered: end, stale: stale, written: now, table: table)
        guard StoreFiles.replace(indexURL, with: data) != nil else { return false }
        indexBytes = data.count
        appendedSinceIndex = 0
        isIndexCurrent = true
        return true
    }

    // MARK: - Moving

    /// The shard's files copied to `destination` and checked byte for byte against these, then
    /// renamed into place there; the shard reads and writes them from then on.
    mutating func move(to destination: URL, now: UInt32) throws {
        if !isIndexCurrent {
            writeIndex(now: now)
        }
        let pack = Self.packURL(number, in: destination)
        let index = Self.indexURL(number, in: destination)
        try Self.copy(packURL, to: pack)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                try Self.copy(indexURL, to: index)
            } catch {
                try? FileManager.default.removeItem(at: pack)
                throw error
            }
        }
        guard let moved = StoreMapping(url: pack) else {
            try? FileManager.default.removeItem(at: pack)
            try? FileManager.default.removeItem(at: index)
            throw PhotoStoreError.unreadable(pack)
        }
        directory = destination
        descriptor = nil
        mapping = moved
        identity = moved.identity
    }

    /// Copies `source` to `destination` through a staging file, checked against `source` before
    /// it's renamed into place.
    static func copy(_ source: URL, to destination: URL) throws {
        let staging = StoreFiles.staging(for: destination)
        try FileManager.default.copyItem(at: source, to: staging)
        guard let original = StoreMapping(url: source), let copy = StoreMapping(url: staging),
              original.count == copy.count, memcmp(original.base, copy.base, original.count) == 0
        else {
            try? FileManager.default.removeItem(at: staging)
            throw PhotoStoreError.copyDiffers(destination)
        }
        let renamed = staging.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0
            }
        }
        guard renamed else {
            try? FileManager.default.removeItem(at: staging)
            throw PhotoStoreError.destinationHoldsAStore(destination.deletingLastPathComponent())
        }
    }
}

/// A record found for reading: its entry, and a mapping that holds it for as long as it's kept.
struct StoreLookup: Sendable {
    let entry: StoreEntry
    let mapping: StoreMapping
}
