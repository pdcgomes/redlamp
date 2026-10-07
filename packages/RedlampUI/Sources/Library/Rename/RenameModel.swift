import Foundation
import RedlampDocument
import RedlampLibrary

/// What Rename Photos shows (LIB-25): the selection's photos, with their raw and JPEG pairs, named by the
/// template as it's typed. The photos are read once, off the main thread, and their original names when a
/// template first asks for them; each change of the template, its options or its texts is named off the main
/// thread too, one at a time, the latest waiting for the one under way and those between skipped, so the main
/// thread only takes the names. A template's error is said in words, and the last template that reads stays
/// named.
@MainActor
final class RenameModel {
    enum Phase: Equatable {
        case reading
        case ready
        /// Renaming, these steps of the batch done.
        case renaming(done: Int, total: Int)
        /// The photos couldn't be read, or the rename didn't happen: why.
        case failed(String)
    }

    enum Change {
        case names, phase, template
    }

    /// What a batch of names was made with.
    struct Request: Equatable, Sendable {
        var template: NamingTemplate
        var options: NamingOptions
        var texts: [String: String]
        var counters: NamingCounters
    }

    /// How many photos were asked for, before their pairs.
    let photos: Int
    let presets: NamingPresetStore
    var onChange: ((Change) -> Void)?
    private(set) var phase = Phase.reading
    private(set) var job: RenameJob?
    private(set) var text: String
    private(set) var template: NamingTemplate?
    private(set) var error: String?
    private(set) var options: NamingOptions
    private(set) var texts: [String: String] = [:]
    /// The names of the latest template that reads, and what they were named with.
    private(set) var batch: NamingBatch?
    private(set) var named: Request?
    private let context = NamingContext(date: Date())
    private let read: @Sendable () async throws -> RenameJob
    private let sidecars: SidecarPlacement
    private var naming = false
    private var waiting: Request?
    private var following: [CheckedContinuation<Void, Never>] = []

    /// `read` reads the photos off the main thread; their original names come through `sidecars`.
    init(
        photos: Int, presets: NamingPresetStore, sidecars: SidecarPlacement,
        read: @escaping @Sendable () async throws -> RenameJob,
    ) {
        self.photos = photos
        self.presets = presets
        self.sidecars = sidecars
        self.read = read
        let last = presets.lastRename ?? NamingPreset.lightroom[0]
        text = last.template.description
        template = last.template
        options = last.options
    }

    /// Reads the photos, then names them.
    func start() async {
        do {
            job = try await read()
            setPhase(.ready)
        } catch {
            setPhase(.failed("The photos couldn't be read: \(String(describing: error))"))
        }
    }

    // MARK: - Editing

    /// The template as it's typed: a token still open at the end is left out, so the names follow the typing.
    func setText(_ text: String) {
        self.text = text
        do {
            template = try NamingTemplate(parsing: text, asYouType: true)
            error = nil
        } catch {
            self.error = error.message
        }
        onChange?(.template)
        requestNames()
    }

    /// A preset chosen: its template, with its options when it keeps them.
    func choose(_ text: String, options: NamingOptions?) {
        if let options {
            self.options = options
        }
        setText(text)
    }

    func setOptions(_ options: NamingOptions) {
        guard options != self.options else { return }
        self.options = options
        requestNames()
    }

    /// `{text}` and `{text:shoot}`, by their names ("" and "shoot").
    func setText(_ name: String, _ value: String) {
        texts[name] = value.isEmpty ? nil : value
        requestNames()
    }

    /// The texts the template asks for, in the order it asks.
    var textNames: [String] {
        template?.textNames ?? []
    }

    // MARK: - Naming

    /// Names the photos with the template as it stands, once the naming under way is done.
    private func requestNames() {
        guard let template, job != nil, phase == .ready else { return }
        let request = Request(template: template, options: options, texts: texts, counters: presets.counters)
        guard naming || request != named else { return }
        guard !naming else {
            waiting = request
            return
        }
        naming = true
        Task { await self.makeNames(request) }
    }

