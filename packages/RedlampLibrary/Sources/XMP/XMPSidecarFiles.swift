import Foundation
import RedlampDocument

/// The photos of a folder that share one `.xmp` name, whatever its case: `IMG_1234.ARW` and
/// `IMG_1234.JPG` share `IMG_1234.xmp`, as Capture One writes it and Lightroom reads it for the raw.
/// darktable names its own after each photo, `IMG_1234.ARW.xmp`, which is read and never written.
struct XMPGroup: Sendable {
    struct Member: Sendable {
        let entry: FileEntry
        /// Its row; nil for a photo the index doesn't have yet.
        let record: PhotoRecord?
        /// darktable's `.xmp` beside it.
        let darktable: FileEntry?
        /// A `.redlamp` sidecar is listed beside it.
        let besideSidecar: Bool

        var name: String {
            entry.name
        }

        /// The time its camera recorded and the zone its file records, as its row keeps them; nil without
        /// a row or a capture time.
        var camera: XMPCaptureTime? {
            record.flatMap { row in row.cameraTime.map { XMPCaptureTime(time: $0, offset: row.cameraZone) } }
        }
    }

    let folder: String
    /// The raw first, then the rest in Finder's order: the `.xmp` is the raw's, as Lightroom reads it.
    let members: [Member]
    /// The shared `.xmp`, as listed.
    let shared: FileEntry?

    /// The shared `.xmp`'s name as listed, else the name it's written under: the first member's
    /// without its extension.
    var sharedName: String {
        shared?.name ?? (members[0].name as NSString).deletingPathExtension + ".xmp"
    }

    func url(_ name: String) -> URL {
        URL(fileURLWithPath: folder, isDirectory: true).appending(path: name, directoryHint: .notDirectory)
    }

    /// The groups of `folder`'s listing with a photo in `selected`, by their photos' rows in it.
    static func groups(
        in folder: String, entries: [FileEntry], rows: [String: PhotoRecord], selected: Set<Int64>,
    ) -> [XMPGroup] {
        var xmps: [String: FileEntry] = [:]
        var sidecars = Set<String>()
        var photos: [FileEntry] = []
        for entry in entries {
            let name = entry.name.lowercased()
            if name.hasSuffix(".redlamp") {
                sidecars.insert(String(entry.name.dropLast(".redlamp".count)))
            } else if !entry.isDirectory, name.hasSuffix(".xmp") {
                xmps[name] = entry
            } else if FolderWalk.isPhoto(entry) {
                photos.append(entry)
            }
        }
        let stems = Dictionary(grouping: photos) { ($0.name as NSString).deletingPathExtension.lowercased() }
        return stems.compactMap { stem, photos -> XMPGroup? in
            guard photos.contains(where: { rows[$0.name].map { selected.contains($0.id) } ?? false })
            else { return nil }
            let ordered = photos.sorted { lhs, rhs in
                let (lhsRaw, rhsRaw) = (isRaw(lhs.name), isRaw(rhs.name))
                return lhsRaw != rhsRaw ? lhsRaw : FileOrder.precedes(lhs.name, rhs.name)
            }
            let members = ordered.map { entry in
                Member(
                    entry: entry, record: rows[entry.name], darktable: xmps[entry.name.lowercased() + ".xmp"],
                    besideSidecar: sidecars.contains(entry.name),
                )
            }
            return XMPGroup(folder: folder, members: members, shared: xmps[stem + ".xmp"])
        }.sorted { FileOrder.precedes($0.members[0].name, $1.members[0].name) }
    }

    private static func isRaw(_ name: String) -> Bool {
        PhotoRecord.Kind(pathExtension: (name as NSString).pathExtension) == .raw
    }
}

/// Writes `.xmp` sidecars: only ever a `.xmp`, under file coordination as every sidecar is, and
/// atomically, built under a hidden name beside it (one an interrupted save would leave, which
/// opening the folder removes) and renamed over it. A new one never takes the place of a file that
/// appeared meanwhile, and an existing one is replaced only while it holds the bytes it was read
/// with, so another app's write in between is never lost.
enum XMPSidecarWriter {
    enum Failure: Error, Sendable, CustomStringConvertible {
        case notXMP(URL)
        /// Another app changed it, or made it, since it was read.
        case changed(URL)
        case cannotWrite(URL, Int32)

        var description: String {
            switch self {
            case let .notXMP(url): "\(url.lastPathComponent) isn't an .xmp"
            case let .changed(url): "\(url.lastPathComponent) changed while it was being written: left as it is"
            case let .cannotWrite(url, code): "\(url.lastPathComponent) couldn't be written: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Writes `bytes` at `target` in place of `expected` (nil for a new file); returns the file
    /// as written.
    static func write(_ bytes: [UInt8], to target: URL, replacing expected: [UInt8]?) throws -> XMPFileStamp? {
        guard target.pathExtension.lowercased() == "xmp" else { throw Failure.notXMP(target) }
        var outcome: Result<XMPFileStamp?, any Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: target, options: .forReplacing, error: &coordinationError,
        ) { url in
            outcome = Result { try write(bytes, at: url, replacing: expected) }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try (outcome ?? .failure(CocoaError(.fileWriteUnknown))).get()
    }

    private static func write(_ bytes: [UInt8], at url: URL, replacing expected: [UInt8]?) throws -> XMPFileStamp? {
        let path = url.path
        var info = stat()
        let exists = lstat(path, &info) == 0
        if let expected {
            guard exists, (info.st_mode & S_IFMT) == S_IFREG, let current = try? Data(contentsOf: url),
                  current.elementsEqual(expected)
            else { throw Failure.changed(url) }
        } else if exists {
            throw Failure.changed(url)
        }
        let staging = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).redlamp.\(UUID().uuidString)")
        let mode = exists ? info.st_mode & 0o7777 : 0o644
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(mode))
        guard descriptor >= 0 else { throw Failure.cannotWrite(url, errno) }
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let writeError = errno
        let closed = close(descriptor) == 0
        guard written == bytes.count, closed else {
            unlink(staging.path)
            throw Failure.cannotWrite(url, written == bytes.count ? errno : writeError)
        }
        if exists {
            _ = chmod(staging.path, mode_t(mode))
        }
        let renamed = exists ? rename(staging.path, path) : renamex_np(staging.path, path, UInt32(RENAME_EXCL))
        guard renamed == 0 else {
            let code = errno
            unlink(staging.path)
            throw code == EEXIST ? Failure.changed(url) : Failure.cannotWrite(url, code)
        }
        return XMPFileStamp(at: url)
    }
}
