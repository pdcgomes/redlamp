import Foundation
import RedlampEngineAPI

/// A bench folder's manifest, `task.json`: a step an agent needs the owner to do in another app
/// (a Lightroom check), or a look reference made on the phone. See docs/bench-tasks.md.
///
/// Fields a newer Redlamp writes are kept in `unknownFields`, so a round trip never erases them.
public struct BenchManifest: Sendable, Hashable {
    public static let fileName = "task.json"
    public static let format = "redlamp-bench"
    public static let formatVersion = 1

    public enum Kind {
        public static let lightroomCheck = "lightroom-check"
        /// A look being replicated: the capture kit run through another app's filter.
        public static let lookReference = "look-reference"
        /// The capture kit, served by the hub as the source of new look references.
        public static let lookKit = "look-kit"
    }

    /// Who asked, so the owner knows what a task is for.
    public struct Requester: Codable, Sendable, Hashable {
        public var workstream: String?
        /// A tracker row, such as `DEC-08`.
        public var tracker: String?
        public var issue: Int?

        public init(workstream: String? = nil, tracker: String? = nil, issue: Int? = nil) {
            self.workstream = workstream
            self.tracker = tracker
            self.issue = issue
        }
    }

    public struct Step: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        /// Short: it heads the step's screen.
        public var title: String
        /// A sentence or two, with exact menu names and values.
        public var detail: String?
        /// A reference picture inside the folder, such as a screenshot of the setting to find.
        public var picture: String?
        public var action: Action?

