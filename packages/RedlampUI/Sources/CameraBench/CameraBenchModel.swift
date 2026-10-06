import CoreGraphics
import Foundation
import Observation
import RedlampEngineAPI
import RedlampRecipes

/// The Camera Bench window's state (CAM-15): reads the chosen photos, picks a few per camera mode,
/// tests them on this Mac, and builds the report it would send, measurements only.
@MainActor @Observable
public final class CameraBenchModel {
    public enum Phase: Equatable {
        case start
        case reading(done: Int, total: Int)
        case testing(done: Int, total: Int)
        case results
    }

    public enum Sending: Equatable {
        case idle, sending
        case sent(id: String, dryRun: Bool)
        case failed(String)
    }

    public struct Photo: Identifiable {
        public var id: URL
        public var result: CameraBenchPhoto
        public var ours: CGImage?
        public var theirs: CGImage?
    }

    public struct Mode: Identifiable {
        public var id: String {
            mode.key
        }

        public var mode: CameraMode
        /// Photos of this mode among those chosen.
        public var candidates: Int
        public var photos: [Photo]

        public var verdict: BenchVerdict {
            photos.map(\.result.verdict).max() ?? .skipped
        }

        /// Each check's worst result across the photos.
        public var checks: [BenchCheck] {
            var worst: [String: BenchCheck] = [:]
            var order: [String] = []
            for check in photos.flatMap(\.result.checks) {
                if worst[check.id] == nil {
                    order.append(check.id)
                }
                if check.verdict > worst[check.id]?.verdict ?? .skipped || worst[check.id] == nil {
                    worst[check.id] = check
                }
            }
            return order.compactMap { worst[$0] }
        }

        public var conditions: Set<BenchCondition> {
            Set(photos.flatMap(\.result.conditions))
        }
    }

    public private(set) var phase = Phase.start
    public private(set) var modes: [Mode] = []
    public var selectedMode: String?
    /// What's Sent: the report exactly as it would be sent.
    public var showsReport = false
    public var answers: [String: CameraBenchAnswer.Choice] = [:]
    public var notes: [String: String] = [:]
    public var credit: String {
        didSet { UserDefaults.standard.set(credit, forKey: "CameraBenchCredit") }
    }

    public private(set) var sending = Sending.idle
    public private(set) var summary: CameraBenchSummary?
    /// The folder the editor is showing, offered as a source.
    public let currentFolder: () -> URL?

    private let makeBench: () throws -> CameraBench
    private let relay: any CameraBenchSending
    private var bench: CameraBench?
    private var work: Task<Void, Never>?
    private let version: (redlamp: String, commit: String?)

    public init(
        makeBench: @escaping () throws -> CameraBench, relay: any CameraBenchSending,
        currentFolder: @escaping () -> URL?,
        version: (redlamp: String, commit: String?),
    ) {
        self.makeBench = makeBench
        self.relay = relay
        self.currentFolder = currentFolder
        self.version = version
        credit = UserDefaults.standard.string(forKey: "CameraBenchCredit") ?? ""
        Task { [weak self, relay] in
            let summary = await relay.summary()
            self?.summary = summary
        }
    }

    // MARK: - Testing

    /// Tests raws in `urls` (files, or folders searched for raws): up to `perMode` per camera mode.
    public func test(_ urls: [URL], perMode: Int = 8) {
        work?.cancel()
        modes = []
        answers = [:]
        notes = [:]
        sending = .idle
        phase = .reading(done: 0, total: 0)
        work = Task { [weak self] in
            await self?.run(urls, perMode: perMode)
        }
    }

    public func cancel() {
        work?.cancel()
        phase = modes.isEmpty ? .start : .results
    }

    private func run(_ urls: [URL], perMode: Int) async {
        let files = await Task.detached(priority: .userInitiated) { Self.raws(in: urls) }.value
        guard !Task.isCancelled else { return }
        let bench: CameraBench
        do {
            bench = try self.bench ?? makeBench()
            self.bench = bench
        } catch {
            sending = .failed("The bench couldn't start: \(error.localizedDescription)")
            phase = .start
            return
        }
        var candidates: [CameraBenchSelection.Candidate] = []
        for (index, url) in files.enumerated() {
            guard !Task.isCancelled else { return }
            if let identity = await Task.detached(priority: .userInitiated, operation: { bench.engine.identify(url) })
                .value {
                candidates.append(CameraBenchSelection.Candidate(url: url, identity: identity))
            }
            phase = .reading(done: index + 1, total: files.count)
        }
        let groups = CameraBenchSelection.choose(candidates, perMode: perMode, needs: summary?.needs ?? [:])
        modes = groups.map { Mode(mode: $0.mode, candidates: $0.candidates, photos: []) }
        selectedMode = modes.first?.id
        let chosen = groups.flatMap { group in group.chosen.map { (group.mode.key, $0) } }
        phase = .testing(done: 0, total: chosen.count)
        for (index, (key, url)) in chosen.enumerated() {
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { await bench.run(url) }.value
            if let result, let position = modes.firstIndex(where: { $0.id == key }) {
                modes[position].photos.append(Photo(
                    id: url,
                    result: result.photo,
                    ours: result.ours,
                    theirs: result.theirs,
                ))
            }
            phase = .testing(done: index + 1, total: chosen.count)
        }
        phase = .results
    }

