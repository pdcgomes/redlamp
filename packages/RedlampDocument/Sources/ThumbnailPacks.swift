import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Filmstrip thumbnails cached on disk: one pack file per folder, so opening a folder maps one
/// file instead of opening thousands.
///
/// A pack is a header (`RLTP`, version) and then records, each a photo's name, size and
/// modification date and its thumbnail as a JPEG. The pack is mapped into memory and indexed by
/// name when first used; the last record for a name wins, and one whose size or date no longer
/// match the photo's is ignored, so a file overwritten in place is decoded again. New records are
/// appended. A pack more than a third stale is rewritten with only its live records. When all
/// packs pass `budget`, the least recently opened go first.
public final class ThumbnailPacks: Sendable {
    public static let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "app.redlamp/Thumbnails", directoryHint: .isDirectory)

    public let directory: URL
    public let budget: Int64
    /// Packs kept open (each holds a mapping and a file descriptor).
    private static let openLimit = 64
    private let state: Mutex<State>

    private struct State {
        var open: [String: Pack] = [:]
        var lastUse: [String: UInt64] = [:]
        var tick: UInt64 = 0
        /// Bytes of every pack on disk, known once `directory` has been measured.
        var total: Int64?
    }

    public init(directory: URL = ThumbnailPacks.defaultDirectory, budget: Int64 = 1 << 30) {
        self.directory = directory
        self.budget = budget
        state = Mutex(State())
    }

    /// The pack file for photos in `folder`.
    public func packURL(for folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).rltp")
    }

    // MARK: - Reading and writing

    /// The cached JPEG for `photo`, if one matches its size and date.
    public func jpeg(for photo: URL, size: Int64, modified: Date) -> Data? {
        pack(for: photo.deletingLastPathComponent())?.read(photo.lastPathComponent, size: size, modified: modified)
    }

    public func contains(_ photo: URL, size: Int64, modified: Date) -> Bool {
        pack(for: photo.deletingLastPathComponent())?
            .contains(photo.lastPathComponent, size: size, modified: modified) ?? false
    }

    /// Caches `jpeg` for `photo`.
    public func store(_ jpeg: Data, for photo: URL, size: Int64, modified: Date) {
        guard let pack = pack(for: photo.deletingLastPathComponent(), creating: true) else { return }
        let added = pack.append(photo.lastPathComponent, size: size, modified: modified, jpeg: jpeg)
        let over = state.withLock { state -> Bool in
            guard let total = state.total else { return false }
            state.total = total + added
            return total + added > budget
        }
        if over {
            evict()
        }
    }

    /// Packs open now.
    public var openCount: Int {
        state.withLock { $0.open.count }
    }

    // MARK: - Packs

    private func pack(for folder: URL, creating: Bool = false) -> Pack? {
        let url = packURL(for: folder)
        let key = url.lastPathComponent
        let existing = state.withLock { state -> Pack? in
            state.tick += 1
            state.lastUse[key] = state.tick
            return state.open[key]
        }
        if let existing {
            return existing
        }
        guard creating || FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Opened under the lock: two threads opening one pack at once would each map the file
        // while the other might be replacing it.
        let opened = state.withLock { state -> (pack: Pack, measure: Bool)? in
            if let raced = state.open[key] {
                return (raced, false)
            }
            guard let opened = Pack(url: url) else { return nil }
            state.open[key] = opened
            // Packs past the limit are closed once nothing reading them holds them.
            if state.open.count > Self.openLimit {
                let oldest = state.open.keys.sorted { state.lastUse[$0, default: 0] < state.lastUse[$1, default: 0] }
                for key in oldest.prefix(state.open.count - Self.openLimit) {
                    state.open.removeValue(forKey: key)
                }
            }
            return (opened, state.total == nil)
        }
        guard let (pack, measure) = opened else { return nil }
        try? (url as NSURL).setResourceValue(Date(), forKey: .contentModificationDateKey)
        if measure {
            removeLeftovers()
            let total = packFiles().reduce(Int64(0)) { $0 + $1.size }
            state.withLock { $0.total = $0.total ?? total }
        }
        return pack
    }

    /// Older than this, a hidden staging file belongs to a write that never finished.
    static let leftoverAge: TimeInterval = 60 * 60

    /// Removes the staging files (`.<pack>.rltp.<UUID>`) that writes cut short left; they aren't
    /// packs, so the budget doesn't see them.
    func removeLeftovers(now: Date = Date()) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys))
        for file in files ?? []
            where file.lastPathComponent.hasPrefix(".") && file.lastPathComponent.contains(".rltp.") {
            let modified = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > Self.leftoverAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private struct PackFile {
        let url: URL
        let size: Int64
        let modified: Date
    }

    private func packFiles() -> [PackFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys))
        return (files ?? []).filter { $0.pathExtension == "rltp" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return PackFile(
                url: url, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate ?? .distantPast,
            )
        }
    }

    /// Removes the least recently opened packs until all of them fit the budget, keeping those
    /// opened in the last minute (the folders being looked at).
    private func evict() {
        var files = packFiles().sorted { $0.modified < $1.modified }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        let recent = Date().addingTimeInterval(-60)
        while total > budget * 9 / 10, let oldest = files.first, oldest.modified < recent {
            files.removeFirst()
            state.withLock { state in
                _ = state.open.removeValue(forKey: oldest.url.lastPathComponent)
            }
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
        state.withLock { $0.total = total }
    }

    // MARK: - Encoding

    /// A JPEG of `image` for a pack.
    public static func encode(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary,
        )
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A pack's JPEG, decoded now (not when first drawn).
    public static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// One folder's pack file.
private final class Pack: Sendable {
    private static let magic: [UInt8] = Array("RLTP".utf8)
    private static let version: UInt32 = 1
    private static let headerSize = 8
    /// Record length (4), name length (2), size (8), date (8), then the name and the JPEG.
    private static let recordHeaderSize = 22

    private struct Record {
        var offset: Int
        var length: Int
        var size: Int64
        var modified: Double
    }

    /// The file is only ever replaced (renamed over), never shrunk in place, so a mapping taken
    /// earlier stays valid; reads past the mapping (records appended since) hold the lock, as the
    /// descriptor changes when the file is replaced.
    private struct State {
        var descriptor: Int32
        var mapped: Data
        var index: [String: Record] = [:]
        var end: Int
        var stale = 0
    }

    let url: URL
    private let state: Mutex<State>

    init?(url: URL) {
        self.url = url
        var mapped = (try? Data(contentsOf: url, options: .alwaysMapped)) ?? Data()
        if mapped.count < Self.headerSize || Array(mapped.prefix(4)) != Self.magic {
            // A new pack, or one this version can't read: a fresh file is renamed over it rather
            // than truncating it, which would break a mapping another process holds.
            var header = Data(Self.magic)
            withUnsafeBytes(of: Self.version.littleEndian) { header.append(contentsOf: $0) }
            let staging = url.deletingLastPathComponent()
                .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
            guard (try? header.write(to: staging)) != nil, rename(staging.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: staging)
                return nil
            }
            mapped = header
        }
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var state = State(descriptor: fd, mapped: mapped, end: mapped.count)
        Self.index(&state)
        self.state = Mutex(state)
    }

    deinit {
        state.withLock { _ = close($0.descriptor) }
    }

    private static func index(_ state: inout State) {
        let data = state.mapped
        var offset = headerSize
        data.withUnsafeBytes { bytes in
            while offset + recordHeaderSize <= bytes.count {
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
                let nameLength = Int(bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt16.self).littleEndian)
                guard length >= recordHeaderSize + nameLength, offset + length <= bytes.count else { break }
                let size = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 6, as: Int64.self))
                let date = Double(bitPattern: UInt64(
                    littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 14, as: UInt64.self),
                ))
                let nameStart = offset + recordHeaderSize
                let name = String(bytes: bytes[nameStart ..< nameStart + nameLength], encoding: .utf8) ?? ""
                if let previous = state.index[name] {
                    state.stale += previous.length
                }
                state.index[name] = Record(offset: offset, length: length, size: size, modified: date)
                offset += length
            }
        }
        state.end = offset
    }

    private static func matches(_ record: Record, size: Int64, modified: Date) -> Bool {
        record.size == size && abs(record.modified - modified.timeIntervalSinceReferenceDate) < 0.001
    }

    func contains(_ name: String, size: Int64, modified: Date) -> Bool {
        state.withLock { $0.index[name].map { Self.matches($0, size: size, modified: modified) } ?? false }
    }

    func read(_ name: String, size: Int64, modified: Date) -> Data? {
        let nameLength = name.utf8.count
        let found = state.withLock { state -> (Range<Int>, Data?)? in
            guard let record = state.index[name], Self.matches(record, size: size, modified: modified) else {
                return nil
            }
            let start = record.offset + Self.recordHeaderSize + nameLength
            let range = start ..< record.offset + record.length
            if range.upperBound <= state.mapped.count {
                return (range, nil)
            }
            var data = Data(count: range.count)
            let read = data
                .withUnsafeMutableBytes { pread(state.descriptor, $0.baseAddress, range.count, off_t(start)) }
            return read == range.count ? (range, data) : nil
        }
        guard let (range, data) = found else { return nil }
        if let data {
            return data
        }
        let mapped = state.withLock { $0.mapped }
        return range.upperBound <= mapped.count ? mapped.subdata(in: range) : nil
    }

    /// Appends a record and returns the bytes added. Compacts the pack first when more than a
    /// third of it is stale.
    func append(_ name: String, size: Int64, modified: Date, jpeg: Data) -> Int64 {
        let nameBytes = Array(name.utf8)
        var record = Data(capacity: Self.recordHeaderSize + nameBytes.count + jpeg.count)
        let length = UInt32(Self.recordHeaderSize + nameBytes.count + jpeg.count)
        withUnsafeBytes(of: length.littleEndian) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(nameBytes.count).littleEndian) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: size.littleEndian) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: modified.timeIntervalSinceReferenceDate.bitPattern.littleEndian) {
            record.append(contentsOf: $0)
        }
        record.append(contentsOf: nameBytes)
        record.append(jpeg)
        return state.withLock { state -> Int64 in
            let offset = state.end
            let written = record.withUnsafeBytes {
                pwrite(state.descriptor, $0.baseAddress, record.count, off_t(offset))
            }
            guard written == record.count else { return 0 }
            if let previous = state.index[name] {
                state.stale += previous.length
            }
            state.index[name] = Record(
                offset: offset, length: record.count, size: size, modified: modified.timeIntervalSinceReferenceDate,
            )
            state.end += record.count
            if state.stale * 3 > state.end {
                compact(&state)
            }
            return Int64(record.count)
        }
    }

    /// Writes the live records to a new file and renames it over the pack, under the lock.
    private func compact(_ state: inout State) {
        var live = Data(state.mapped.prefix(Self.headerSize))
        var index: [String: Record] = [:]
        for (name, record) in state.index.sorted(by: { $0.value.offset < $1.value.offset }) {
            var bytes: Data
            if record.offset + record.length <= state.mapped.count {
                bytes = state.mapped.subdata(in: record.offset ..< record.offset + record.length)
            } else {
                bytes = Data(count: record.length)
                let read = bytes.withUnsafeMutableBytes {
                    pread(state.descriptor, $0.baseAddress, record.length, off_t(record.offset))
                }
                guard read == record.length else { continue }
            }
            index[name] = Record(
                offset: live.count,
                length: record.length,
                size: record.size,
                modified: record.modified,
            )
            live.append(bytes)
        }
        let staging = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard (try? live.write(to: staging)) != nil else { return }
        guard rename(staging.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            return
        }
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return }
        close(state.descriptor)
        state.descriptor = fd
        state.mapped = (try? Data(contentsOf: url, options: .alwaysMapped)) ?? live
        state.index = index
        state.end = live.count
        state.stale = 0
    }
}
