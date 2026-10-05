import Foundation

/// A version as `Version.xcconfig` writes it, `0.2.4-prealpha`: three numbers, then the stage,
/// which comes before the release itself (`compareVersions` in web/lib/whats-new.ts).
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public enum Stage: String, CaseIterable, Comparable, Sendable {
        case prealpha, alpha, beta, release

        public static func < (lhs: Stage, rhs: Stage) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let stage: Stage

    public init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = parts.first?.split(separator: ".").compactMap { Int($0) } ?? []
        guard numbers.count == 3, parts.first?.split(separator: ".").count == 3 else { return nil }
        let stage = parts.count == 2 ? Stage(rawValue: parts[1]) : .release
        guard let stage, stage != .release || parts.count == 1 else { return nil }
        (major, minor, patch, self.stage) = (numbers[0], numbers[1], numbers[2], stage)
    }

    /// The running app's, from its Info.plist.
    public static var current: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    public var description: String {
        stage == .release ? short : "\(short)-\(stage.rawValue)"
    }

    /// Without the stage, as titles name it: "0.2.4".
    public var short: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch)
            ? (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
            : lhs.stage < rhs.stage
    }
}

extension AppVersion: Codable {
    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let version = AppVersion(string) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not a version: \(string)",
            ))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// What a highlight's button can open: only things that open something, never anything that changes
/// an edit. The site checks against the same list (`appActions` in web/lib/whats-new.ts).
public enum WhatsNewAction: String, Codable, CaseIterable, Sendable {
    case testCamera, sendFeedback, filmLooks, showShortcuts, commandPalette

    public var shortcut: ShortcutAction {
        ShortcutAction(rawValue: rawValue)!
    }
}

/// One highlight of a release, from redlamp.app/api/whats-new (web/lib/whats-new.ts).
public struct WhatsNewItem: Codable, Hashable, Sendable, Identifiable {
    public struct Image: Codable, Hashable, Sendable {
        /// Relative to the feed's URL as the site sends it; absolute once `WhatsNewRelay` has read it.
        public var url: URL
        public var alt: String
        public var width: Int
        public var height: Int
    }

    public enum Action: Hashable, Sendable {
        case app(WhatsNewAction, title: String)
        case link(URL, title: String)

        public var title: String {
            switch self {
            case let .app(_, title), let .link(_, title): title
            }
        }
    }

    public var id: String
    /// The release it's in.
    public var version: AppVersion
    /// YYYY-MM-DD.
    public var date: String
    /// An SF Symbol, for the list of highlights.
    public var symbol: String
    public var title: String
    /// One line, for the list of highlights.
    public var summary: String
    /// A paragraph or two of inline Markdown, separated by a blank line.
    public var body: String
    public var image: Image
    /// Nil also when the site names an action this version doesn't have: the page shows no button.
    public var action: Action?

    private enum CodingKeys: String, CodingKey {
        case id, version, date, symbol, title, summary, body, image, action
    }

    private struct ActionFields: Codable {
        var app: String?
        var link: URL?
        var title: String
    }

    public init(
        id: String, version: AppVersion, date: String, symbol: String, title: String, summary: String,
        body: String, image: Image, action: Action? = nil,
    ) {
        (self.id, self.version, self.date, self.symbol) = (id, version, date, symbol)
        (self.title, self.summary, self.body, self.image, self.action) = (title, summary, body, image, action)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(AppVersion.self, forKey: .version)
        date = try container.decode(String.self, forKey: .date)
        symbol = try container.decode(String.self, forKey: .symbol)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        body = try container.decode(String.self, forKey: .body)
        image = try container.decode(Image.self, forKey: .image)
        let fields = try? container.decodeIfPresent(ActionFields.self, forKey: .action)
        if let fields, let app = fields.app.flatMap(WhatsNewAction.init(rawValue:)) {
            action = .app(app, title: fields.title)
        } else if let fields, let link = fields.link, link.scheme == "https" {
            action = .link(link, title: fields.title)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(date, forKey: .date)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(body, forKey: .body)
        try container.encode(image, forKey: .image)
        switch action {
        case let .app(app, title): try container.encode(ActionFields(app: app.rawValue, title: title), forKey: .action)
        case let .link(link, title): try container.encode(ActionFields(link: link, title: title), forKey: .action)
        case nil: break
        }
    }

    /// Newest release first, then the newest date, as the site lists them.
    static func newestFirst(_ lhs: WhatsNewItem, _ rhs: WhatsNewItem) -> Bool {
        lhs.version != rhs.version ? lhs.version > rhs.version : lhs.date != rhs.date ? lhs.date > rhs.date : lhs
            .id < rhs.id
    }
}

/// The feed as the site sends it: an item this version can't read is left out, not the whole feed.
struct WhatsNewFeed: Decodable {
    static let format = 1

    var items: [WhatsNewItem]

    private enum CodingKeys: String, CodingKey {
        case format, items
    }

    private struct Lossy: Decodable {
        var item: WhatsNewItem?

        init(from decoder: Decoder) throws {
            item = try? WhatsNewItem(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .format) == Self.format else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: container, debugDescription: "A newer format")
        }
        items = try container.decode([Lossy].self, forKey: .items).compactMap(\.item)
    }
}