    nonisolated static func raws(in urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue else { return SupportedFormats.isRaw(url) ? [url] : [] }
            let found = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            )?.compactMap { $0 as? URL } ?? []
            return found.filter(SupportedFormats.isRaw).sorted { $0.path < $1.path }
        }
    }

    // MARK: - What it found

    public var selected: Mode? {
        modes.first { $0.id == selectedMode } ?? modes.first
    }

    /// The checklist's conditions this mode's evidence still lacks: from redlamp.app when it's
    /// known, less what these photos cover.
    public func stillNeeded(_ mode: Mode) -> [BenchCondition] {
        let wanted = summary?.mode(mode.id).map { Set($0.needs.compactMap(BenchCondition.init(rawValue:))) }
            ?? Set(BenchCondition.allCases)
        return BenchCondition.allCases.filter { wanted.contains($0) && !mode.conditions.contains($0) }
    }

    /// Whether the decode tests already have a CC0 sample of this camera, when redlamp.app says.
    public func isVerified(_ mode: Mode) -> Bool {
        summary?.mode(mode.id)?.verified ?? false
    }

    // MARK: - Sending

    /// Exactly what Send sends.
    public var report: CameraBenchReport {
        let environment = bench?.environment(redlamp: version.redlamp, commit: version.commit)
            ?? CameraBenchEnvironment(
                redlamp: version.redlamp, commit: version.commit, decoder: "",
                processVersion: EditRecipe.currentProcessVersion,
                bench: CameraBench.version, system: "",
            )
        let trimmed = credit.trimmingCharacters(in: .whitespacesAndNewlines)
        return CameraBenchReport(
            environment: environment,
            photos: modes.flatMap { $0.photos.map(\.result) },
            answers: modes.compactMap { mode in
                answers[mode.id].map { choice in
                    let note = notes[mode.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return CameraBenchAnswer(
                        mode: mode.id,
                        choice: choice,
                        note: note?.isEmpty == false ? String(note!.prefix(500)) : nil,
                    )
                }
            },
            contributor: CameraBenchContributor.id(),
            credit: trimmed.isEmpty ? nil : String(trimmed.prefix(80)),
        )
    }

    public var reportJSON: String {
        (try? Self.encoded(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    nonisolated static func encoded(_ report: CameraBenchReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    public var canSend: Bool {
        phase == .results && modes.contains { !$0.photos.isEmpty } && sending != .sending
    }

    public func send() {
        guard canSend else { return }
        sending = .sending
        let report = report
        Task { [weak self, relay] in
            do {
                let receipt = try await relay.send(Self.encoded(report))
                self?.sending = .sent(id: receipt.id, dryRun: receipt.dryRun)
            } catch {
                self?.sending = .failed(error.localizedDescription)
            }
        }
    }

    public func resetContributor() {
        CameraBenchContributor.reset()
    }

    // MARK: - Problems

    /// Opens Report a Bug or Send Feedback (UX-10), set by the app; without it, problems are
    /// reported as a filled-in GitHub issue.
    @ObservationIgnored public var onReportProblem: ((FeedbackPrefill) -> Void)?

    /// What the bench found wrong with a mode, in words, for a report; the photos stay on this Mac.
    public func problemSummary(_ mode: Mode) -> String? {
        let problems = mode.checks.filter { $0.verdict >= .warn }
        guard !problems.isEmpty else { return nil }
        let environment = report.environment
        let lines = problems.map { check in
            "- \(CameraBenchView.title(check.id)) (\(check.verdict.rawValue)): \(check.summary)"
                + (check.tracker.map { " (\($0))" } ?? "")
        }
        let photos = mode.photos.count == 1 ? "1 photo" : "\(mode.photos.count) photos"
        return """
        The camera bench found this with \(photos) from my camera, \(mode.mode.camera), \(mode.mode.label):
        \(lines.joined(separator: "\n"))
        Redlamp \(environment.redlamp), \(environment.decoder), process \(environment.processVersion), \
        bench \(environment.bench).
        """
    }

    /// The feedback report for a mode's problems, in the Photos & Cameras feature they concern.
    public func problemReport(_ mode: Mode) -> FeedbackPrefill? {
        guard let summary = problemSummary(mode) else { return nil }
        let worst = mode.checks.filter { $0.verdict >= .warn }.max { $0.verdict < $1.verdict }?.id ?? ""
        let feature = switch worst {
        case "decode.opens": mode.checks.contains { $0.tracker != nil } ? "raw.unsupported" : "raw.wont-open"
        case "decode.colour", "preview.cast", "preview.colour": "raw.colours"
        case "decode.white", "preview.highlights": "raw.highlights"
        case "preview.structure": "raw.demosaic"
        default: "raw.unsupported"
        }
        return FeedbackPrefill(kind: .bug, featureID: feature, message: summary)
    }

    /// A new GitHub issue about a mode's problems, filled in for the person to read and send.
    public func problemURL(_ mode: Mode) -> URL? {
        guard let summary = problemSummary(mode) else { return nil }
        var components = URLComponents(string: "https://github.com/pdcgomes/redlamp/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "Camera bench: \(mode.mode.camera), \(mode.mode.label)"),
            URLQueryItem(name: "body", value: summary),
        ]
        return components.url
    }
}
