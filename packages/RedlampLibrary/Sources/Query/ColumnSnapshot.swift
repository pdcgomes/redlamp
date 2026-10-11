import Darwin
import Dispatch
import Foundation
import Synchronization

/// The column store saved beside the index (LIB-44), `Index.columns` for `Index.sqlite`: a header
/// page, then each of the store's columns, its sort orders, the row of each photo ID and the rows
/// holding a photo, each on a page boundary (16 KB on Apple silicon) and laid out as the store keeps
/// it in memory, so loading it is mapping it; then the names its code columns stand for and the
/// small tables' names. The header names the index generation and schema version it reflects.
///
/// It's written to a temporary file beside it, made durable and renamed over the last, so it's
/// whole or absent; when only the generation it reflects changes, its header alone is written
/// again, in place, its checksum guarding it. One that doesn't reflect the index as it is now, or
/// can't be read, is set aside, never trusted: one of another generation, schema, format or page
/// size is removed, and one whose header, length or checksums don't hold is kept as
/// `Index.columns.damaged`.
enum ColumnSnapshot {
    /// The store's sections, in the file's order, each with the bytes of one value.
    enum Section: UInt32, CaseIterable, Sendable {
        case ids = 1, folders, captured, cameras, lenses, packed, iso, aperture, focal, shutter, kinds
        case nameRanks, editedAt, sizes, modifiedAt, states, creators, copyrights, customLabels, places
        case megapixels, aspects, orientations, widestApertures, focal35s, rowOfID
        case byCaptured, byName, byRating, byEdited, byModified, bySize
        case live, names

        var stride: Int {
            switch self {
            case .ids, .captured, .live: 8
            case .folders, .shutter, .nameRanks, .editedAt, .sizes, .modifiedAt, .places, .rowOfID, .byCaptured,
                 .byName, .byRating, .byEdited, .byModified, .bySize: 4
            case .cameras, .lenses, .packed, .iso, .aperture, .focal, .creators, .copyrights, .megapixels,
                 .aspects, .widestApertures, .focal35s: 2
            case .kinds, .states, .customLabels, .orientations, .names: 1
            }
        }

        /// The orders a store keeps only once a search sorts by them.
        var isOptional: Bool {
            self == .byModified || self == .bySize
        }
    }

    /// Why a snapshot was set aside.
    enum Refusal: Sendable, Hashable {
        /// Of another generation, schema, format or page size: removed.
        case stale
        /// Unreadable: kept as `<name>.damaged`.
        case damaged
    }

    /// What a snapshot holds besides its columns.
    struct Contents: Sendable {
        var store: ColumnStore
        /// The small tables' names, as the index has them: folders, cameras, lenses, keywords and
        /// collections.
        var names: QueryNames
    }

    static let magic: UInt64 = 0x534E_4D55_4C4F_4352 // "RCOLUMNS", little-endian
    /// The file's layout: bumped whenever a section is added, removed or changes its values, the name
    /// order's included (`FinderOrder`).
    static let format: UInt32 = 4
    static let headerBytes = 72
    static let entryBytes = 40

    /// Where it's kept for the index at `index`: beside it, named after it.
    static func url(forIndex index: URL) -> URL {
        index.deletingPathExtension().appendingPathExtension("columns")
    }

    // MARK: - Writing

