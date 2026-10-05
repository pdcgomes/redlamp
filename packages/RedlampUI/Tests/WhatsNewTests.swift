import AppKit
import Foundation
import Testing
@testable import RedlampUI

private func appVersion(_ string: String) -> AppVersion {
    AppVersion(string)!
}

private func highlight(
    _ id: String, _ version: String, date: String = "2026-10-06", action: WhatsNewItem.Action? = nil,
) -> WhatsNewItem {
    WhatsNewItem(
        id: id, version: appVersion(version), date: date, symbol: "camera.badge.ellipsis", title: "Title \(id)",
        summary: "Summary", body: "Body.",
        image: .init(
            url: URL(string: "https://site.test/synced/whats-new/\(id)/shot.png")!,
            alt: "Alt",
            width: 2080,
            height: 1504,
        ),
        action: action,
    )
}

/// A small PNG, as a screenshot.
private let screenshot: Data = {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
    )!
    return bitmap.representation(using: .png, properties: [:])!
}()

/// What's New's versions, its feed and the relay that brings it (UX-14).
@Suite(.serialized)
struct WhatsNewFeedTests {
    @Test func `versions sort by their numbers, then prealpha, alpha, beta and the release`() {
        let sorted = ["0.3.0", "0.2.10-prealpha", "0.3.0-beta", "0.2.4-prealpha", "0.3.0-alpha", "0.3.0-prealpha"]
            .map(appVersion).sorted()
        #expect(sorted.map(\.description) == [
            "0.2.4-prealpha", "0.2.10-prealpha", "0.3.0-prealpha", "0.3.0-alpha", "0.3.0-beta", "0.3.0",
        ])
        #expect(appVersion("0.2.4-prealpha").short == "0.2.4")
    }

    @Test func `a version Version.xcconfig wouldn't write isn't one`() {
        for string in ["", "0.2", "0.2.4.1", "0.2.4-rc1", "0.2.4-release", "a.b.c", "0.2.x-alpha"] {
            #expect(AppVersion(string) == nil, "\(string)")
        }
    }

    @Test func `the feed skips an item it can't read, and an action this version doesn't have`() throws {
        let json = """
        {"format": 1, "items": [
          {"id": "bench", "version": "0.2.4-prealpha", "date": "2026-10-06", "symbol": "camera", "title": "T",
           "summary": "S", "body": "B", "image": {"url": "/synced/a.png", "alt": "A", "width": 2080, "height": 1504},
           "action": {"app": "testCamera", "title": "Test Your Camera…"}},
          {"id": "future", "version": "0.2.4-prealpha", "date": "2026-10-06", "symbol": "camera", "title": "T",
           "summary": "S", "body": "B", "image": {"url": "/synced/b.png", "alt": "A", "width": 2080, "height": 1504},
           "action": {"app": "somethingNew", "title": "Try It"}},
          {"id": "broken", "version": "soon"},
          {"id": "linked", "version": "0.2.4", "date": "2026-10-06", "symbol": "camera", "title": "T",
           "summary": "S", "body": "B", "image": {"url": "/synced/c.png", "alt": "A", "width": 2080, "height": 1504},
           "action": {"link": "https://redlamp.app/cameras/test", "title": "Read More"}}
        ]}
        """
        let feed = try JSONDecoder().decode(WhatsNewFeed.self, from: Data(json.utf8))
        #expect(feed.items.map(\.id) == ["bench", "future", "linked"])
        #expect(feed.items[0].action == .app(.testCamera, title: "Test Your Camera…"))
        #expect(feed.items[1].action == nil, "an action this version doesn't have shows no button")
        #expect(try feed.items[2].action == .link(
            #require(URL(string: "https://redlamp.app/cameras/test")),
            title: "Read More",
        ))
    }

    @Test func `a feed in a newer format isn't read`() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WhatsNewFeed.self, from: Data(#"{"format": 2, "items": []}"#.utf8))
        }
    }

    @Test func `every action a highlight can name opens something in the app`() {
        #expect(WhatsNewAction.allCases.map(\.shortcut) == [
            .testCamera, .sendFeedback, .filmLooks, .showShortcuts, .commandPalette,
        ])
    }

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var answers: [String: (Int, Data)] = [:]
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override static func canInit(with _: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.requests.append(request)
            guard let url = request.url, let (status, data) = Self.answers[url.absoluteString] else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func relay() -> WhatsNewRelay {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        Stub.answers = [:]
        Stub.requests = []
        return WhatsNewRelay(
            endpoint: URL(string: "https://site.test/api/whats-new")!,
            session: URLSession(configuration: configuration),
        )
    }

    @Test func `the relay asks its endpoint and makes image URLs absolute against it`() async throws {
        let relay = relay()
        Stub.answers["https://site.test/api/whats-new"] = (200, Data("""
        {"format": 1, "items": [{"id": "bench", "version": "0.2.4-prealpha", "date": "2026-10-06", "symbol": "camera",
          "title": "T", "summary": "S", "body": "B",
          "image": {"url": "/synced/whats-new/bench/shot.png", "alt": "A", "width": 2080, "height": 1504}}]}
        """.utf8))
        Stub.answers["https://site.test/synced/whats-new/bench/shot.png"] = (200, screenshot)
        let items = try #require(await relay.feed())
        #expect(items.map(\.image.url.absoluteString) == ["https://site.test/synced/whats-new/bench/shot.png"])
        #expect(await relay.image(at: items[0].image.url) == screenshot)
        #expect(Stub.requests.map(\.httpMethod) == ["GET", "GET"])
        #expect(Stub.requests.allSatisfy { $0.httpBody == nil }, "nothing is sent but the request")
    }

    @Test func `the relay has nothing when the site can't be reached or doesn't answer`() async {
        let relay = relay()
        #expect(await relay.feed() == nil)
        Stub.answers["https://site.test/api/whats-new"] = (500, Data("{}".utf8))
        #expect(await relay.feed() == nil)
        Stub.answers["https://site.test/api/whats-new"] = (200, Data("not json".utf8))
        #expect(await relay.feed() == nil)
    }

    @Test func `a WhatsNewEndpoint default points a build at another site`() {
        UserDefaults.standard.set("http://localhost:3000/api/whats-new", forKey: "WhatsNewEndpoint")
        defer { UserDefaults.standard.removeObject(forKey: "WhatsNewEndpoint") }
        #expect(WhatsNewRelay.configuredEndpoint.absoluteString == "http://localhost:3000/api/whats-new")
    }
}

