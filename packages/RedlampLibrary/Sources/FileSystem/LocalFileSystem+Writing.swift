import CryptoKit
import Foundation

/// The file operations' writes on the Mac's own file system, through its system calls. What they make
/// is named in Unicode's composed form, as naming templates make names (a file URL's path is
/// decomposed); the volume finds what's there in either form.
public extension LocalFileSystem {
    func moveItem(at source: URL, to destination: URL) throws {
        let (from, to) = (source.path, Self.composed(destination))
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 {
            return
        }
        let error = errno
        guard error == ENOTSUP || error == EINVAL else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        // A volume that can't refuse to replace in the same call (some network file systems).
        var target = stat()
        if lstat(to, &target) == 0 {
            var file = stat()
            guard lstat(from, &file) == 0, file.st_dev == target.st_dev, file.st_ino == target.st_ino else {
                throw POSIXError(.EEXIST)
            }
        }
        guard rename(from, to) == 0 else { throw POSIXError.current }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)
        guard copyfile(source.path, Self.composed(destination), nil, flags) == 0 else {
            let error = POSIXError.current
            try? removeItem(at: destination)
            throw error
        }
        try Self.synchronize(destination)
    }

    /// A folder, a link or a file its volume keeps compressed is copied as `copyItem` copies it, then read.
    func copyFile(at source: URL, to destination: URL) throws -> FileDigest {
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else {
            guard errno == ELOOP else { throw POSIXError.current }
            try copyItem(at: source, to: destination)
            return try FileDigest(of: source, in: self)
        }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw POSIXError.current }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(UF_COMPRESSED) == 0 else {
            try copyItem(at: source, to: destination)
            return try FileDigest(of: source, in: self)
        }
        let path = Self.composed(destination)
        let output = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError.current }
        do {
            defer { close(output) }
            let digest = try Self.stream(input, to: output)
            // Its permissions, dates and extended attributes, once nothing more is written.
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0, fsync(output) == 0 else {
                throw POSIXError.current
            }
            if fcntl(output, F_FULLFSYNC) != 0, ![ENOTSUP, ENOTTY, EINVAL].contains(errno) {
                throw POSIXError.current
            }
            return digest
        } catch {
            unlink(path)
            throw error
        }
    }

    /// A folder is made and each thing in it cloned, as copyfile(3) clones folders.
    func cloneItem(at source: URL, to destination: URL) throws {
        let (from, to) = (source.path, Self.composed(destination))
        var info = stat()
        guard lstat(from, &info) == 0 else { throw POSIXError.current }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            guard clonefile(from, to, UInt32(CLONE_NOFOLLOW)) == 0 else { throw POSIXError.current }
            return
        }
        guard mkdir(to, info.st_mode & 0o7777) == 0 else { throw POSIXError.current }
        do {
            for name in try FileManager.default.contentsOfDirectory(atPath: from) {
                try cloneItem(at: source.appending(path: name), to: destination.appending(path: name))
            }
            guard copyfile(from, to, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw POSIXError.current }
        } catch {
            try? FileManager.default.removeItem(atPath: to)
            throw error
        }
    }

    func createDirectory(at url: URL, withIntermediateDirectories intermediates: Bool) throws {
        let path = Self.composed(url)
        guard intermediates else {
            guard mkdir(path, 0o777) == 0 else { throw POSIXError.current }
            return
        }
        var made = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            made += "/" + part
            if mkdir(made, 0o777) != 0, errno != EEXIST {
                throw POSIXError.current
            }
        }
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(atPath: url.path)
    }

    func trashItem(at url: URL) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let trashed else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
        return trashed as URL
    }

    func trashDirectory(for url: URL) throws -> URL {
        try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)
    }

    /// The path in Unicode's composed form.
    static func composed(_ url: URL) -> String {
        url.path.precomposedStringWithCanonicalMapping
    }

    /// Writes what's left of `input` to `output`, a part at a time, hashing each part; what it read.
    private static func stream(_ input: Int32, to output: Int32) throws -> FileDigest {
        var hash = SHA256()
        var size: Int64 = 0
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: FileDigest.part, alignment: 16384)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(input, buffer.baseAddress, buffer.count)
            if count < 0 {
                guard errno == EINTR else { throw POSIXError.current }
                continue
            }
            if count == 0 {
                return FileDigest(sha256: Data(hash.finalize()), size: size)
            }
            let part = UnsafeRawBufferPointer(rebasing: buffer[..<count])
            hash.update(bufferPointer: part)
            try write(part, to: output)
            size += Int64(count)
        }
    }

    private static func write(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var written = 0
        while written < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress! + written, bytes.count - written)
            if count < 0 {
                guard errno == EINTR else { throw POSIXError.current }
                continue
            }
            written += count
        }
    }

    /// Puts a copy's files on the disk: each written out, then the drive asked to flush its cache
    /// once (`F_FULLFSYNC`), since `fsync` alone leaves them in it.
    private static func synchronize(_ copy: URL) throws {
        var files = [copy.path]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: copy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            files += (FileManager.default.subpaths(atPath: copy.path) ?? []).map { copy.path + "/" + $0 }
        }
        var last: Int32 = -1
        defer {
            if last >= 0 {
                close(last)
            }
        }
        for file in files {
            let descriptor = open(file, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                if errno == ELOOP {
                    continue
                }
                throw POSIXError.current
            }
            guard fsync(descriptor) == 0 else {
                close(descriptor)
                throw POSIXError.current
            }
            if last >= 0 {
                close(last)
            }
            last = descriptor
        }
        if last >= 0, fcntl(last, F_FULLFSYNC) != 0, ![ENOTSUP, ENOTTY, EINVAL].contains(errno) {
            throw POSIXError.current
        }
    }
}
