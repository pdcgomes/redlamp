import Foundation

/// One agent-studio run on disk, shared by the orchestrator (which writes most of it), the
/// MCP server (which saves candidates) and the Recipe Lab (which shows it and records
/// human verdicts). Layout, under `build/recipe-runs/<run-id>/`:
///
/// - `run.json`: `RecipeRun.Info`
/// - `briefs/<id>.json`: style briefs
/// - `candidates/<id>.redrecipe` and `candidates/<id>.json` (metadata and lineage)
/// - `renders/`: contact sheets and comparisons
/// - `critiques.jsonl`, `comparisons.jsonl`, `scores.jsonl`: the agents' work
/// - `shortlist.json`: the Selector's picks per brief
/// - `verdicts.jsonl`: human approvals, pairwise picks and final picks (append-only)
/// - `transcripts/`: every model call, for reproducibility
///
/// See docs/recipes/agent-studio.md.
public enum RecipeRun {
    public struct Info: Codable, Sendable, Hashable {
        public var id: String
        public var created: Date?
        public var seed: UInt64?
        public var model: String?
        public var rubricVersion: String?
        public var status: String?
        public var budget: [String: Int]?
        public var notes: String?

        public init(
            id: String,
            created: Date? = Date(),
            seed: UInt64? = nil,
            model: String? = nil,
            status: String? = "running",
        ) {
            self.id = id
            self.created = created
            self.seed = seed
            self.model = model
            self.status = status
        }
    }

    public enum BriefStatus: String, Codable, Sendable {
        case proposed, approved, rejected
    }

    public struct Brief: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var description: String
        /// What the look must do to skin, sky and foliage.
        public var requirements: [String]?
        public var references: [String]
        public var targetFingerprint: StyleFingerprint?
        public var status: BriefStatus
        public var createdBy: String?

        public init(
            id: String, title: String, description: String, requirements: [String]? = nil, references: [String] = [],
            targetFingerprint: StyleFingerprint? = nil, status: BriefStatus = .proposed, createdBy: String? = nil,
        ) {
            self.id = id
            self.title = title
            self.description = description
            self.requirements = requirements
            self.references = references
            self.targetFingerprint = targetFingerprint
            self.status = status
            self.createdBy = createdBy
        }
    }

    public struct Candidate: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var brief: String?
        public var parent: String?
        public var iteration: Int
        /// `fit`, `colorist`, `mutation` or `human`.
        public var origin: String
        public var notes: String?
        public var lint: String?
        public var fingerprintDistance: Double?
        public var rating: Double?
        /// Relative to the run directory.
        public var render: String?
        public var created: Date?

        public init(
            id: String, brief: String? = nil, parent: String? = nil, iteration: Int = 0, origin: String = "colorist",
            notes: String? = nil, lint: String? = nil, fingerprintDistance: Double? = nil, rating: Double? = nil,
            render: String? = nil, created: Date? = Date(),
        ) {
            self.id = id
            self.brief = brief
            self.parent = parent
            self.iteration = iteration
            self.origin = origin
            self.notes = notes
            self.lint = lint
            self.fingerprintDistance = fingerprintDistance
            self.rating = rating
            self.render = render
            self.created = created
        }
    }

    public struct Critique: Codable, Sendable, Hashable {
        public var candidate: String
        public var critic: String
        public var rubricVersion: String?
        public var scores: [String: Double]
        public var notes: String?
        public var changeRequests: [String]?
    }

    public struct Comparison: Codable, Sendable, Hashable {
        public var a: String
        public var b: String
        public var winner: String?
        public var critic: String
        public var swapped: Bool?
        public var brief: String?
    }

    public struct Score: Codable, Sendable, Hashable {
        public var iteration: Int
        public var candidate: String
        public var rating: Double
        public var brief: String?
    }

    public struct Shortlist: Codable, Sendable, Hashable {
        public var brief: String
        public var candidates: [String]
    }

    public struct Verdict: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            /// A brief approved or rejected (`approved`).
            case brief
            /// A human pick between `a` and `b`; `winner` nil for a tie.
            case pairwise
            /// A shortlisted candidate chosen (`approved` true) or turned down.
            case final
        }

        public var type: Kind
        public var brief: String?
        public var a: String?
        public var b: String?
        public var winner: String?
        public var candidate: String?
        public var approved: Bool?
        public var rater: String
        public var note: String?
        public var at: Date

        public static func brief(_ id: String, approved: Bool, rater: String, note: String? = nil) -> Verdict {
            Verdict(type: .brief, brief: id, approved: approved, rater: rater, note: note, at: Date())
        }

        public static func pairwise(
            _ a: String,
            _ b: String,
            winner: String?,
            brief: String?,
            rater: String,
        ) -> Verdict {
            Verdict(type: .pairwise, brief: brief, a: a, b: b, winner: winner, rater: rater, at: Date())
        }

        public static func final(
            _ candidate: String,
            approved: Bool,
            brief: String?,
            rater: String,
            note: String? = nil,
        ) -> Verdict {
            Verdict(
                type: .final,
                brief: brief,
                candidate: candidate,
                approved: approved,
                rater: rater,
                note: note,
                at: Date(),
            )
        }
    }
}