    /// Saves `store` and the small tables' `names` at `url` as reflecting `generation`: written to a
    /// temporary file beside it, made durable and renamed over it.
    static func write(_ store: ColumnStore, names: QueryNames, generation: IndexGeneration, to url: URL) throws {
        let page = ColumnPages.pageSize
        let folder = url.deletingLastPathComponent()
        removePartials(of: url)
        let partial = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).partial")
        let descriptor = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError.current }
        var renamed = false
        defer {
            Darwin.close(descriptor)
            if !renamed {
                unlink(partial.path)
            }
        }
        let blob = encode(store, names: names)
        var entries: [Layout.Entry] = []
        var offset = page
        func put(_ section: Section, _ bytes: UnsafeRawBufferPointer) throws {
            try writeAll(descriptor, bytes, at: offset)
            entries.append(Layout.Entry(
                section: section, offset: offset, length: bytes.count, count: bytes.count / section.stride,
                checksum: checksum(bytes),
            ))
            offset += ColumnPages.rounded(bytes.count)
        }
        try store.withSections { section, bytes in
            try put(section, bytes)
        }
        try blob.withUnsafeBytes { try put(.names, $0) }
        var header = Data(count: page)
        header.withUnsafeMutableBytes { header in
            header.storeBytes(of: magic.littleEndian, toByteOffset: 0, as: UInt64.self)
            header.storeBytes(of: format.littleEndian, toByteOffset: 8, as: UInt32.self)
            header.storeBytes(of: UInt32(page).littleEndian, toByteOffset: 12, as: UInt32.self)
            header.storeBytes(of: Int64(generation.schema).littleEndian, toByteOffset: 16, as: Int64.self)
            header.storeBytes(of: generation.counter.littleEndian, toByteOffset: 24, as: Int64.self)
            header.storeBytes(of: generation.token.littleEndian, toByteOffset: 32, as: Int64.self)
            header.storeBytes(of: Int64(store.rowCount).littleEndian, toByteOffset: 40, as: Int64.self)
            header.storeBytes(of: Int64(store.count).littleEndian, toByteOffset: 48, as: Int64.self)
            header.storeBytes(of: UInt32(entries.count).littleEndian, toByteOffset: 56, as: UInt32.self)
            for (number, entry) in entries.enumerated() {
                let at = headerBytes + number * entryBytes
                header.storeBytes(of: entry.section.rawValue.littleEndian, toByteOffset: at, as: UInt32.self)
                header.storeBytes(of: UInt32(entry.section.stride).littleEndian, toByteOffset: at + 4, as: UInt32.self)
                header.storeBytes(of: UInt64(entry.offset).littleEndian, toByteOffset: at + 8, as: UInt64.self)
                header.storeBytes(of: UInt64(entry.length).littleEndian, toByteOffset: at + 16, as: UInt64.self)
                header.storeBytes(of: UInt64(entry.count).littleEndian, toByteOffset: at + 24, as: UInt64.self)
                header.storeBytes(of: entry.checksum.littleEndian, toByteOffset: at + 32, as: UInt64.self)
            }
            let sum = checksum(UnsafeRawBufferPointer(rebasing: header[..<(headerBytes + entries.count * entryBytes)]))
            header.storeBytes(of: sum.littleEndian, toByteOffset: 64, as: UInt64.self)
        }
        guard ftruncate(descriptor, off_t(offset)) == 0 else { throw POSIXError.current }
        try header.withUnsafeBytes { try writeAll(descriptor, $0, at: 0) }
        guard fsync(descriptor) == 0 else { throw POSIXError.current }
        guard rename(partial.path, url.path) == 0 else { throw POSIXError.current }
        renamed = true
    }
}

