import Foundation

public protocol WhatsNewSource: Sendable {
    /// Every highlight on the site, with absolute image URLs; nil when it can't be had.
    func feed() async -> [WhatsNewItem]?
    /// A highlight's screenshot; nil when it can't be had.
    func image(at url: URL) async -> Data?
}

/// Each release's highlights from redlamp.app (`web/app/api/whats-new`). The whole feed comes down,
/// and the app picks what its version has; nothing is sent but the request.
public struct WhatsNewRelay: WhatsNewSource {
    public static let defaultEndpoint = URL(string: "https://redlamp.app/api/whats-new")!

    public var endpoint: URL
    public var session: URLSession
    /// Short, so a slow network leaves the launch alone; what arrives late is cached for the next.
    public var timeout: TimeInterval

    public init(
        endpoint: URL = WhatsNewRelay.configuredEndpoint,
        session: URLSession = .shared,
        timeout: TimeInterval = 8,
    ) {
        self.endpoint = endpoint
        self.session = session
        self.timeout = timeout
    }

    /// `defaults write app.redlamp.mac WhatsNewEndpoint http://localhost:3000/api/whats-new` points
    /// a build at a local site or a preview deployment, drafts included.
    public static var configuredEndpoint: URL {
        UserDefaults.standard.string(forKey: "WhatsNewEndpoint").flatMap(URL.init(string:)) ?? defaultEndpoint
    }

    public func feed() async -> [WhatsNewItem]? {
        guard let data = await get(endpoint),
              let feed = try? JSONDecoder().decode(WhatsNewFeed.self, from: data)
        else { return nil }
        return feed.items.compactMap { item in
            var item = item
            guard let url = URL(string: item.image.url.relativeString, relativeTo: endpoint)?.absoluteURL
            else { return nil }
            item.image.url = url
            return item
        }
    }

    public func image(at url: URL) async -> Data? {
        await get(url)
    }

    private func get(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 || url.isFileURL
        else { return nil }
        return data
    }
}