        public init(id: String, title: String, detail: String? = nil, picture: String? = nil, action: Action? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
            self.picture = picture
            self.action = action
        }
    }

    /// What a step's screen offers. `assets` nil means every asset.
    public enum Action: Sendable, Hashable {
        /// Share the assets' original files to another app.
        case share(assets: [String]?)
        /// Save the assets to Photos, for apps that only read the library.
        case save(assets: [String]?)
        case answer(question: String)
        /// Wait until the assets have results; the step ticks itself when they do.
        case results(assets: [String]?)
    }

    public struct Asset: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        /// Relative to the folder, under `assets/`.
        public var file: String
        public var label: String?
        public var sha256: String
        public var bytes: Int
        /// The number a capture-kit chart's barcode carries (1–3 for the full charts, 9 for the
        /// one-image kit), so a filtered export pairs with its chart.
        public var chart: Int?
        /// The one-image kit's photo tiles, in order: what each shows.
        public var tiles: [String]?
        /// Whether the task is complete only once this asset has a result.
        public var counts: Bool

        public init(
            id: String,
            file: String,
            label: String? = nil,
            sha256: String,
            bytes: Int,
            chart: Int? = nil,
            tiles: [String]? = nil,
            counts: Bool = true,
        ) {
            self.id = id
            self.file = file
            self.label = label
            self.sha256 = sha256
            self.bytes = bytes
            self.chart = chart
            self.tiles = tiles
            self.counts = counts
        }

        enum CodingKeys: String, CodingKey {
            case id, file, label, sha256, bytes, chart, tiles, counts
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            file = try container.decode(String.self, forKey: .file)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            sha256 = try container.decode(String.self, forKey: .sha256)
            bytes = try container.decode(Int.self, forKey: .bytes)
            chart = try container.decodeIfPresent(Int.self, forKey: .chart)
            tiles = try container.decodeIfPresent([String].self, forKey: .tiles)
            counts = try container.decodeIfPresent(Bool.self, forKey: .counts) ?? true
        }
    }

    public enum Pairing: String, Codable, Sendable, Hashable, CaseIterable {
        /// The result's file name, less the suffixes apps add, is the asset's.
        case fileName = "file-name"
        /// The result looks most like the asset, by a clear margin.
        case similarity
        /// The result is a capture-kit chart whose barcode names the asset's `chart`.
        case captureChart = "capture-chart"
        /// The owner paired it.
        case hand
    }

    public enum Completion: Sendable, Hashable {
        /// Every asset that `counts` has a result.
        case everyAsset
        case assets([String])
        /// The owner says when it's done.
        case manual
    }

    public struct Question: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var text: String
        public var choices: [String]
        public var required: Bool

        public init(id: String, text: String, choices: [String], required: Bool = true) {
            self.id = id
            self.text = text
            self.choices = choices
            self.required = required
        }
    }

    /// Which look a look reference replicates. Private provenance: never part of a recipe's name
    /// (DEC-19).
    public struct LookReference: Codable, Sendable, Hashable {
        public enum KitSet: String, Codable, Sendable, Hashable, CaseIterable {
            /// The one-image kit.
            case quick
            /// The three charts and two photos.
            case standard
            /// The three charts and all eight photos.
            case full
        }

        public var app: String
        public var filter: String
        public var variant: String?
        /// Free notes: slider values, strength, anything set away from the defaults.
        public var settings: String?
        /// A screenshot of the filter's settings, inside the folder.
        public var settingsScreenshot: String?
        public var kitSet: KitSet

        public init(
            app: String,
            filter: String,
            variant: String? = nil,
            settings: String? = nil,
            settingsScreenshot: String? = nil,
            kitSet: KitSet,
        ) {
            self.app = app
            self.filter = filter
            self.variant = variant
            self.settings = settings
            self.settingsScreenshot = settingsScreenshot
            self.kitSet = kitSet
        }

        /// "Prequel · Cine Film 2".
        public var title: String {
            let filter = [filter, variant].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
            return app.isEmpty ? filter : "\(app) · \(filter)"
        }
    }

    public var format: String
    public var version: Int
    public var id: String
    public var title: String
    public var kind: String
    public var created: Date
    /// Raised when an agent changes a task the phone may already have.
    public var revision: Int
    public var requestedBy: Requester?
    /// The app the steps happen in.
    public var app: String?
    public var steps: [Step]
    public var assets: [Asset]
    public var completion: Completion
    /// Tried in order for each result.
    public var pairing: [Pairing]
    public var questions: [Question]
    public var note: String?
    public var look: LookReference?
    /// An agent took the task back; the phone drops it unless it already has results.
    public var withdrawn: Bool
    public private(set) var unknownFields: [String: JSONValue] = [:]

    public init(
        id: String,
        title: String,
        kind: String,
        created: Date = Date(),
        revision: Int = 1,
        requestedBy: Requester? = nil,
        app: String? = nil,
        steps: [Step] = [],
        assets: [Asset] = [],
        completion: Completion = .everyAsset,
        pairing: [Pairing] = [.fileName, .similarity],
        questions: [Question] = [],
        note: String? = nil,
        look: LookReference? = nil,
        withdrawn: Bool = false,
    ) {
        format = Self.format
        version = Self.formatVersion
        self.id = id
        self.title = title
        self.kind = kind
        self.created = created
        self.revision = revision
        self.requestedBy = requestedBy
        self.app = app
        self.steps = steps
        self.assets = assets
        self.completion = completion
        self.pairing = pairing
        self.questions = questions
        self.note = note
        self.look = look
        self.withdrawn = withdrawn
    }

    public func asset(_ id: String) -> Asset? {
        assets.first { $0.id == id }
    }

    /// The assets that must have a result before the task is complete; empty when the owner
    /// decides.
    public var requiredAssets: [String] {
        switch completion {
        case .everyAsset: assets.filter(\.counts).map(\.id)
        case let .assets(ids): ids
        case .manual: []
        }
    }

    /// Lowercase letters, digits, `-`, `_` and `.`, at most 100 characters, not starting with `.`;
    /// the ID is the folder's name.
    public static func isValidID(_ id: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        return !id.isEmpty && id.count <= 100 && id.first != "." && id.allSatisfy(allowed.contains)
    }

    /// A new ID from a title: `2026-10-08-mask-intersect-3f2a`.
    public static func newID(title: String, date: Date = Date()) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let words = String(title.lowercased().map { allowed.contains($0) ? $0 : " " })
            .split(separator: " ").prefix(6).joined(separator: "-")
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        let suffix = UUID().uuidString.lowercased().prefix(4)
        return [day, words.isEmpty ? nil : words, String(suffix)].compactMap(\.self).joined(separator: "-")
    }
}