extension ColumnSnapshot {
    /// Says of the snapshot at `url`, saved as reflecting `saved`, that it reflects `generation`, the
    /// store being unchanged since: only the bytes of its header that change are written again, in
    /// place, so its pages stay in the file cache for the next launch. A header a crash cut short
    /// fails its checksum and the snapshot is set aside, never trusted. False when the snapshot there
    /// isn't `saved`'s or its header couldn't be written.
    static func restamp(at url: URL, from saved: IndexGeneration, to generation: IndexGeneration) -> Bool {
        let page = ColumnPages.pageSize
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var header = Data(count: page)
        var file = stat()
        let read = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, page, 0) }
        guard read == page, fstat(descriptor, &file) == 0, let layout = Layout(header, fileSize: Int(file.st_size)),
              layout.format == format, layout.pageSize == page, layout.generation == saved
        else { return false }
        let tableEnd = headerBytes + layout.entries.count * entryBytes
        header.withUnsafeMutableBytes { header in
            header.storeBytes(of: Int64(generation.schema).littleEndian, toByteOffset: 16, as: Int64.self)
            header.storeBytes(of: generation.counter.littleEndian, toByteOffset: 24, as: Int64.self)
            header.storeBytes(of: generation.token.littleEndian, toByteOffset: 32, as: Int64.self)
            header.storeBytes(of: UInt64(0), toByteOffset: 64, as: UInt64.self)
            let sum = checksum(UnsafeRawBufferPointer(rebasing: header[..<tableEnd]))
            header.storeBytes(of: sum.littleEndian, toByteOffset: 64, as: UInt64.self)
        }
        do {
            try header.prefix(tableEnd).withUnsafeBytes { try writeAll(descriptor, $0, at: 0) }
        } catch {
            return false
        }
        return fsync(descriptor) == 0
    }

    private static func writeAll(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, at offset: Int) throws {
        var written = 0
        while written < bytes.count {
            let count = pwrite(descriptor, bytes.baseAddress! + written, bytes.count - written, off_t(offset + written))
            guard count > 0 else { throw POSIXError.current }
            written += count
        }
    }

    /// Removes temporary files of writes that never finished: a process quit partway, say. Only
    /// those left an hour or more, since another process may be writing one now.
    private static func removePartials(of url: URL) {
        let folder = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".partial") {
            let file = folder.appending(path: name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            if let modified, Date().timeIntervalSince(modified) > 3600 {
                unlink(file.path)
            }
        }
    }

    // MARK: - Reading

    /// The store and names saved at `url`, mapped copy-on-write, when they reflect `generation`; nil
    /// when there's none, and when there's one that doesn't, which is set aside (`refused`). A cold
    /// file is read ahead with one request.
    static func read(
        at url: URL, generation: IndexGeneration, refused: (Refusal) -> Void = { _ in },
    ) -> Contents? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var file = stat()
        guard fstat(descriptor, &file) == 0 else { return nil }
        func setAside(_ refusal: Refusal) -> Contents? {
            var now = stat()
            if stat(url.path, &now) == 0, now.st_ino == file.st_ino, now.st_dev == file.st_dev {
                switch refusal {
                case .stale:
                    unlink(url.path)
                case .damaged:
                    let damaged = url.appendingPathExtension("damaged")
                    unlink(damaged.path)
                    rename(url.path, damaged.path)
                }
            }
            refused(refusal)
            return nil
        }
        let page = ColumnPages.pageSize
        let size = Int(file.st_size)
        var header = Data(count: page)
        let read = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, page, 0) }
        guard read >= headerBytes else { return setAside(.damaged) }
        let (magic, kind, pageSize) = header.withUnsafeBytes { bytes in
            (
                UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self))),
            )
        }
        guard magic == Self.magic else { return setAside(.damaged) }
        guard kind == format, pageSize == page else { return setAside(.stale) }
        guard read == page, size % page == 0, let layout = Layout(header, fileSize: size) else {
            return setAside(.damaged)
        }
        guard layout.generation == generation else { return setAside(.stale) }
        guard let mapping = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE, descriptor, 0),
              mapping != MAP_FAILED
        else { return nil }
        readAheadIfCold(descriptor, mapping, size)
        guard layout.checksumsHold(in: UnsafeRawPointer(mapping)) else {
            munmap(mapping, size)
            return setAside(.damaged)
        }
        guard let contents = layout.contents(in: mapping, size: size) else { return setAside(.damaged) }
        return contents
    }

    /// One request to read the whole file ahead when its pages aren't in memory: the SSD then
    /// delivers it at its own speed, where page faults bring it in a page at a time.
    private static func readAheadIfCold(_ descriptor: Int32, _ mapping: UnsafeMutableRawPointer, _ size: Int) {
        let page = ColumnPages.pageSize
        var resident = [CChar](repeating: 0, count: size / page)
        if mincore(mapping, size, &resident) == 0, resident.allSatisfy({ $0 & 1 != 0 }) {
            return
        }
        var advice = radvisory(ra_offset: 0, ra_count: Int32(clamping: size))
        _ = fcntl(descriptor, F_RDADVISE, &advice)
    }

    /// A header read and checked against the file it's in.
    private struct Layout {
        struct Entry {
            let section: Section
            let offset: Int
            let length: Int
            let count: Int
            let checksum: UInt64
        }

        let format: UInt32
        let pageSize: Int
        let generation: IndexGeneration
        let rows: Int
        let count: Int
        let entries: [Entry]

        init?(_ header: Data, fileSize: Int) {
            func load<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
                header.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
            }
            guard load(0, UInt64.self) == ColumnSnapshot.magic else { return nil }
            format = load(8, UInt32.self)
            pageSize = Int(load(12, UInt32.self))
            generation = IndexGeneration(
                schema: Int(load(16, Int64.self)), counter: load(24, Int64.self), token: load(32, Int64.self),
            )
            rows = Int(load(40, Int64.self))
            count = Int(load(48, Int64.self))
            let sections = Int(load(56, UInt32.self))
            let tableEnd = headerBytes + sections * entryBytes
            guard sections <= Section.allCases.count, tableEnd <= header.count, rows >= 0, count >= 0,
                  count <= rows
            else { return nil }
            var copy = header.prefix(tableEnd)
            copy.withUnsafeMutableBytes { $0.storeBytes(of: 0, toByteOffset: 64, as: UInt64.self) }
            let sum = copy.withUnsafeBytes { ColumnSnapshot.checksum($0) }
            guard sum == load(64, UInt64.self) else { return nil }
            var entries: [Entry] = []
            var next = pageSize
            for number in 0 ..< sections {
                let at = headerBytes + number * entryBytes
                guard let section = Section(rawValue: load(at, UInt32.self)),
                      Int(load(at + 4, UInt32.self)) == section.stride
                else { return nil }
                let entry = Entry(
                    section: section, offset: Int(load(at + 8, UInt64.self)), length: Int(load(at + 16, UInt64.self)),
                    count: Int(load(at + 24, UInt64.self)), checksum: load(at + 32, UInt64.self),
                )
                guard entry.offset == next, entry.length == entry.count * section.stride,
                      entry.offset + entry.length <= fileSize
                else { return nil }
                next = entry.offset + ColumnPages.rounded(entry.length)
                entries.append(entry)
            }
            guard next == fileSize else { return nil }
            self.entries = entries
        }

        /// Whether every section's bytes give its checksum, the sections checked side by side.
        func checksumsHold(in mapping: UnsafeRawPointer) -> Bool {
            let entries = entries
            nonisolated(unsafe) let mapping = mapping
            let mismatched = Atomic(0)
            DispatchQueue.concurrentPerform(iterations: entries.count) { number in
                let entry = entries[number]
                let bytes = UnsafeRawBufferPointer(start: mapping + entry.offset, count: entry.length)
                if ColumnSnapshot.checksum(bytes) != entry.checksum {
                    mismatched.wrappingAdd(1, ordering: .relaxed)
                }
            }
            return mismatched.load(ordering: .relaxed) == 0
        }

        /// The store and names, the columns taking their pages of `mapping`, and the rest of it
        /// unmapped; nil, with all of it unmapped, when the sections don't make a store.
        func contents(in mapping: UnsafeMutableRawPointer, size: Int) -> Contents? {
            var store = ColumnStore()
            var names: QueryNames?
            var taken: [Range<Int>] = []
            var valid = true
            for entry in entries {
                if entry.section == .names {
                    let blob = UnsafeRawBufferPointer(start: mapping + entry.offset, count: entry.length)
                    if let decoded = ColumnSnapshot.decode(blob, into: &store) {
                        names = decoded
                    } else {
                        valid = false
                    }
                    continue
                }
                let length = ColumnPages.rounded(entry.length)
                let pages = ColumnPages(base: length > 0 ? mapping + entry.offset : nil, size: length)
                taken.append(entry.offset ..< entry.offset + length)
                if !store.adopt(entry.section, pages: pages, count: entry.count) {
                    valid = false
                }
            }
            var unmapped = 0
            for range in taken.sorted(by: { $0.lowerBound < $1.lowerBound }) + [size ..< size] {
                if range.lowerBound > unmapped {
                    munmap(mapping + unmapped, range.lowerBound - unmapped)
                }
                unmapped = max(unmapped, range.upperBound)
            }
            guard valid, let names, store.isWhole(rows: rows, count: count) else { return nil }
            return Contents(store: store, names: names)
        }
    }

    // MARK: - Checksums

    /// A 64-bit checksum of `bytes`: four lanes of words, each mixed in by a multiply, so a damaged
    /// page or one of zeros where data was gives another sum.
    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        let prime: UInt64 = 0x9E37_79B9_7F4A_7C15
        var lane0: UInt64 = 0x243F_6A88_85A3_08D3
        var lane1: UInt64 = 0x1319_8A2E_0370_7344
        var lane2: UInt64 = 0xA409_3822_299F_31D0
        var lane3: UInt64 = 0x082E_FA98_EC4E_6C89
        let words = bytes.count / 8
        var index = 0
        var sum: UInt64
        if let base = bytes.baseAddress {
            while index + 4 <= words {
                let at = index * 8
                lane0 = (lane0 ^ base.loadUnaligned(fromByteOffset: at, as: UInt64.self)) &* prime
                lane1 = (lane1 ^ base.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self)) &* prime
                lane2 = (lane2 ^ base.loadUnaligned(fromByteOffset: at + 16, as: UInt64.self)) &* prime
                lane3 = (lane3 ^ base.loadUnaligned(fromByteOffset: at + 24, as: UInt64.self)) &* prime
                index += 4
            }
            sum = lane0 ^ lane1.rotated(17) ^ lane2.rotated(31) ^ lane3.rotated(47)
            for word in index ..< words {
                sum = (sum ^ base.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self)) &* prime
            }
            for byte in words * 8 ..< bytes.count {
                sum = (sum ^ UInt64(base.load(fromByteOffset: byte, as: UInt8.self))) &* prime
            }
        } else {
            sum = lane0 ^ lane1.rotated(17) ^ lane2.rotated(31) ^ lane3.rotated(47)
        }
        sum ^= UInt64(bytes.count)
        sum = (sum ^ (sum >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        return sum ^ (sum >> 33)
    }

    // MARK: - Names

    /// The code columns' names and the small tables' names, as bytes.
    private static func encode(_ store: ColumnStore, names: QueryNames) -> Data {
        var data = Data()
        func put(_ value: Int64) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func put(_ text: String) {
            let bytes = Array(text.utf8)
            put(Int64(bytes.count))
            data.append(contentsOf: bytes)
        }
        func put(_ table: [Int64: String]) {
            put(Int64(table.count))
            for (id, name) in table.sorted(by: { $0.key < $1.key }) {
                put(id)
                put(name)
            }
        }
        let codes = store.savedCodes
        for ids in [codes.cameraIDs, codes.lensIDs] {
            put(Int64(ids.count))
            ids.forEach(put)
        }
        for list in codes.nameLists {
            put(Int64(list.count))
            list.forEach(put)
        }
        put(Int64(codes.placeParts.count))
        for part in codes.placeParts {
            put(Int64(part))
        }
        for table in [names.folders, names.cameras, names.lenses, names.keywords, names.collections] {
            put(table)
        }
        return data
    }

    /// The small tables' names from `blob`, with the code columns' names put in `store`; nil when the
    /// bytes don't hold them.
    private static func decode(_ blob: UnsafeRawBufferPointer, into store: inout ColumnStore) -> QueryNames? {
        var at = 0
        func number() -> Int64? {
            guard at + 8 <= blob.count else { return nil }
            defer { at += 8 }
            return Int64(littleEndian: blob.loadUnaligned(fromByteOffset: at, as: Int64.self))
        }
        func count() -> Int? {
            guard let value = number(), value >= 0, value <= blob.count else { return nil }
            return Int(value)
        }
        func text() -> String? {
            guard let length = count(), at + length <= blob.count else { return nil }
            defer { at += length }
            return String(decoding: UnsafeRawBufferPointer(rebasing: blob[at ..< at + length]), as: UTF8.self)
        }
        func table() -> [Int64: String]? {
            guard let entries = count() else { return nil }
            var table: [Int64: String] = [:]
            table.reserveCapacity(entries)
            for _ in 0 ..< entries {
                guard let id = number(), let name = text() else { return nil }
                table[id] = name
            }
            return table
        }
        var codes = ColumnStore.SavedCodes()
        for kind in 0 ..< 2 {
            guard let entries = count() else { return nil }
            var ids = ContiguousArray<Int64>()
            ids.reserveCapacity(entries)
            for _ in 0 ..< entries {
                guard let id = number() else { return nil }
                ids.append(id)
            }
            if kind == 0 {
                codes.cameraIDs = ids
            } else {
                codes.lensIDs = ids
            }
        }
        codes.nameLists = []
        for _ in 0 ..< ColumnStore.SavedCodes.nameListCount {
            guard let entries = count() else { return nil }
            var list: [String] = []
            list.reserveCapacity(entries)
            for _ in 0 ..< entries {
                guard let name = text() else { return nil }
                list.append(name)
            }
            codes.nameLists.append(list)
        }
        guard let parts = count() else { return nil }
        codes.placeParts.reserveCapacity(parts)
        for _ in 0 ..< parts {
            guard let part = number(), let code = UInt32(exactly: part) else { return nil }
            codes.placeParts.append(code)
        }
        guard let folders = table(), let cameras = table(), let lenses = table(), let keywords = table(),
              let collections = table(), at == blob.count, store.adopt(codes)
        else { return nil }
        return QueryNames(
            folders: folders,
            cameras: cameras,
            lenses: lenses,
            keywords: keywords,
            collections: collections,
        )
    }
}

private extension UInt64 {
    func rotated(_ bits: UInt64) -> UInt64 {
        self << bits | self >> (64 - bits)
    }
}
