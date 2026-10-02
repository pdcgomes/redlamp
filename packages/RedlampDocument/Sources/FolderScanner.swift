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

    public init(
        url: URL, size: Int64 = 0, modified: Date = .distantPast, hasSidecar: Bool = false,
        sidecarIsLocal: Bool = true, isLocal: Bool = true,
    ) {
        self.url = url
        self.size = size
        self.modified = modified
        self.hasSidecar = hasSidecar
        self.sidecarIsLocal = sidecarIsLocal
        self.isLocal = isLocal
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
        var sidecars: [String: Bool] = [:]
        var subfolders: [String] = []
        files.reserveCapacity(entries.count)
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: keySet) else { continue }
            var name = entry.lastPathComponent
            name.makeContiguousUTF8()
            let ext = (name as NSString).pathExtension.lowercased()
            if ext == "redlamp" {
                sidecars[String(name.dropLast(".redlamp".count))] = isLocal(values)
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
                sidecarIsLocal: sidecar ?? true,
                isLocal: isLocal(values),
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

/// Finder's order for file names: case-insensitive, with runs of digits compared as numbers, so
/// `IMG_9.ARW` comes before `IMG_10.ARW`. ASCII names are compared directly; anything else falls
/// back to `localizedStandardCompare`.
public enum FileOrder {
    public static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        var lhs = lhs
        var rhs = rhs
        let result = lhs.withUTF8 { a in rhs.withUTF8 { b in compareASCII(a, b) } }
        return result ?? lhs.localizedStandardCompare(rhs)
    }

    /// Nil when either name isn't ASCII.
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