/// What What's New remembers, when it opens by itself and what it loads (UX-14).
@MainActor
struct WhatsNewLaunchTests {
    private func store() throws -> WhatsNewStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WhatsNewTests-\(UUID().uuidString)")
        return try WhatsNewStore(
            directory: directory,
            defaults: #require(UserDefaults(suiteName: "WhatsNewTests-\(UUID().uuidString)")),
        )
    }

    @Test func `the feed and its screenshots are cached, and what's been shown is remembered`() throws {
        let store = try store()
        #expect(store.cachedFeed == nil)
        let items = [highlight("bench", "0.2.4-prealpha", action: .app(.testCamera, title: "Test Your Camera…"))]
        store.cache(items)
        #expect(store.cachedFeed == items)
        store.cache(image: screenshot, for: items[0].image.url)
        #expect(store.cachedImage(for: items[0].image.url) == screenshot)
        store.markSeen(items)
        store.markSeen([highlight("menu", "0.2.4-prealpha")])
        #expect(store.seen == ["bench", "menu"])
    }

    @Test func `a new feed keeps only its own screenshots`() throws {
        let store = try store()
        let dropped = highlight("bench", "0.2.4-prealpha"), kept = highlight("menu", "0.2.5-prealpha")
        store.cache([dropped, kept])
        store.cache(image: screenshot, for: dropped.image.url)
        store.cache(image: screenshot, for: kept.image.url)
        store.cache([kept])
        #expect(store.cachedImage(for: dropped.image.url) == nil)
        #expect(store.cachedImage(for: kept.image.url) == screenshot)
    }

    @Test func `the floor only rises`() throws {
        let store = try store()
        store.raiseFloor(to: appVersion("0.2.4-prealpha"))
        store.raiseFloor(to: appVersion("0.2.3-prealpha"))
        #expect(store.floor == appVersion("0.2.4-prealpha"))
        store.raiseFloor(to: appVersion("0.3.0-alpha"))
        #expect(store.floor == appVersion("0.3.0-alpha"))
    }

    @Test func `the site is asked on each new version, and at most daily after that`() throws {
        let store = try store()
        let version = appVersion("0.2.4-prealpha")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(store.isCheckDue(version: version, now: now))
        store.markChecked(version: version, now: now)
        #expect(!store.isCheckDue(version: version, now: now.addingTimeInterval(3600)))
        #expect(store.isCheckDue(version: version, now: now.addingTimeInterval(25 * 3600)))
        #expect(store.isCheckDue(version: appVersion("0.2.5-prealpha"), now: now.addingTimeInterval(60)))
    }

    @Test func `it opens after updates unless Settings turns it off`() throws {
        let store = try store()
        #expect(store.opensAfterUpdates)
        store.opensAfterUpdates = false
        #expect(!store.opensAfterUpdates)
    }

    @Test func `tooling launches and builds from source never look, and --whats-new always opens it`() {
        let launch = { (arguments: [String], updates: Bool, opens: Bool, welcome: Bool) in
            WhatsNew.atLaunch(
                arguments: arguments,
                updatesItself: updates,
                opensAfterUpdates: opens,
                welcomeOpens: welcome,
            )
        }
        #expect(launch(["Redlamp"], true, true, false) == .check)
        #expect(launch(["Redlamp"], false, true, false) == .nothing, "a build from source")
        #expect(launch(["Redlamp"], true, false, false) == .nothing, "turned off in Settings")
        #expect(launch(["Redlamp"], true, true, true) == .setFloor, "a first launch")
        for flag in Welcome.toolingArguments {
            #expect(launch(["Redlamp", "/Photos", flag], true, true, false) == .nothing, "\(flag)")
        }
        #expect(launch(["Redlamp", "--whats-new"], false, false, false) == .open)
    }

    @Test func `what opens by itself is in this version, above the floor and not yet shown, newest first`() {
        let items = [
            highlight("old", "0.2.3-prealpha"),
            highlight("bench", "0.2.4-prealpha", date: "2026-10-06"),
            highlight("menu", "0.2.4-prealpha", date: "2026-10-07"),
            highlight("seen", "0.2.4-prealpha"),
            highlight("future", "0.2.5-prealpha"),
        ]
        let shown = WhatsNew.unseen(
            items, version: appVersion("0.2.4-prealpha"), floor: appVersion("0.2.3-prealpha"), seen: ["seen"],
        )
        #expect(shown.map(\.id) == ["menu", "bench"])
        #expect(WhatsNew.unseen(items, version: nil, floor: nil, seen: []).map(\.id) == [
            "future", "menu", "bench", "seen", "old",
        ])
        let many = (0 ..< 9).map { highlight("item-\($0)", "0.2.4-prealpha") }
        #expect(WhatsNew.unseen(many, version: appVersion("0.2.4-prealpha"), floor: nil, seen: []).count == WhatsNew
            .openLimit)
    }

    @Test func `the Help menu shows the latest highlights this version has, newest first`() {
        let items = (0 ..< 12).map { highlight("item-\($0)", "0.2.\($0)-prealpha") }
        let recent = WhatsNew.recent(items, version: appVersion("0.2.10-prealpha"))
        #expect(recent.count == WhatsNew.recentLimit)
        #expect(recent.first?.id == "item-10")
    }

    actor Source: WhatsNewSource {
        var items: [WhatsNewItem]?
        var images: [URL: Data] = [:]
        var asked = 0

        init(items: [WhatsNewItem]?) {
            self.items = items
        }

        func feed() async -> [WhatsNewItem]? {
            asked += 1
            return items
        }

        func image(at url: URL) async -> Data? {
            images[url]
        }

        func set(items: [WhatsNewItem]?) {
            self.items = items
        }

        func set(image: Data?, for url: URL) {
            images[url] = image
        }
    }

    @Test func `after an update the unseen highlights load with their screenshots, and once shown don't open again`(
    ) async throws {
        let store = try store()
        let bench = highlight("bench", "0.2.4-prealpha")
        let source = Source(items: [bench])
        await source.set(image: screenshot, for: bench.image.url)
        let loader = WhatsNewLoader(store: store, source: source)
        let version = appVersion("0.2.4-prealpha")

        let pages = try #require(await loader.atLaunch(.check, version: version))
        #expect(pages.items == [bench])
        #expect(pages.images["bench"] != nil)
        #expect(store.cachedFeed == [bench])
        #expect(store.cachedImage(for: bench.image.url) == screenshot)
        loader.markShown(pages)
        #expect(await loader.atLaunch(.check, version: version) == nil)
        #expect(await source.asked == 1, "the second launch, the same day, reads the cache")
    }

    @Test func `when the site can't be reached the cache stands in, and a missing screenshot waits for another launch`(
    ) async throws {
        let store = try store()
        let bench = highlight("bench", "0.2.4-prealpha")
        store.cache([bench])
        let loader = WhatsNewLoader(store: store, source: Source(items: nil))
        let version = appVersion("0.2.4-prealpha")

        #expect(await loader.atLaunch(.check, version: version) == nil, "no screenshot yet")
        #expect(store.seen.isEmpty)
        store.cache(image: screenshot, for: bench.image.url)
        let pages = try #require(await loader.atLaunch(.check, version: version))
        #expect(pages.items == [bench])
    }

    @Test func `a first launch sets the floor, so what's already in this version stays shut`() async throws {
        let store = try store()
        let bench = highlight("bench", "0.2.4-prealpha")
        let source = Source(items: [bench])
        await source.set(image: screenshot, for: bench.image.url)
        let loader = WhatsNewLoader(store: store, source: source)

        #expect(await loader.atLaunch(.setFloor, version: appVersion("0.2.4-prealpha")) == nil)
        #expect(await source.asked == 0)
        #expect(await loader.atLaunch(.check, version: appVersion("0.2.4-prealpha")) == nil)

        let menu = highlight("menu", "0.2.5-prealpha")
        await source.set(items: [menu, bench])
        await source.set(image: screenshot, for: menu.image.url)
        let pages = try #require(await loader.atLaunch(.check, version: appVersion("0.2.5-prealpha")))
        #expect(pages.items == [menu], "the next update's highlights open")
    }

    @Test func `--whats-new and Help show the recent highlights even once they've been seen`() async throws {
        let store = try store()
        let bench = highlight("bench", "0.2.4-prealpha")
        store.markSeen([bench])
        let source = Source(items: [bench])
        await source.set(image: screenshot, for: bench.image.url)
        let loader = WhatsNewLoader(store: store, source: source)
        let version = appVersion("0.2.4-prealpha")

        #expect(await loader.atLaunch(.open, version: version)?.items == [bench])
        #expect(await loader.recent(version: version).items == [bench])
        #expect(await source.asked == 2, "both ask the site")
    }
}
