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
