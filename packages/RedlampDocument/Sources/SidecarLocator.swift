import Foundation

/// Where photos' `.redlamp` sidecars are kept (DEC-43): beside each photo, `IMG_1234.ARW.redlamp`,
/// or, for the folders that keep them in Redlamp on this Mac, in a folder on the Mac's own disk by
/// the photo's volume and its path from the volume's root,
/// `<folder>/<volume UUID>/DCIM/100CANON/IMG_1234.CR3.redlamp`, so they're found again wherever the
/// volume is mounted. It places Redlamp's own sidecars only: other apps' `.xmp` sit beside the photo.
///
/// A sidecar is written in one place and read from either (`readURL(for:)`), so a folder whose
/// setting changed reads what was written before.
public struct SidecarLocator: Sendable, Hashable {
    /// A folder the locator knows: where it is on its volume, and where its sidecars are written.
    public struct Root: Sendable, Hashable {
        /// The folder's path, as its photos' URLs have it.
        public var path: String
        /// The library's name for its volume: the volume's UUID where it has one.
        public var volume: String
        /// The folder's path from its volume's root, without a slash at either end: empty for the
        /// volume's root.
        public var pathInVolume: String
        /// Its photos' sidecars are written on this Mac rather than beside them.
        public var onThisMac: Bool

        public init(path: String, volume: String, pathInVolume: String, onThisMac: Bool) {
            self.path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            self.volume = volume
            self.pathInVolume = pathInVolume.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            self.onThisMac = onThisMac
        }
    }

    /// Where sidecars kept on this Mac go (the library's `LibraryPaths.sidecars`); nil for none.
    public let folder: URL?
    /// The folders it knows, the deepest first.
    public let roots: [Root]

    /// Every sidecar beside its photo, as `SidecarStore()` keeps them.
    public static let besidePhotos = SidecarLocator()

    public init() {
        folder = nil
        roots = []
    }

    public init(folder: URL, roots: [Root]) {
        self.folder = folder
        self.roots = roots.sorted { $0.path.count > $1.path.count }
    }

    /// The sidecar beside the photo: `IMG_1234.ARW.redlamp`.
    public static func besidePhoto(_ image: URL) -> URL {
        image.appendingPathExtension("redlamp")
    }

    /// Where the photo's sidecar is, or would be, on this Mac; nil for a photo outside the folders it
    /// knows.
    public func onThisMac(_ image: URL) -> URL? {
        guard let (root, relative) = root(of: image), let folder else { return nil }
        var url = folder.appending(
            path: root.volume.replacingOccurrences(of: "/", with: ":"),
            directoryHint: .isDirectory,
        )
        if !root.pathInVolume.isEmpty {
            url.append(path: root.pathInVolume, directoryHint: .isDirectory)
        }
        return url.appending(path: relative + ".redlamp", directoryHint: .notDirectory)
    }

    /// Where the photo's sidecar is written: on this Mac for a folder that keeps them there, beside
    /// the photo otherwise.
    public func url(for image: URL) -> URL {
        guard let (root, _) = root(of: image), root.onThisMac, let mac = onThisMac(image) else {
            return Self.besidePhoto(image)
        }
        return mac
    }

    /// Where the photo's sidecar is read from. For a photo in a folder the locator knows, that's
    /// beside the photo, or on this Mac when only that one is there or its edit was saved later;
    /// otherwise beside the photo. Where neither is there, it's where the sidecar would be written.
    public func readURL(for image: URL) -> URL {
        let beside = Self.besidePhoto(image)
        guard let mac = onThisMac(image) else { return beside }
        switch (Self.isPresent(beside), FileManager.default.fileExists(atPath: mac.path)) {
        case (true, false): return beside
        case (false, true): return mac
        case (false, false): return url(for: image)
        case (true, true):
            guard let macSaved = Self.saved(mac), let besideSaved = Self.saved(beside), macSaved > besideSaved
            else { return beside }
            return mac
        }
    }

    /// The deepest folder `image` is in, and its path below that folder.
    private func root(of image: URL) -> (Root, String)? {
        guard !roots.isEmpty else { return nil }
        let path = image.path
        for root in roots {
            if root.path == "/" {
                if path.count > 1 {
                    return (root, String(path.dropFirst()))
                }
            } else if path.count > root.path.count + 1, path.hasPrefix(root.path),
                      path.dropFirst(root.path.count).first == "/" {
                return (root, String(path.dropFirst(root.path.count + 1)))
            }
        }
        return nil
    }

    /// Whether the sidecar is there, downloaded or not: iCloud Drive leaves a placeholder in place
    /// of one it evicted.
    private static func isPresent(_ sidecar: URL) -> Bool {
        let placeholder = sidecar.deletingLastPathComponent().appending(path: ".\(sidecar.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: sidecar.path)
            || FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// When the sidecar's edit was saved, as it records it; nil when it can't be read.
    private static func saved(_ sidecar: URL) -> Date? {
        struct Probe: Decodable {
            var modified: Date?
        }
        guard let data = try? Data(contentsOf: SidecarStore.editURL(inSidecar: sidecar)),
              let probe = try? JSONDecoder.sidecar.decode(Probe.self, from: data)
        else { return nil }
        return probe.modified ?? .distantPast
    }
}
