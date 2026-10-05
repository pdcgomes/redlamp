import CryptoKit
import Foundation

/// What What's New remembers: the last feed and its screenshots, in Caches so they can go, and in
/// the defaults, which highlights have been shown, the floor below which none open by themselves,
/// when the site was last asked, and whether they open after updates at all.
@MainActor
public final class WhatsNewStore {
    public static let shared = WhatsNewStore()

    static let seenKey = "whatsNew.seen"
    static let floorKey = "whatsNew.floor"
    static let checkedKey = "whatsNew.checked"
    public static let opensKey = "whatsNew.opensAfterUpdates"
    /// The site is asked on each new version, and at most this often after that.
    static let checkInterval: TimeInterval = 24 * 3600

    public static let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "Redlamp/WhatsNew", directoryHint: .isDirectory)

    let directory: URL
    let defaults: UserDefaults

    public init(directory: URL = WhatsNewStore.defaultDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    /// Settings › About's "Show what's new after updates"; on unless turned off.
    public var opensAfterUpdates: Bool {
        get { defaults.object(forKey: Self.opensKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.opensKey) }
    }

    var seen: Set<String> {
        Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
    }

    func markSeen(_ items: [WhatsNewItem]) {
        defaults.set(seen.union(items.map(\.id)).sorted(), forKey: Self.seenKey)
    }

    /// Highlights in this version or earlier never open by themselves.
    var floor: AppVersion? {
        defaults.string(forKey: Self.floorKey).flatMap(AppVersion.init)
    }

    /// At a first launch: what's already in this version isn't news. The floor only rises.
    func raiseFloor(to version: AppVersion) {
        if floor.map({ $0 < version }) ?? true {
            defaults.set(version.description, forKey: Self.floorKey)
        }
    }

    func isCheckDue(version: AppVersion, now: Date) -> Bool {
        guard let checked = defaults.dictionary(forKey: Self.checkedKey),
              checked["version"] as? String == version.description,
              let at = checked["at"] as? Date
        else { return true }
        return now.timeIntervalSince(at) >= Self.checkInterval || now < at
    }

    func markChecked(version: AppVersion, now: Date) {
        defaults.set(["version": version.description, "at": now], forKey: Self.checkedKey)
    }

    private var feedFile: URL {
        directory.appending(path: "feed.json")
    }

    var cachedFeed: [WhatsNewItem]? {
        guard let data = try? Data(contentsOf: feedFile) else { return nil }
        return try? JSONDecoder().decode([WhatsNewItem].self, from: data)
    }

    /// Keeps `items` as the feed, and only their screenshots.
    func cache(_ items: [WhatsNewItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: feedFile, options: .atomic)
        let kept = Set(items.map { imageFile(for: $0.image.url).lastPathComponent })
        let images = directory.appending(path: "images")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []
            where !kept.contains(name) {
            try? FileManager.default.removeItem(at: images.appending(path: name))
        }
    }

    private func imageFile(for url: URL) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "images/\(name).\(url.pathExtension.isEmpty ? "img" : url.pathExtension)")
    }

    func cachedImage(for url: URL) -> Data? {
        try? Data(contentsOf: imageFile(for: url))
    }

    func cache(image: Data, for url: URL) {
        let file = imageFile(for: url)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? image.write(to: file, options: .atomic)
    }
}
