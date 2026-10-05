import Foundation
import Synchronization

/// Which file a path named: another process compacting a shard renames a new file over it.
struct FileIdentity: Equatable {
    let device: Int32
    let inode: UInt64

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        self.init(info)
    }
}

/// A pack's open file, closed when the last shard holding it lets go. A shard keeps it from its
/// first write on: opening a file for every write, and closing it, costs milliseconds where
/// security software inspects each file closed after a write.
final class StoreDescriptor: @unchecked Sendable {
    /// Descriptors open in the process, across stores.
    static let openCount = Atomic(0)

    let descriptor: Int32
    let identity: FileIdentity

    /// `url` opened to append to and read.
    convenience init?(url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDWR | O_APPEND | O_CLOEXEC) } ?? -1
        }
        self.init(adopting: descriptor)
    }

    init?(adopting descriptor: Int32) {
        guard descriptor >= 0 else { return nil }
        guard let identity = FileIdentity(descriptor: descriptor) else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        self.identity = identity
        Self.openCount.add(1, ordering: .relaxed)
    }

    deinit {
        close(descriptor)
        Self.openCount.subtract(1, ordering: .relaxed)
    }

    enum Appended {
        case at(Int)
        /// Nothing was written, or only part (`partial`), which then sits at the end of the file.
        case failed(partial: Bool)
    }

    /// Appends `bytes` in one write and says where they landed: with `O_APPEND`, another process's
    /// appends never overwrite them.
    func append(_ bytes: Data) -> Appended {
        var written = 0
        repeat {
            written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        } while written < 0 && errno == EINTR
        guard written == bytes.count else {
            return .failed(partial: written > 0)
        }
        let end = lseek(descriptor, 0, SEEK_CUR)
        return end >= bytes.count ? .at(Int(end) - bytes.count) : .failed(partial: false)
    }
}

/// A pack mapped read-only, as long as it was when mapped, and unmapped once nothing holds it.
/// Packs are only ever appended to or replaced by a rename, never shortened, so a mapping stays
/// valid for as long as it's held.
final class StoreMapping: @unchecked Sendable {
    let base: UnsafeRawPointer
    let count: Int
    let identity: FileIdentity

    convenience init?(url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        self.init(descriptor: descriptor)
    }

    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0,
              let pointer = mmap(nil, Int(info.st_size), PROT_READ, MAP_SHARED, descriptor, 0), pointer != MAP_FAILED
        else { return nil }
        base = UnsafeRawPointer(pointer)
        count = Int(info.st_size)
        identity = FileIdentity(info)
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), count)
    }

    var bytes: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: base, count: count)
    }
}

enum StoreFiles {
    /// Older than this, a hidden staging file belongs to a write that never finished.
    static let leftoverAge: TimeInterval = 60 * 60

    /// A hidden file beside `url` for writing what's then renamed over it.
    static func staging(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
    }

    /// Writes `data` to a staging file and renames it over `url`, or with `exclusive` only where
    /// there's no file, and returns the new file, open.
    static func replace(_ url: URL, with data: Data, exclusive: Bool = false, sync: Bool = false) -> StoreDescriptor? {
        guard let file = StagingFile(beside: url), file.write(data) else { return nil }
        return file.finish(over: url, exclusive: exclusive, sync: sync)
    }

    /// Removes the staging files (`.<shard>.rlps.<UUID>`, `.<shard>.rlpi.<UUID>`) that writes cut
    /// short left in `directory`.
    static func removeLeftovers(in directory: URL, now: Date = Date()) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys))
        for file in files ?? [] where isStaging(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > leftoverAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func isStaging(_ name: String) -> Bool {
        name.hasPrefix(".") && (name.contains(".\(PhotoStore.packExtension).")
            || name.contains(".\(PhotoStore.indexExtension)."))
    }
}

/// A file written beside another and then renamed over it, so nothing that maps the other ever
/// sees it change; removed if it's never renamed.
final class StagingFile {
    let url: URL
    private var descriptor: StoreDescriptor?
    private var buffer = Data()
    private var failed = false
    private static let bufferLength = 1 << 20

    init?(beside target: URL) {
        url = StoreFiles.staging(for: target)
        let opened = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC, 0o644) } ?? -1
        }
        guard let descriptor = StoreDescriptor(adopting: opened) else { return nil }
        self.descriptor = descriptor
    }

    deinit {
        if descriptor != nil {
            unlink(url.path)
        }
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { write($0) }
    }

    @discardableResult
    func write(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard !failed else { return false }
        if let base = bytes.baseAddress {
            buffer.append(base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        }
        if buffer.count >= Self.bufferLength {
            flush()
        }
        return !failed
    }

    private func flush() {
        guard !failed, !buffer.isEmpty, let descriptor else { return }
        failed = !buffer.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let written = Foundation.write(descriptor.descriptor, bytes.baseAddress! + done, bytes.count - done)
                if written > 0 {
                    done += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        buffer.removeAll(keepingCapacity: true)
    }

    /// Renames the file over `target` (with `exclusive`, only where there's none) once it's all
    /// written, and with `sync` on the disk, and returns it still open; nil when that failed, and
    /// the staging file is gone.
    func finish(over target: URL, exclusive: Bool = false, sync: Bool = false) -> StoreDescriptor? {
        flush()
        guard let descriptor else { return nil }
        self.descriptor = nil
        let renamed = !failed && (!sync || fsync(descriptor.descriptor) == 0)
            && url.withUnsafeFileSystemRepresentation { from in
                target.withUnsafeFileSystemRepresentation { to in
                    guard let from, let to else { return false }
                    return exclusive ? renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 : rename(from, to) == 0
                }
            }
        guard renamed else {
            unlink(url.path)
            return nil
        }
        return descriptor
    }
}
