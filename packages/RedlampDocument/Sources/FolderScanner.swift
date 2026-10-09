import Foundation
import RedlampEngineAPI

/// A photo found by a listing, with what the filmstrip needs before any file is read.
public struct PhotoEntry: Sendable, Hashable {
    public let url: URL
    public let size: Int64
    public let modified: Date
    /// A `.redlamp` sidecar sits beside it.
    public let hasSidecar: Bool
    /// The sidecar can be read without waiting for iCloud Drive (or there is none).
    public let sidecarIsLocal: Bool
    /// The photo itself is on this Mac, not only in iCloud Drive.
    public let isLocal: Bool
    /// When the sidecar last changed, so a sidecar edited elsewhere is read again.
    public let sidecarModified: Date?

    public init(
        url: URL, size: Int64 = 0, modified: Date = .distantPast, hasSidecar: Bool = false,
        sidecarIsLocal: Bool = true, isLocal: Bool = true, sidecarModified: Date? = nil,
    ) {
        self.url = url
        self.size = size
        self.modified = modified
        self.hasSidecar = hasSidecar
        self.sidecarIsLocal = sidecarIsLocal
        self.isLocal = isLocal
        self.sidecarModified = sidecarModified
    }

    public var name: String {
        url.lastPathComponent
    }
}

/// One directory's photos and subfolders, both in Finder's order.
public struct FolderListing: Sendable, Hashable {
    public let folder: URL
    public let photos: [PhotoEntry]
    public let subfolders: [URL]

    public init(folder: URL, photos: [PhotoEntry], subfolders: [URL]) {
        self.folder = folder
        self.photos = photos
        self.subfolders = subfolders
    }
}

