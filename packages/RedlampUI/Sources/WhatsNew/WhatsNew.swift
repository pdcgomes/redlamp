import AppKit
import Foundation

/// When What's New opens by itself, and what it shows (UX-14): after an update, the highlights of
/// this version and earlier that haven't been shown, once each, and never for launches made by
/// tooling or builds from source, which don't update themselves. Help › What's New in Redlamp
/// shows the recent ones at any time.
public enum WhatsNew {
    public enum Launch: Equatable, Sendable {
        case nothing
        /// A first launch: the welcome opens, and what's already in this version isn't news.
        case setFloor
        /// Look for highlights not yet shown.
        case check
        /// `--whats-new`: open it whatever has been seen.
        case open
    }

    /// At most this many open by themselves; Help shows at most `recentLimit`.
    static let openLimit = 6
    static let recentLimit = 8

    /// `welcomeOpens`: the welcome opens by itself at this launch, so this is a first launch.
    public static func atLaunch(
        arguments: [String], updatesItself: Bool, opensAfterUpdates: Bool, welcomeOpens: Bool,
    ) -> Launch {
        if arguments.contains("--whats-new") {
            return .open
        }
        if arguments.contains(where: Welcome.toolingArguments.contains) {
            return .nothing
        }
        if welcomeOpens {
            return .setFloor
        }
        return updatesItself && opensAfterUpdates ? .check : .nothing
    }

    /// In this version or earlier, above the floor, not yet shown; newest first. A build from
    /// source (`version` nil) has every highlight.
    static func unseen(
        _ items: [WhatsNewItem], version: AppVersion?, floor: AppVersion?, seen: Set<String>,
    ) -> [WhatsNewItem] {
        let fresh = items.filter { item in
            (version.map { item.version <= $0 } ?? true) && (floor.map { item.version > $0 } ?? true)
                && !seen.contains(item.id)
        }
        return Array(fresh.sorted(by: WhatsNewItem.newestFirst).prefix(openLimit))
    }

    /// The latest highlights in this version or earlier, newest first.
    static func recent(_ items: [WhatsNewItem], version: AppVersion?) -> [WhatsNewItem] {
        let available = items.filter { item in version.map { item.version <= $0 } ?? true }
        return Array(available.sorted(by: WhatsNewItem.newestFirst).prefix(recentLimit))
    }
}

/// Highlights with their screenshots, by item, ready for the window.
public struct WhatsNewPages {
    public var items: [WhatsNewItem]
    public var images: [String: NSImage]
}

/// Highlights for the window: from the site when it's time to ask, otherwise, or when the site
/// can't be reached, from the cache, which everything that arrives goes into.
@MainActor
public final class WhatsNewLoader {
    public let store: WhatsNewStore
    let source: any WhatsNewSource

    public init(store: WhatsNewStore = .shared, source: any WhatsNewSource = WhatsNewRelay()) {
        self.store = store
        self.source = source
    }

    /// The highlights to open at this launch, with every screenshot, or nil. `version` is nil in
    /// builds from source.
    public func atLaunch(_ launch: WhatsNew.Launch, version: AppVersion?, now: Date = .now) async -> WhatsNewPages? {
        switch launch {
        case .nothing:
            return nil
        case .setFloor:
            if let version {
                store.raiseFloor(to: version)
            }
            return nil
        case .check, .open:
            let asking = launch == .open || version.map { store.isCheckDue(version: $0, now: now) } ?? true
            let items = await feed(asking: asking, version: version, now: now)
            var shown = WhatsNew.unseen(items, version: version, floor: store.floor, seen: store.seen)
            if launch == .open, shown.isEmpty {
                shown = WhatsNew.recent(items, version: version)
            }
            let images = await images(for: shown)
            // A page without its screenshot waits for a launch that has it.
            guard !shown.isEmpty, launch == .open || images.count == shown.count else { return nil }
            return WhatsNewPages(items: shown, images: images)
        }
    }

    /// Help › What's New in Redlamp: the recent highlights, from the site or the cache.
    public func recent(version: AppVersion?, now: Date = .now) async -> WhatsNewPages {
        let items = await WhatsNew.recent(feed(asking: true, version: version, now: now), version: version)
        return await WhatsNewPages(items: items, images: images(for: items))
    }

    /// Shown, so they don't open by themselves again.
    public func markShown(_ pages: WhatsNewPages) {
        store.markSeen(pages.items)
    }

    func feed(asking: Bool, version: AppVersion?, now: Date) async -> [WhatsNewItem] {
        if asking, let items = await source.feed() {
            store.cache(items)
            if let version {
                store.markChecked(version: version, now: now)
            }
            return items
        }
        return store.cachedFeed ?? []
    }

    func images(for items: [WhatsNewItem]) async -> [String: NSImage] {
        var images: [String: NSImage] = [:]
        var missing: [WhatsNewItem] = []
        for item in items {
            if let data = store.cachedImage(for: item.image.url), let image = NSImage(data: data) {
                images[item.id] = image
            } else {
                missing.append(item)
            }
        }
        let source = source
        let fetched = await withTaskGroup(of: (WhatsNewItem, Data?).self) { group in
            for item in missing {
                group.addTask { await (item, source.image(at: item.image.url)) }
            }
            var results: [(WhatsNewItem, Data?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        for case let (item, data?) in fetched {
            guard let image = NSImage(data: data) else { continue }
            store.cache(image: data, for: item.image.url)
            images[item.id] = image
        }
        return images
    }
}