/// Reads and writes one run directory.
public struct RunStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func runsDirectory(root: URL) -> URL {
        root.appendingPathComponent("build/recipe-runs", isDirectory: true)
    }

    public static func all(root: URL) -> [RunStore] {
        let folder = runsDirectory(root: root)
        let runs = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
        )) ?? []
        // Folders starting with "_" hold studio bookkeeping (evals), not runs.
        return runs
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent
                    .hasPrefix("_")
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(RunStore.init)
    }

    public static func named(_ id: String, root: URL) -> RunStore {
        RunStore(directory: runsDirectory(root: root).appendingPathComponent(id, isDirectory: true))
    }

    public var id: String {
        directory.lastPathComponent
    }

    private func url(_ path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func prepare() throws {
        for folder in ["briefs", "candidates", "renders", "transcripts"] {
            try FileManager.default.createDirectory(at: url(folder), withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: url("run.json").path) {
            try write(RecipeRun.Info(id: id), to: "run.json")
        }
    }

    public var info: RecipeRun.Info? {
        read("run.json")
    }

    public func briefs() -> [RecipeRun.Brief] {
        files(in: "briefs", extension: "json").compactMap { read("briefs/\($0)") }.sorted { $0.id < $1.id }
    }

    public func save(_ brief: RecipeRun.Brief) throws {
        try prepare()
        try write(brief, to: "briefs/\(brief.id).json")
    }

    public func candidates() -> [RecipeRun.Candidate] {
        files(in: "candidates", extension: "json").compactMap { read("candidates/\($0)") }
            .sorted { ($0.iteration, $0.id) < ($1.iteration, $1.id) }
    }

    public func recipe(for candidate: String) -> Recipe? {
        try? RecipeFile.read(url("candidates/\(candidate).\(Recipe.fileExtension)")).recipe
    }

    public func recipeURL(for candidate: String) -> URL {
        url("candidates/\(candidate).\(Recipe.fileExtension)")
    }

    public func renderURL(_ name: String) -> URL {
        url("renders/\(name)")
    }

    /// Saves a candidate recipe and its metadata. The candidate id doubles as the recipe
    /// file name; a recipe without a local id gets one.
    @discardableResult
    public func save(_ recipe: Recipe, as candidate: RecipeRun.Candidate) throws -> RecipeRun.Candidate {
        try prepare()
        try RecipeFile.write(recipe, to: recipeURL(for: candidate.id))
        try write(candidate, to: "candidates/\(candidate.id).json")
        return candidate
    }

    public func critiques() -> [RecipeRun.Critique] {
        lines("critiques.jsonl")
    }

    public func scores() -> [RecipeRun.Score] {
        lines("scores.jsonl")
    }

    public func shortlist() -> [RecipeRun.Shortlist] {
        read("shortlist.json") ?? []
    }

    public func verdicts() -> [RecipeRun.Verdict] {
        lines("verdicts.jsonl")
    }

    /// The latest human decision on each brief.
    public func briefStatus(_ brief: RecipeRun.Brief) -> RecipeRun.BriefStatus {
        guard let latest = verdicts().last(where: { $0.type == .brief && $0.brief == brief.id })
        else { return brief.status }
        return latest.approved == true ? .approved : .rejected
    }

    public func append(_ verdict: RecipeRun.Verdict) throws {
        try append(verdict, to: "verdicts.jsonl")
    }

    public func append(_ value: some Encodable, to file: String) throws {
        try prepare()
        var data = try Self.encoder.encode(value)
        data.append(0x0A)
        let target = url(file)
        if let handle = try? FileHandle(forWritingTo: target) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: target, options: .atomic)
        }
    }

    /// The newest modification time of anything in the run, for watching it change.
    public var lastModified: Date {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
        )
        var newest = Date.distantPast
        while let file = enumerator?.nextObject() as? URL {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date > newest {
                newest = date
            }
        }
        return newest
    }

    // MARK: - Files

    private func files(in folder: String, extension ext: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? [])
            .filter { $0.hasSuffix("." + ext) }
    }

    private func read<T: Decodable>(_ path: String) -> T? {
        guard let data = try? Data(contentsOf: url(path)) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    private func write(_ value: some Encodable, to path: String) throws {
        try Self.encoder.encode(value).write(to: url(path), options: .atomic)
    }

    private func lines<T: Decodable>(_ path: String) -> [T] {
        guard let text = try? String(contentsOf: url(path), encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .compactMap { try? Self.decoder.decode(T.self, from: Data($0.utf8)) }
    }
}
