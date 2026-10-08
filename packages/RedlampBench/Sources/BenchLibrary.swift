import Foundation

/// The phone's bench folders, in the App Group container the app and its share extension share:
/// `Tasks/` pulled from the hub, `Looks/` made on the phone, `Kit/` the capture kit, and the
/// settings and send queue beside them.
public struct BenchLibrary: Sendable {
    public struct Settings: Codable, Sendable, Hashable {
        /// The hub last reached, and its token.
        public var hub: URL?
        public var hubName: String?
        public var token: String?
        /// This phone's name, as the hub lists it.
        public var device: String?
        /// The folder the share extension files results into unless told otherwise.
        public var lastUsed: String?
        public var lastSync: Date?

        public init() {}
    }

    /// A folder waiting to reach the hub, and the results digest it had when queued.
    public struct Queued: Codable, Sendable, Hashable {
        public var id: String
        public var digest: String
        public var queued: Date
        public var lastError: String?
    }

    public struct SyncReport: Sendable, Hashable {
        public var added: [String] = []
        public var updated: [String] = []
        public var withdrawn: [String] = []
        public var kitUpdated = false
    }

    public let root: URL
    private let kitOverride: URL?

    /// `kit` is the capture kit's folder when it isn't the library's own (the Mac's template).
    public init(root: URL, kit: URL? = nil) {
        self.root = root
        kitOverride = kit
    }

    public var tasksURL: URL {
        root.appending(path: "Tasks", directoryHint: .isDirectory)
    }

    public var looksURL: URL {
        root.appending(path: "Looks", directoryHint: .isDirectory)
    }

    public var kitURL: URL {
        kitOverride ?? root.appending(path: "Kit/\(BenchStore.lookKitID)", directoryHint: .isDirectory)
    }

    // MARK: - Settings and queue

    public var settings: Settings {
        get { read("settings.json") ?? Settings() }
        nonmutating set { write(newValue, to: "settings.json") }
    }

    public var queue: [Queued] {
        get { read("queue.json") ?? [] }
        nonmutating set { write(newValue, to: "queue.json") }
    }

    /// What the hub confirmed, by folder: the results digest it has.
    public var sent: [String: String] {
        get { read("sent.json") ?? [:] }
        nonmutating set { write(newValue, to: "sent.json") }
    }

    private func read<T: Decodable>(_ name: String) -> T? {
        (try? Data(contentsOf: root.appending(path: name))).flatMap { try? JSONDecoder.bench.decode(T.self, from: $0) }
    }

    private func write(_ value: some Encodable, to name: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder.bench.encode(value).write(to: root.appending(path: name), options: .atomic)
    }

    // MARK: - Folders

    public var tasks: [BenchFolder] {
        folders(in: tasksURL)
    }

    public var looks: [BenchFolder] {
        folders(in: looksURL)
    }

    public var kit: BenchFolder? {
        try? BenchFolder.load(kitURL)
    }

    /// Tasks and looks, newest first: what the share extension offers.
    public var all: [BenchFolder] {
        (tasks + looks).sorted { $0.manifest.created > $1.manifest.created }
    }

    public func folder(_ id: String) -> BenchFolder? {
        all.first { $0.id == id }
    }

    /// The folder results go to unless the owner picks another: the last one used, if it's
    /// still here, else the newest.
    public var suggested: BenchFolder? {
        let all = all
        if let id = settings.lastUsed, let folder = all.first(where: { $0.id == id }) {
            return folder
        }
        return all.first
    }

    public func markUsed(_ id: String) {
        var settings = settings
        settings.lastUsed = id
        self.settings = settings
    }