// MARK: - Coding

extension BenchManifest: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case format, version, id, title, kind, created, revision, requestedBy, app, steps, assets
        case completion, pairing, questions, note, look, withdrawn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(String.self, forKey: .kind)
        created = try container.decode(Date.self, forKey: .created)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        requestedBy = try container.decodeIfPresent(Requester.self, forKey: .requestedBy)
        app = try container.decodeIfPresent(String.self, forKey: .app)
        steps = try container.decodeIfPresent([Step].self, forKey: .steps) ?? []
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        completion = try container.decodeIfPresent(Completion.self, forKey: .completion) ?? .everyAsset
        pairing = try container.decodeIfPresent([Pairing].self, forKey: .pairing) ?? [.fileName, .similarity]
        questions = try container.decodeIfPresent([Question].self, forKey: .questions) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        look = try container.decodeIfPresent(LookReference.self, forKey: .look)
        withdrawn = try container.decodeIfPresent(Bool.self, forKey: .withdrawn) ?? false
        if case let .object(all) = try JSONValue(from: decoder) {
            let known = Set(CodingKeys.allCases.map(\.rawValue))
            unknownFields = all.filter { !known.contains($0.key) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(created, forKey: .created)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(requestedBy, forKey: .requestedBy)
        try container.encodeIfPresent(app, forKey: .app)
        try container.encode(steps, forKey: .steps)
        try container.encode(assets, forKey: .assets)
        try container.encode(completion, forKey: .completion)
        try container.encode(pairing, forKey: .pairing)
        if !questions.isEmpty {
            try container.encode(questions, forKey: .questions)
        }
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(look, forKey: .look)
        if withdrawn {
            try container.encode(withdrawn, forKey: .withdrawn)
        }
        var extra = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in unknownFields {
            try extra.encode(value, forKey: AnyKey(key))
        }
    }
}

extension BenchManifest.Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, assets, question
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let assets = try container.decodeIfPresent([String].self, forKey: .assets)
        switch try container.decode(String.self, forKey: .type) {
        case "share": self = .share(assets: assets)
        case "save": self = .save(assets: assets)
        case "answer": self = try .answer(question: container.decode(String.self, forKey: .question))
        case "results": self = .results(assets: assets)
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown step action \(type)",
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .share(assets):
            try container.encode("share", forKey: .type)
            try container.encodeIfPresent(assets, forKey: .assets)
        case let .save(assets):
            try container.encode("save", forKey: .type)
            try container.encodeIfPresent(assets, forKey: .assets)
        case let .answer(question):
            try container.encode("answer", forKey: .type)
            try container.encode(question, forKey: .question)
        case let .results(assets):
            try container.encode("results", forKey: .type)
            try container.encodeIfPresent(assets, forKey: .assets)
        }
    }

    /// The assets the action names; nil means every asset.
    public var assets: [String]? {
        switch self {
        case let .share(assets), let .save(assets), let .results(assets): assets
        case .answer: nil
        }
    }
}

extension BenchManifest.Completion: Codable {
    private enum CodingKeys: String, CodingKey {
        case rule, assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .rule) {
        case "every-asset": self = .everyAsset
        case "assets": self = try .assets(container.decode([String].self, forKey: .assets))
        case "manual": self = .manual
        case let rule:
            throw DecodingError.dataCorruptedError(
                forKey: .rule, in: container, debugDescription: "unknown completion rule \(rule)",
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .everyAsset:
            try container.encode("every-asset", forKey: .rule)
        case let .assets(ids):
            try container.encode("assets", forKey: .rule)
            try container.encode(ids, forKey: .assets)
        case .manual:
            try container.encode("manual", forKey: .rule)
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? {
        nil
    }

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

public extension JSONEncoder {
    /// Bench files: sorted keys and ISO dates, so diffs and hashes are stable.
    static var bench: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var bench: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
