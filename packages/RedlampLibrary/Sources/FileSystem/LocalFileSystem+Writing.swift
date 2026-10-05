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
