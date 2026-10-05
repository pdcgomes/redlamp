import Foundation

/// The Mac's own file system: a listing carries its entries' attributes (asked for up front, so
/// they come back with the listing itself), and a read is one `pread` on a descriptor opened for
/// it.
public struct LocalFileSystem: LibraryFileSystem {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .fileIdentifierKey,
    ]
    private static let keySet = Set(keys)
    private static let volumeKeys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
    ]

    public init() {}

    public func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Self.keys, options: [.skipsHiddenFiles],
        )
        return entries.compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: Self.keySet) else { return nil }
            return FileEntry(entry.lastPathComponent, values)
        }
    }

    public func attributes(of url: URL) throws -> FileEntry {
        // A new URL: the caller's caches the values it was first asked for.
        let fresh = URL(fileURLWithPath: url.path)
        return try FileEntry(url.lastPathComponent, fresh.resourceValues(forKeys: Self.keySet))
    }

    public func read(_ url: URL, range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0 else { throw POSIXError(.EINVAL) }
        let fd = url.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_RDONLY | O_CLOEXEC) } ?? -1 }
        guard fd >= 0 else { throw POSIXError.current }
        defer { close(fd) }
        var data = Data(count: range.count)
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < range.count {
                let read = pread(fd, buffer.baseAddress! + total, range.count - total, off_t(range.lowerBound + total))
                if read > 0 {
                    total += read
                } else if read == 0 {
                    break
                } else if errno != EINTR {
                    throw POSIXError.current
                }
            }
            return total
        }
        data.count = count
        return data
    }

    public func volume(of url: URL) throws -> VolumeInfo {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: Self.volumeKeys)
        return VolumeInfo(
            uuid: values.volumeUUIDString,
            name: values.volumeName,
            isLocal: values.volumeIsLocal ?? false,
            isInternal: values.volumeIsInternal ?? false,
        )
    }
}

extension FileEntry {
    init(_ name: String, _ values: URLResourceValues) {
        var name = name
        name.makeContiguousUTF8()
        self.init(
            name: name,
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast,
            fileIdentifier: values.fileIdentifier,
        )
    }
}

extension POSIXError {
    /// The error `errno` holds now.
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
