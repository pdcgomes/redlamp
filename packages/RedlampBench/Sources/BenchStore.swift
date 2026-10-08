import Foundation

/// The Mac's bench folders, outside every checkout so agents in any worktree share them:
/// `Outbox/` for tasks waiting for the phone, `Inbox/` while an arrival is checked, `Done/` for
/// what came back, and `Templates/` for the capture kit new look references start from.
public struct BenchStore: Sendable {
    public enum Area: String, CaseIterable, Sendable {
        case outbox = "Outbox"
        case inbox = "Inbox"
        case done = "Done"
        case templates = "Templates"
    }

    public let root: URL

    public init(root: URL = BenchStore.standardRoot) {
        self.root = root
    }

    /// `~/Library/Application Support/Redlamp/Bench`.
    public static var standardRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Redlamp/Bench", directoryHint: .isDirectory)
    }

    /// The template new look references copy their kit from.
    public static let lookKitID = "look-kit"

    public func url(_ area: Area) -> URL {
        root.appending(path: area.rawValue, directoryHint: .isDirectory)
    }

    public func prepare() throws {
        for area in Area.allCases {
            try FileManager.default.createDirectory(at: url(area), withIntermediateDirectories: true)
        }
    }

    /// The folders in an area that load, newest first.
    public func folders(_ area: Area) -> [BenchFolder] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url(area), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        )) ?? []
        return children.compactMap { try? BenchFolder.load($0) }
            .filter { $0.url.lastPathComponent == $0.manifest.id }
            .sorted { $0.manifest.created > $1.manifest.created }
    }

    public func folder(_ id: String, in area: Area) -> BenchFolder? {
        guard BenchManifest.isValidID(id) else { return nil }
        return try? BenchFolder.load(url(area).appending(path: id, directoryHint: .isDirectory))
    }

    /// A new task in the outbox.
    @discardableResult
    public func create(
        _ manifest: BenchManifest,
        assets: [BenchFolder.NewAsset],
        pictures: [URL] = [],
        in area: Area = .outbox,
    ) throws -> BenchFolder {
        try prepare()
        return try BenchFolder.create(manifest, assets: assets, pictures: pictures, in: url(area))
    }

    /// Takes a task back: the phone drops it, unless it already has results.
    public func withdraw(_ id: String) throws {
        guard var folder = folder(id, in: .outbox) else { throw BenchError.notFound("task \(id) in the outbox") }
        folder.manifest.withdrawn = true
        folder.manifest.revision += 1
        try folder.saveManifest()
    }

    /// What the hub says when something arrives.
    public struct Arrival: Sendable {
        public var folder: BenchFolder
        /// An earlier copy of the same task was replaced.
        public var replaced: Bool

        /// "12 results, all paired", or for a look reference "Prequel · Cine Film 2: 11 of 11".
        public var summary: String {
            let results = folder.results.results
            let unpaired = folder.results.unpaired.count
            if let look = folder.manifest.look {
                let required = folder.manifest.requiredAssets.count
                return "\(look.title): \(required - folder.missing.count) of \(required) kit images"
            }
            let count = "\(results.count) result\(results.count == 1 ? "" : "s")"
            return unpaired == 0 ? "\(count), all paired" : "\(count), \(unpaired) unpaired"
        }
    }

    #if os(macOS)
        /// Checks an archive from the phone as untrusted input, then files it in Done.
        public func receive(_ archive: URL) throws -> Arrival {
            try prepare()
            let scratch = url(.inbox).appending(path: "unpack-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: scratch) }
            return try file(BenchArchive.extract(archive, into: scratch))
        }

        /// Checks a folder (dropped on the Lab, or unpacked from an archive) and files a copy in
        /// Done, replacing an earlier copy of the same task. A complete task leaves the outbox.
        public func file(_ source: URL) throws -> Arrival {
            try prepare()
            let folder = try BenchFolder.load(source)
            let errors = folder.validate().filter { $0.severity == .error }
            guard errors.isEmpty else { throw BenchError.invalid(errors.map(\.message)) }
            let fm = FileManager.default
            let staging = url(.inbox).appending(path: "\(folder.id)-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.copyItem(at: source, to: staging)
            let destination = url(.done).appending(path: folder.id, directoryHint: .isDirectory)
            let replaced = fm.fileExists(atPath: destination.path)
            if replaced {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            let filed = try BenchFolder.load(destination)
            if filed.isComplete, let sent = self.folder(filed.id, in: .outbox) {
                try? fm.removeItem(at: sent.url)
            }
            return Arrival(folder: filed, replaced: replaced)
        }
    #endif
}
