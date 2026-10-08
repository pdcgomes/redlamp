import Foundation

/// A bench folder as one file, `.redtask`: a zip of the folder, sent to the hub in one upload or
/// by AirDrop. The system makes the zip (`NSFileCoordinator`'s upload form), so no package is
/// needed; the Mac reads the zip's directory first and refuses an archive that would write
/// outside its folder or expand too far, then extracts it with `ditto`.
public enum BenchArchive {
    public static let fileExtension = "redtask"

    public struct Entry: Sendable, Hashable {
        public var path: String
        public var compressedSize: UInt64
        public var size: UInt64
        public var isDirectory: Bool
        public var isSymbolicLink: Bool

        public init(path: String, compressedSize: UInt64, size: UInt64, isDirectory: Bool, isSymbolicLink: Bool) {
            self.path = path
            self.compressedSize = compressedSize
            self.size = size
            self.isDirectory = isDirectory
            self.isSymbolicLink = isSymbolicLink
        }
    }

    public enum ArchiveError: Error, CustomStringConvertible, Equatable {
        case notAZip
        case unsupported(String)
        case unsafe (String)
        case tooLarge(UInt64)
        case noTask
        case failed(String)

        public var description: String {
            switch self {
            case .notAZip: "not a zip archive"
            case let .unsupported(what): "unsupported zip: \(what)"
            case let .unsafe (path): "\(path) would land outside the task's folder"
            case let .tooLarge(bytes): "it expands to \(bytes >> 20) MB, more than \(BenchLimits.bytes >> 20) MB"
            case .noTask: "it holds no \(BenchManifest.fileName)"
            case let .failed(why): "couldn't unpack it: \(why)"
            }
        }
    }

    /// Zips `folder` into `destination` (replaced if it exists).
    public static func make(_ folder: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator()
            .coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zip in
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: zip, to: destination)
                } catch {
                    copyError = error
                }
            }
        if let error = coordinationError ?? copyError {
            throw error
        }
    }

    /// The archive's entries, from its central directory, without extracting anything.
    public static func entries(_ archive: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw ArchiveError.notAZip }
        // The end-of-central-directory record sits in the last 22 bytes plus a comment of up to 64 KB.
        let tailLength = min(length, 22 + 65535)
        try handle.seek(toOffset: length - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else { throw ArchiveError.notAZip }
        let count = tail.uint16(at: eocd + 10)
        let directorySize = UInt64(tail.uint32(at: eocd + 12))
        let directoryOffset = UInt64(tail.uint32(at: eocd + 16))
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else { throw ArchiveError.unsupported("zip64") }
        guard directoryOffset + directorySize <= length else { throw ArchiveError.notAZip }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()
        var entries: [Entry] = []
        var offset = 0
        for _ in 0 ..< count {
            guard offset + 46 <= directory.count, directory.uint32(at: offset) == 0x0201_4B50 else {
                throw ArchiveError.notAZip
            }
            let compressed = directory.uint32(at: offset + 20), size = directory.uint32(at: offset + 24)
            let nameLength = Int(directory.uint16(at: offset + 28))
            let extraLength = Int(directory.uint16(at: offset + 30)),
                commentLength = Int(directory.uint16(at: offset + 32))
            let madeBy = directory.uint16(at: offset + 4) >> 8
            let external = directory.uint32(at: offset + 38)
            guard offset + 46 + nameLength <= directory.count else { throw ArchiveError.notAZip }
            let name = String(
                decoding: directory[(directory.startIndex + offset + 46) ..<
                    (directory.startIndex + offset + 46 + nameLength)],
                as: UTF8.self,
            )
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF else { throw ArchiveError.unsupported("zip64") }
            // On Unix-made archives (3), the high half of the external attributes is the mode.
            let mode = madeBy == 3 ? (external >> 16) & 0o170000 : 0
            entries.append(Entry(
                path: name, compressedSize: UInt64(compressed), size: UInt64(size),
                isDirectory: name.hasSuffix("/"), isSymbolicLink: mode == 0o120000,
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Refuses an archive with an entry outside its folder, a link, too many files or too many
    /// bytes once expanded.
    public static func check(_ entries: [Entry]) throws {
        guard entries.count <= BenchLimits.files else {
            throw ArchiveError.unsupported("\(entries.count) files, more than \(BenchLimits.files)")
        }
        var total: UInt64 = 0
        for entry in entries {
            let path = entry.isDirectory ? String(entry.path.dropLast()) : entry.path
            guard BenchFile.isSafeRelativePath(path) else { throw ArchiveError.unsafe (entry.path) }
            guard !entry.isSymbolicLink else { throw ArchiveError.unsafe ("\(entry.path) (a link)") }
            total += entry.size
        }
        guard total <= UInt64(BenchLimits.bytes) else { throw ArchiveError.tooLarge(total) }
    }

    #if os(macOS)
        /// Checks and extracts an archive into `target`, a new folder the caller removes, and
        /// returns the bench folder in it (the archive's top folder, or its root).
        public static func extract(_ archive: URL, into target: URL) throws -> URL {
            try check(entries(archive))
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", "--norsrc", archive.path, target.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw ArchiveError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // The Finder's archiver adds resource forks under `__MACOSX/`; nothing reads them.
            try? FileManager.default.removeItem(at: target.appending(path: "__MACOSX"))
            if FileManager.default.fileExists(atPath: target.appending(path: BenchManifest.fileName).path) {
                return target
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: target, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
            )
            guard children.count == 1, let folder = children.first,
                  FileManager.default.fileExists(atPath: folder.appending(path: BenchManifest.fileName).path)
            else { throw ArchiveError.noTask }
            return folder
        }
    #endif

    private static func lastIndex(of signature: [UInt8], in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count else { return nil }
        for index in stride(from: bytes.count - signature.count, through: 0, by: -1)
            where bytes[index] == signature[0] && Array(bytes[index ..< index + signature.count]) == signature {
            return index
        }
        return nil
    }
}

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
