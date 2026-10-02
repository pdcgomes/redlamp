import Foundation

/// A folder the user added to the working set: remembered by bookmark, so a folder renamed or
/// moved is followed, and by its last known path, shown while it is missing.
public struct WorkingFolder: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var path: String
    public var bookmark: Data?

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    public var name: String {
        url.lastPathComponent
    }

    /// The folder at `url`, with a bookmark made now. Reads the file system: call it off the main
    /// thread.
    public static func make(for url: URL, id: UUID = UUID()) -> WorkingFolder {
        WorkingFolder(id: id, path: url.standardizedFileURL.path, bookmark: FolderAccess.bookmark(for: url))
    }

    /// Where the folder is now: its last known path while a folder is there, else wherever its
    /// bookmark leads (a folder renamed or moved). Nil when it can't be found, as when its volume
    /// isn't mounted. Never mounts a volume or asks the user. Reads the file system: call it off
    /// the main thread.
    public func resolve() -> WorkingFolder? {
        var resolved = self
        if !Self.isDirectory(path) {
            guard let bookmark, let found = FolderAccess.resolve(bookmark), Self.isDirectory(found.url.path) else {
                return nil
            }
            resolved.path = found.url.standardizedFileURL.path
            if found.isStale {
                resolved.bookmark = FolderAccess.bookmark(for: found.url) ?? bookmark
            }
        }
        if resolved.bookmark == nil {
            resolved.bookmark = FolderAccess.bookmark(for: resolved.url)
        }
        return resolved
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether `url` is this folder or inside it.
    public func contains(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        return candidate == path || candidate.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }
}

/// Access to folders outside the app's container. Bookmarks are security-scoped once the app is
/// sandboxed (the Mac App Store build); until then they are plain, and starting access does
/// nothing, so the working set needs no change when the sandbox arrives.
public enum FolderAccess {
    public static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    public static func bookmark(for url: URL) -> Data? {
        #if os(macOS)
            let options: URL.BookmarkCreationOptions = isSandboxed ? [.withSecurityScope] : []
        #else
            let options: URL.BookmarkCreationOptions = []
        #endif
        return try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        #if os(macOS)
            var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
            if isSandboxed {
                options.insert(.withSecurityScope)
            }
        #else
            let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, stale)
    }

    /// Starts access to a folder for as long as it stays in the working set.
    @discardableResult
    public static func start(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public static func stop(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
