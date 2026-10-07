import Darwin
import Dispatch
import Foundation

/// The column store saved beside the index (LIB-44), `Index.columns` for `Index.sqlite`: a header
/// page, then each of the store's columns, its sort orders, the row of each photo ID and the rows
/// holding a photo, each on a page boundary (16 KB on Apple silicon) and laid out as the store keeps
/// it in memory, so loading it is mapping it; then the names its code columns stand for and the
/// small tables' names. The header names the index generation and schema version it reflects.
///
/// It's written to a temporary file beside it, made durable and renamed over the last, so it's
/// whole or absent; when only the generation it reflects changes, its header alone is written
/// again, in place, its checksum guarding it.
enum ColumnSnapshot {
    /// The store's sections, in the file's order, each with the bytes of one value.
    enum Section: UInt32, CaseIterable, Sendable {
        case ids = 1, folders, captured, cameras, lenses, packed, iso, aperture, focal, shutter, kinds
        case nameRanks, editedAt, sizes, modifiedAt, states, creators, copyrights, customLabels, places
        case megapixels, aspects, orientations, rowOfID
        case byCaptured, byName, byRating, byEdited, byModified, bySize
        case live, names

        var stride: Int {
            switch self {
            case .ids, .captured, .live: 8
            case .folders, .shutter, .nameRanks, .editedAt, .sizes, .modifiedAt, .places, .rowOfID, .byCaptured,
                 .byName, .byRating, .byEdited, .byModified, .bySize: 4
            case .cameras, .lenses, .packed, .iso, .aperture, .focal, .creators, .copyrights, .megapixels,
                 .aspects: 2
            case .kinds, .states, .customLabels, .orientations, .names: 1
            }
        }

        /// The orders a store keeps only once a search sorts by them.
        var isOptional: Bool {
            self == .byModified || self == .bySize
        }
    }

    static let magic: UInt64 = 0x534E_4D55_4C4F_4352 // "RCOLUMNS", little-endian
    /// The file's layout: bumped whenever a section is added, removed or changes its values.
    static let format: UInt32 = 1
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
        var entries: [(section: Section, offset: Int, length: Int, count: Int, checksum: UInt64)] = []
        var offset = page
        func put(_ section: Section, _ bytes: UnsafeRawBufferPointer) throws {
            try writeAll(descriptor, bytes, at: offset)
            entries.append((section, offset, bytes.count, bytes.count / section.stride, checksum(bytes)))
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
    }

    // MARK: - Checksums

    /// A 64-bit checksum of `bytes`: four lanes of words, each mixed in by a multiply, so a damaged
    /// page or one of zeros where data was gives another sum.
    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        let prime: UInt64 = 0x9E37_79B9_7F4A_7C15
        var lanes: (UInt64, UInt64, UInt64, UInt64) = (
            0x243F_6A88_85A3_08D3, 0x1319_8A2E_0370_7344, 0xA409_3822_299F_31D0, 0x082E_FA98_EC4E_6C89,
        )
        let words = bytes.count / 8
        var index = 0
        var sum: UInt64
        if let base = bytes.baseAddress {
            while index + 4 <= words {
                let at = index * 8
                lanes.0 = (lanes.0 ^ base.loadUnaligned(fromByteOffset: at, as: UInt64.self)) &* prime
                lanes.1 = (lanes.1 ^ base.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self)) &* prime
                lanes.2 = (lanes.2 ^ base.loadUnaligned(fromByteOffset: at + 16, as: UInt64.self)) &* prime
                lanes.3 = (lanes.3 ^ base.loadUnaligned(fromByteOffset: at + 24, as: UInt64.self)) &* prime
                index += 4
            }
            sum = lanes.0 ^ lanes.1.rotated(17) ^ lanes.2.rotated(31) ^ lanes.3.rotated(47)
            for word in index ..< words {
                sum = (sum ^ base.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self)) &* prime
            }
            for byte in words * 8 ..< bytes.count {
                sum = (sum ^ UInt64(base.load(fromByteOffset: byte, as: UInt8.self))) &* prime
            }
        } else {
            sum = lanes.0 ^ lanes.1.rotated(17) ^ lanes.2.rotated(31) ^ lanes.3.rotated(47)
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
}

private extension UInt64 {
    func rotated(_ bits: UInt64) -> UInt64 {
        self << bits | self >> (64 - bits)
    }
}