    private func folders(in url: URL) -> [BenchFolder] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        )) ?? []
        return children.compactMap { try? BenchFolder.load($0) }.sorted { $0.manifest.created > $1.manifest.created }
    }

    public func remove(_ id: String) throws {
        guard let folder = folder(id) else { return }
        try FileManager.default.removeItem(at: folder.url)
        queue.removeAll { $0.id == id }
        var sent = sent
        sent[id] = nil
        self.sent = sent
    }

    // MARK: - Look references

    /// The kit assets a set uses: the one-image kit, or the three charts with two photos or all
    /// eight.
    public static func kitAssets(_ kit: BenchFolder, set: BenchManifest.LookReference.KitSet) -> [BenchManifest.Asset] {
        let charts = kit.manifest.assets.filter { ($0.chart ?? 0) >= 1 && ($0.chart ?? 0) <= 3 }
        let photos = kit.manifest.assets.filter { $0.chart == nil }
        switch set {
        case .quick: return kit.manifest.assets.filter { $0.chart == 9 }
        case .standard: return charts + standardPhotos(photos)
        case .full: return charts + photos
        }
    }

    /// A landscape and a portrait, so vignette, grain and skin all have a photo.
    static func standardPhotos(_ photos: [BenchManifest.Asset]) -> [BenchManifest.Asset] {
        let preferred = ["contrast", "skin-light"]
        let picked = preferred.compactMap { name in photos.first { $0.id.localizedCaseInsensitiveContains(name) } }
        return picked.count == 2 ? picked : Array(photos.prefix(2))
    }

    /// A new look reference from the kit, in `Looks/`.
    public func newLook(
        _ look: BenchManifest.LookReference,
        screenshot: URL? = nil,
        date: Date = Date(),
    ) throws -> BenchFolder {
        guard let kit else { throw BenchError.notFound("the capture kit (open the app near the Lab once)") }
        let assets = Self.kitAssets(kit, set: look.kitSet)
        guard !assets.isEmpty else { throw BenchError.notFound("the \(look.kitSet.rawValue) kit images") }
        var manifest = BenchManifest(
            id: BenchManifest.newID(title: look.title, date: date), title: look.title,
            kind: BenchManifest.Kind.lookReference, created: date, app: look.app,
            steps: Self.lookSteps(look, assets: assets), completion: .everyAsset,
            pairing: [.captureChart, .fileName, .similarity], look: look,
        )
        manifest.look?.settingsScreenshot = nil
        let new = try assets.map { asset in
            guard let file = kit.file(asset.file) else { throw BenchError.outsideFolder(asset.file) }
            return BenchFolder.NewAsset(
                file: file,
                id: asset.id,
                label: asset.label,
                chart: asset.chart,
                tiles: asset.tiles,
            )
        }
        try FileManager.default.createDirectory(at: looksURL, withIntermediateDirectories: true)
        var folder = try BenchFolder.create(manifest, assets: new, in: looksURL)
        if let screenshot {
            let name = "settings.\(screenshot.pathExtension.isEmpty ? "png" : screenshot.pathExtension.lowercased())"
            try FileManager.default.copyItem(at: screenshot, to: folder.url.appending(path: name))
            folder.manifest.look?.settingsScreenshot = name
            try folder.saveManifest()
        }
        markUsed(folder.id)
        return folder
    }

    /// The steps the app writes for a look reference.
    static func lookSteps(
        _ look: BenchManifest.LookReference,
        assets: [BenchManifest.Asset],
    ) -> [BenchManifest.Step] {
        let settings = look.settings.map { " with these settings: \($0)" } ?? " at its default settings"
        let count = assets.count == 1 ? "the kit image" : "each of the \(assets.count) kit images"
        return [
            .init(
                id: "save", title: "Save the kit to Photos",
                detail: "\(look.app.isEmpty ? "The app" : look.app) opens photos from the library.",
                action: .save(assets: nil),
            ),
            .init(
                id: "apply", title: "Apply \(look.filter)\(look.variant.map { " \($0)" } ?? "")",
                detail: "Open \(count) in \(look.app.isEmpty ? "the app" : look.app) and apply the filter\(settings). "
                    + "Keep the original aspect ratio: no crop, no rotation, nothing else added.",
            ),
            .init(
                id: "export", title: "Export at full size",
                detail: "Save or export each one at the largest size and best quality the app offers.",
            ),
            .init(
                id: "share", title: "Share them back",
                detail: "Share the exports to Redlamp Bench. They pair with their kit images by themselves.",
                action: .results(assets: nil),
            ),
        ]
    }

    // MARK: - Sync with the hub

    /// Fetches new and changed tasks and the kit, and drops withdrawn tasks that have no
    /// results. A task the phone has results for keeps them, even when the hub changes it.
    public func pull(_ client: BenchClient) async throws -> SyncReport {
        var report = SyncReport()
        for listing in try await client.listings() {
            if listing.template {
                guard listing.id == BenchStore.lookKitID else { continue }
                let local = kit
                let manifest = listing.files.first { $0.path == BenchManifest.fileName }
                if let local, let manifest,
                   (try? BenchFile.sha256(local.url.appending(path: BenchManifest.fileName))) == manifest.sha256 {
                    continue
                }
                try await client.download(listing, to: kitURL)
                report.kitUpdated = true
                continue
            }
            let destination = tasksURL.appending(path: listing.id, directoryHint: .isDirectory)
            let local = try? BenchFolder.load(destination)
            if listing.withdrawn {
                if let local, local.results.results.isEmpty {
                    try FileManager.default.removeItem(at: local.url)
                    report.withdrawn.append(listing.id)
                }
                continue
            }
            if let local {
                guard listing.revision > local.manifest.revision, local.results.results.isEmpty else { continue }
                try await client.download(listing, to: destination)
                report.updated.append(listing.id)
            } else {
                try await client.download(listing, to: destination)
                report.added.append(listing.id)
            }
        }
        var settings = settings
        settings.lastSync = Date()
        self.settings = settings
        return report
    }

    /// Queues a folder for the hub, unless the hub already has these results.
    public func enqueue(_ folder: BenchFolder) {
        let digest = folder.resultsDigest
        guard sent[folder.id] != digest else { return }
        var queue = queue
        queue.removeAll { $0.id == folder.id }
        queue.append(Queued(id: folder.id, digest: digest, queued: Date()))
        self.queue = queue
    }

    /// Queues the folder once it's complete; returns whether it was queued.
    @discardableResult
    public func enqueueIfComplete(_ folder: BenchFolder) -> Bool {
        guard folder.isComplete else { return false }
        enqueue(folder)
        return true
    }

    /// Sends everything queued. What fails stays queued, with its error, for the next try.
    @discardableResult
    public func sendQueued(_ client: BenchClient) async -> [String: Result<BenchProtocol.Receipt, Error>] {
        var outcomes: [String: Result<BenchProtocol.Receipt, Error>] = [:]
        for entry in queue {
            guard let folder = folder(entry.id) else {
                queue.removeAll { $0.id == entry.id }
                continue
            }
            do {
                let receipt = try await client.send(folder)
                var sent = sent
                sent[folder.id] = receipt.resultsDigest
                self.sent = sent
                var queue = queue
                if receipt.resultsDigest == folder.resultsDigest {
                    queue.removeAll { $0.id == folder.id }
                }
                self.queue = queue
                outcomes[folder.id] = .success(receipt)
            } catch {
                var queue = queue
                if let index = queue.firstIndex(where: { $0.id == entry.id }) {
                    queue[index].lastError = "\(error)"
                }
                self.queue = queue
                outcomes[folder.id] = .failure(error)
            }
        }
        return outcomes
    }
}