    private func makeNames(_ request: Request) async {
        if let current = job, !current.hasOriginals, RenameJob.needsOriginals(request.template) {
            let sidecars = sidecars
            job = await Task.detached(priority: .userInitiated) { current.withOriginals(sidecars) }.value
        }
        let (job, context) = (job, context)
        let batch = await Task.detached(priority: .userInitiated) { () -> NamingBatch? in
            var context = context
            context.texts = request.texts
            return job?.names(request.template, options: request.options, context: context, counters: request.counters)
        }.value
        if let batch {
            let replaced = self.batch
            self.batch = batch
            named = request
            // Ten thousand names take milliseconds to free: the names replaced go off the main thread.
            Task.detached(priority: .utility) { withExtendedLifetime(replaced) {} }
            onChange?(.names)
        }
        if let next = waiting {
            waiting = nil
            if next != named {
                return await makeNames(next)
            }
        }
        naming = false
        let followers = following
        following = []
        followers.forEach { $0.resume() }
    }

    /// Returns once the names follow the template as it stands.
    func namesFollow() async {
        guard naming else { return }
        await withCheckedContinuation { following.append($0) }
    }

    /// The names are the template's as it stands.
    var isCurrent: Bool {
        guard let template, let named, !naming else { return false }
        return named.template == template && named.options == options && named.texts == texts
    }

    /// Photos the names change.
    var renamed: Int {
        guard let batch else { return 0 }
        return batch.results.count - batch.unchanged
    }

    /// One line: how many photos, renamed, unchanged and numbered, and the tokens that came out empty.
    var summary: String {
        guard let batch, let job, let named else {
            return phase == .reading ? "Reading \(Self.count(photos)) photo\(photos == 1 ? "" : "s")…" : ""
        }
        var line = "\(Self.count(job.ids.count)) photo\(job.ids.count == 1 ? "" : "s"): "
            + "\(Self.count(renamed)) renamed, \(Self.count(batch.unchanged)) unchanged"
        if batch.collisions > 0 {
            line += ", \(Self.count(batch.collisions)) numbered to tell them apart"
        }
        let empty = zip(named.template.tokens, batch.emptyCounts).filter { $0.1 > 0 }
        if !empty.isEmpty {
            line += "; empty: " + empty.map { "\($0.0) for \(Self.count($0.1))" }.joined(separator: ", ")
        }
        return line
    }

    /// The notes beside a photo's new name: unchanged, numbered and who has the name, empty tokens, and what
    /// was done to make the name safe; a warning for those numbered or with empty tokens.
    func notes(_ row: Int) -> (text: String, isWarning: Bool) {
        guard let batch, let job, let named, batch.results.indices.contains(row) else { return ("", false) }
        let result = batch.results[row]
        var notes: [String] = []
        if result.isUnchanged {
            notes.append("unchanged")
        }
        if let collision = result.collision {
            switch collision.holder {
            case let .photo(index):
                notes.append("numbered: \((job.paths[index] as NSString).lastPathComponent) has the name")
            case let .file(name):
                notes.append("numbered: \(name) is in the folder")
            }
        }
        let tokens = named.template.tokens
        if !result.emptyTokens.isEmpty {
            notes.append("empty: " + result.emptyTokens.filter(tokens.indices.contains)
                .map { tokens[$0].description }.joined(separator: ", "))
        }
        let adjustments: [(NamingAdjustments, String)] = [
            (.replaced, "characters replaced"), (.trimmed, "trimmed"), (.shortened, "shortened"),
            (.reserved, "a device name, given an ending"), (.keptName, "nothing made, so it keeps its name"),
        ]
        notes += adjustments.compactMap { result.adjustments.contains($0.0) ? $0.1 : nil }
        return (notes.joined(separator: "; "), !result.emptyTokens.isEmpty || result.collision != nil)
    }

    // MARK: - Renaming

    func setPhase(_ phase: Phase) {
        guard phase != self.phase else { return }
        self.phase = phase
        onChange?(.phase)
        if phase == .ready {
            requestNames()
        }
    }

    /// The renames the names make, once they follow the template as it stands; empty while it doesn't read.
    func renames() async -> (renames: [PhotoRename], batch: NamingBatch)? {
        await namesFollow()
        guard error == nil, isCurrent, let job, let batch else { return nil }
        return (job.renames(batch), batch)
    }

    /// The template and its options are kept for the next Rename Photos, and the counters moved on.
    func renamed(_ batch: NamingBatch) {
        if let template {
            presets.setLastRename(template, options: options)
        }
        presets.setCounters(batch.counters)
    }

    /// `20,000`, whatever the locale.
    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