/// Lists folders of photos without reading any of them.
public enum FolderScanner {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// One listing: photos, the sidecars beside them, and subfolders (packages and hidden folders
    /// aren't folders here). The resource values arrive with the listing itself. iCloud Drive's
    /// download state, which costs ten times the rest of the listing, is asked for only in a folder
    /// iCloud Drive syncs. URLs are built on `folder` as given (the listing's own may resolve `/var`
    /// to `/private/var`), so they match the URLs the rest of the app has for the same files.
    public static func list(_ folder: URL) throws -> FolderListing {
        let ubiquitous = (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        let keys = ubiquitous ? keys + [.ubiquitousItemDownloadingStatusKey] : keys
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
        )
        let keySet = Set(keys)
        var files: [(name: String, values: URLResourceValues)] = []
        var sidecars: [String: (isLocal: Bool, modified: Date?)] = [:]
        var subfolders: [String] = []
        files.reserveCapacity(entries.count)
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: keySet) else { continue }
            var name = entry.lastPathComponent
            name.makeContiguousUTF8()
            let ext = (name as NSString).pathExtension.lowercased()
            if ext == "redlamp" {
                sidecars[String(name.dropLast(".redlamp".count))] = (isLocal(values), values.contentModificationDate)
            } else if values.isDirectory == true {
                if values.isPackage != true, ext != FocusStackDocument.fileExtension {
                    subfolders.append(name)
                }
            } else if SupportedFormats.isSupported(extension: ext) {
                files.append((name, values))
            }
        }
        files.sort { FileOrder.precedes($0.name, $1.name) }
        let photos = files.map { name, values in
            let sidecar = sidecars[name]
            return PhotoEntry(
                url: folder.appending(path: name, directoryHint: .notDirectory),
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast,
                hasSidecar: sidecar != nil,
                sidecarIsLocal: sidecar?.isLocal ?? true,
                isLocal: isLocal(values),
                sidecarModified: sidecar?.modified,
            )
        }
        return FolderListing(
            folder: folder,
            photos: photos,
            subfolders: subfolders.sorted(by: FileOrder.precedes)
                .map { folder.appending(path: $0, directoryHint: .isDirectory) },
        )
    }

    private static func isLocal(_ values: URLResourceValues) -> Bool {
        guard let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status == .current || status == .downloaded
    }

    /// `root` and every folder beneath it, depth first in Finder's order: a folder's photos, then
    /// each subfolder's. Folders are listed in parallel on `scheduler`, and each listing is yielded
    /// as soon as every folder before it has been. A folder that can't be listed is skipped.
    public static func walk(
        _ root: URL, scheduler: WorkScheduler = .shared, lane: WorkScheduler.Lane = .onScreen,
    ) -> AsyncStream<FolderListing> {
        AsyncStream { continuation in
            let task = Task {
                await subtree(root, scheduler: scheduler, lane: lane) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Lists `folder`, yields it, then yields its subfolders' subtrees in order. Every subtree is
    /// listed at once (as wide as the lane), buffering what it finds until its turn.
    private static func subtree(
        _ folder: URL, scheduler: WorkScheduler, lane: WorkScheduler.Lane,
        yield: @escaping @Sendable (FolderListing) -> Void,
    ) async {
        guard let listing = try? await scheduler.run(lane, { try list(folder) }) else { return }
        yield(listing)
        guard !listing.subfolders.isEmpty, !Task.isCancelled else { return }
        let streams = listing.subfolders.map { child in
            AsyncStream<FolderListing> { continuation in
                let task = Task {
                    await subtree(child, scheduler: scheduler, lane: lane) { continuation.yield($0) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        for stream in streams {
            for await found in stream {
                yield(found)
            }
        }
    }
}

/// The order Folders lists file names in, and the library's lists with it (`key`): case-insensitive,
/// with runs of digits compared as numbers, so `IMG_9.ARW` comes before `IMG_10.ARW`, and every other
/// character by its code, so `DSC-1` before `DSC1` before `DSC_1` (the Finder puts punctuation
/// before digits). A name beyond ASCII is compared with its case, accents and width folded, then,
/// against a name that folds the same, after it if that one is all ASCII, else by its folded case.
/// ASCII names are compared directly; any other pair by their keys, so the order is the keys' for
/// every pair of names.
public enum FileOrder {
    public static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        var lhs = lhs
        var rhs = rhs
        if let result = lhs.withUTF8({ a in rhs.withUTF8 { b in compareASCII(a, b) } }) {
            return result
        }
        let (left, right) = (key(lhs), key(rhs))
        return left == right ? .orderedSame : left.lexicographicallyPrecedes(right) ? .orderedAscending
            : .orderedDescending
    }

    /// Bytes that sort as the names do, so a million names sort without comparing strings.
    public static func key(_ name: String) -> [UInt8] {
        var key = ContiguousArray<UInt8>()
        appendKey(of: name, to: &key)
        return Array(key)
    }

    /// Appends `name`'s key to `key`: A to Z lowercased, a run of digits as a marker, the count of
    /// its digits after leading zeros and then those digits (a single zero for a run of zeros), and
    /// every other byte as it is. A name beyond ASCII is keyed folded, then a zero and its bytes with
    /// only its case folded, so names that fold the same follow the one all ASCII.
    public static func appendKey(of name: String, to key: inout ContiguousArray<UInt8>) {
        let isASCII = name.utf8.allSatisfy { $0 < 0x80 }
        let folded = isASCII ? name
            : name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // Where the run of digits being read keeps its count, -1 outside a run.
        var countAt = -1
        var digits = 0
        func endDigits() {
            guard countAt >= 0 else { return }
            if digits == 0 {
                key.append(UInt8(ascii: "0"))
                digits = 1
            }
            key[countAt] = UInt8(min(digits, 255))
            countAt = -1
        }
        for byte in folded.utf8 {
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                if countAt < 0 {
                    key.append(digitMarker)
                    countAt = key.count
                    key.append(0)
                    digits = 0
                }
                if digits > 0 || byte != UInt8(ascii: "0") {
                    key.append(byte)
                    digits += 1
                }
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"):
                endDigits()
                key.append(byte + 0x20)
            default:
                endDigits()
                key.append(byte)
            }
        }
        endDigits()
        guard !isASCII else { return }
        key.append(0)
        key
            .append(contentsOf: name.folding(options: .caseInsensitive, locale: nil)
                .precomposedStringWithCanonicalMapping
                .utf8)
    }

    /// A digit's own code, so a run of digits sorts against any other character as `compareASCII`
    /// has a digit do: after space, `-`, `.` and the others below it, before `:`, `_` and letters.
    private static let digitMarker = UInt8(ascii: "0")

    /// Nil when a byte beyond ASCII comes before the names differ: their keys tell then.
    private static func compareASCII(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>)
        -> ComparisonResult? {
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            let x = a[i]
            let y = b[j]
            if x >= 0x80 || y >= 0x80 {
                return nil
            }
            if isDigit(x), isDigit(y) {
                let (endA, endB, order) = compareNumbers(a, from: i, b, from: j)
                // A fullwidth digit or a mark after a run folds into it, so its keys tell.
                if endA < a.count && a[endA] >= 0x80 || endB < b.count && b[endB] >= 0x80 {
                    return nil
                }
                if order != .orderedSame {
                    return order
                }
                i = endA
                j = endB
                continue
            }
            let lowerX = lower(x)
            let lowerY = lower(y)
            if lowerX != lowerY {
                return lowerX < lowerY ? .orderedAscending : .orderedDescending
            }
            i += 1
            j += 1
        }
        if a[i...].contains(where: { $0 >= 0x80 }) || b[j...].contains(where: { $0 >= 0x80 }) {
            return nil
        }
        let remainingA = a.count - i
        let remainingB = b.count - j
        if remainingA != remainingB {
            return remainingA < remainingB ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /// Compares the runs of digits starting at `i` and `j` by value, and returns where they end.
    private static func compareNumbers(
        _ a: UnsafeBufferPointer<UInt8>, from i: Int, _ b: UnsafeBufferPointer<UInt8>, from j: Int,
    ) -> (Int, Int, ComparisonResult) {
        func run(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> (start: Int, end: Int) {
            var end = start
            while end < bytes.count, isDigit(bytes[end]) {
                end += 1
            }
            var first = start
            while first < end - 1, bytes[first] == 0x30 {
                first += 1
            }
            return (first, end)
        }
        let runA = run(a, from: i)
        let runB = run(b, from: j)
        let length = runA.end - runA.start
        if length != runB.end - runB.start {
            return (runA.end, runB.end, length < runB.end - runB.start ? .orderedAscending : .orderedDescending)
        }
        for k in 0 ..< length where a[runA.start + k] != b[runB.start + k] {
            return (runA.end, runB.end, a[runA.start + k] < b[runB.start + k] ? .orderedAscending : .orderedDescending)
        }
        return (runA.end, runB.end, .orderedSame)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte
    }
}
