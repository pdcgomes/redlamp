import Foundation
import Observation
import RedlampDocument
import RedlampEngineAPI

/// The editor, to Settings Sync: a photo open in it is changed there, as a step of its history,
/// never by writing its sidecar behind it.
@MainActor
protocol SyncEditor: AnyObject {
    /// Whether `url` is open in the editor, or opening there.
    func isOpen(_ url: URL) -> Bool
    /// `change` made to `url` in the editor as a step titled `title`, once it has opened.
    func apply(_ change: SettingsSync.EditorChange, to url: URL, title: String) async -> SettingsSync.EditorOutcome
}

/// Changes photos that aren't open, one at a time in the background: Sync Settings, Paste onto a
/// selection, Update AI Masks across it (`docs/plans/2026-10-02-copy-paste-sync-design.md`).
///
/// For each photo it reads the sidecar, pastes, recomputes the AI masks the paste brought (and an
/// Auto white balance) in an engine of its own, so the open photo is never disturbed, and saves
/// with a history step. A photo whose sidecar a newer Redlamp wrote, or this version can't read,
/// is left alone, and so is one edited between the read and the save. The photo open in the
/// editor, or opening there, when the batch reaches it or is about to save it, is changed by the
/// editor instead (`SyncEditor`). Batches run one after another. Undo puts back what the last
/// batch changed, on every photo not edited since.
///
/// While Auto Sync is on, the batches that follow the open photo's steps make a run (`AutoSyncRun`):
/// each photo keeps one history session for it, and Undo, Redo and history clicks on the open
/// photo give each photo back its edit at that step.
@MainActor
@Observable
public final class SettingsSync {
    public enum Change {
        /// `selection` of `source`, pasted.
        case paste(EditRecipe, SettingsSelection)
        /// Every AI mask computed again with today's models.
        case updateAIMasks
        /// Each photo's sensor dust (found across the selection) healed, a source found for each speck.
        case healDust([URL: [DetectedSpot]])
        /// Each photo of the run as the open photo's step left it: its edit before the run, with
        /// `source` (the open photo's edit at that step) pasted for what the run's steps carried
        /// to it, but for those undone (the open photo's steps after it).
        case follow(EditRecipe, Set<UUID>)
    }

    /// What a batch asks of the photo open in the editor.
    enum EditorChange {
        /// The batch's change, made to the editor's edit.
        case change(Change)
        /// `recipe` for the edit, if the editor's is still `over`: Undo, and following the open
        /// photo's history.
        case edit(EditRecipe, over: EditRecipe)
    }

    enum EditorOutcome {
        /// Made as a step of the photo's history; the edit it left (nil: nothing changed).
        case applied(EditRecipe?)
        /// Left as it is: edited since, or read-only.
        case left
        /// It isn't open in the editor (any more): the batch saves it.
        case notOpen
    }

    /// One of the open photo's steps reaching the rest of the selection while Auto Sync is on.
    struct RunStep {
        /// The open photo's history session.
        var session: UUID
        var id: UUID
        /// The step's title in the open photo's history ("Exposure").
        var title: String
        /// What it carries: an Auto Sync step's changes, or a paste's items and the masks it brought.
        var carried: SettingsSelection
    }

    /// The open photo's steps that reached the other photos while Auto Sync was on, and what each
    /// of those photos was before them, so following the open photo's history gives each its own
    /// edit back.
    private struct AutoSyncRun {
        var session: UUID
        /// What each step carried, by the step's id.
        var steps: [UUID: SettingsSelection] = [:]
        var photos: [URL: Member] = [:]

        struct Member {
            /// Its edit before the run first wrote it (nil: it had no sidecar).
            var base: EditRecipe?
            /// The steps written to it.
            var reached: Set<UUID>
            /// Its edit as the run last wrote it, read back: any other is an edit made since.
            var last: EditRecipe
            /// The run's history session in its sidecar.
            var session: HistorySession
        }

        /// What the steps that reached `member` carried to it, but for those `undone`.
        func carried(to member: Member, without undone: Set<UUID>) -> SettingsSelection {
            member.reached.subtracting(undone).compactMap { steps[$0] }.reduce(.nothing) { $0.union($1) }
        }
    }

    public struct Progress: Equatable, Sendable {
        public var title: String
        public var done: Int
        public var total: Int
    }

    public private(set) var progress: Progress?
    /// Auto Sync: each step on the open photo repeats on the rest of the selection.
    public var isAutoSyncing = false {
        didSet {
            if !isAutoSyncing {
                run = nil
            }
        }
    }

    /// How the last batch went, when there is something to say ("1 photo was left alone…").
    public private(set) var report: String?
    public var canUndo: Bool {
        !written.isEmpty && progress == nil
    }

    /// An engine for photos that aren't open; nil leaves AI masks and Auto white balance as pasted.
    @ObservationIgnored var makeEngine: () -> (any EditingEngine)?
    /// The exposure anchor a photo's edit gets under Redlamp Reproduction (nil when it isn't raw),
    /// set by the editor; without it, the typical anchor.
    @ObservationIgnored var photoAnchor: (@MainActor (URL) async -> ExposureAnchor?)?
    @ObservationIgnored let store: SidecarStore
    /// The editor's saves: a photo just left may still be on its way to disk. The batch's own
    /// saves go through their queue too, after those asked for before them.
    @ObservationIgnored var saves: SaveQueue?
    @ObservationIgnored weak var editor: (any SyncEditor)?
    /// Waited for before each photo's sidecar is written (tests change the photo here).
    @ObservationIgnored var beforeWriting: @MainActor (URL) async -> Void = { _ in }
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The batch's saves on their way, by photo: the editor reads a photo it opens after them.
    @ObservationIgnored private var writing: [URL: Task<Void, Never>] = [:]
    /// The last batch: each photo's edit before (nil: it had no sidecar) and after.
    @ObservationIgnored private var before: [URL: EditRecipe?] = [:]
    @ObservationIgnored private var written: [URL: Sidecar] = [:]
    @ObservationIgnored private var title = ""
    /// Batches that came while one ran, in order; Auto Sync's steps are gathered into one.
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var run: AutoSyncRun?
    /// A photo's history session for a run keeps this many steps at most, as the editor's does.
    static let maximumRunSteps = 500

    private struct Job {
        var change: Change
        var photos: [URL]
        var title: String
        /// The step's title in each photo's history.
        var stepTitle: String
        var isAutoSync = false
        /// The run the batch belongs to, and the open photo's steps it carries.
        var session: UUID?
        var steps: [UUID] = []
        var done: (URL, EditRecipe) -> Void

        var isFollow: Bool {
            if case .follow = change {
                true
            } else {
                false
            }
        }
    }

    /// How a batch's save of one photo went.
    private enum Saving: Sendable {
        /// As read back.
        case saved(Sidecar)
        case editedSince
        /// Protected, or it can't be read now.
        case unreadable
        case failed
    }

    /// How Undo's putting back of one photo went.
    private enum PuttingBack: Sendable {
        case done(EditRecipe)
        case editedSince
        case unreadable
    }

    /// Where a photo's change landed: saved by the batch, or made by the editor.
    private enum Landed<T> {
        case saved(T)
        case inEditor(EditorOutcome)
    }

    init(store: SidecarStore = SidecarStore(), makeEngine: @escaping () -> (any EditingEngine)?) {
        self.store = store
        self.makeEngine = makeEngine
    }

    /// Starts `change` on `photos`, recorded in each one's history as `title`, or queues it after
    /// the batch running; `done` is told of each photo changed. With `step` (a paste onto the
    /// selection) and Auto Sync on, the batch joins the run, so the open photo's Undo takes it
    /// back too.
    func run(
        _ change: Change, on photos: [URL], title: String, step: RunStep? = nil,
        done: @escaping (URL, EditRecipe) -> Void,
    ) {
        var job = Job(change: change, photos: photos, title: title, stepTitle: title, done: done)
        if let step, isAutoSyncing {
            record(step)
            job.session = step.session
            job.steps = [step.id]
        }
        enqueue(job)
    }

    public func cancel() {
        queue = []
        task?.cancel()
    }

    /// One Auto Sync step of `source`, onto `photos`; gathered with the steps queued just before it.
    func autoSync(_ source: EditRecipe, step: RunStep, on photos: [URL], done: @escaping (URL, EditRecipe) -> Void) {
        guard !step.carried.isEmpty, !photos.isEmpty else { return }
        record(step)
        let stepTitle = "Auto Sync: \(step.title)"
        if progress != nil, let last = queue.last, last.isAutoSync, last.session == step.session,
           case let .paste(_, gathered) = last.change {
            queue[queue.count - 1].change = .paste(source, gathered.union(step.carried))
            queue[queue.count - 1].photos = photos
            queue[queue.count - 1].steps.append(step.id)
            if !last.stepTitle.contains(step.title) {
                queue[queue.count - 1].stepTitle = "\(last.stepTitle), \(step.title)"
            }
            return
        }
        enqueue(Job(
            change: .paste(source, step.carried), photos: photos, title: "Auto Sync", stepTitle: stepTitle,
            isAutoSync: true, session: step.session, steps: [step.id], done: done,
        ))
    }

    /// The open photo moved through its history (Undo, Redo, a click) to the step whose edit is
    /// `source`, the steps after it being `undone`: each photo of the run in `photos` follows.
    func follow(
        _ source: EditRecipe, undone: Set<UUID>, session: UUID, on photos: [URL], title: String,
        done: @escaping (URL, EditRecipe) -> Void,
    ) {
        guard isAutoSyncing, let run, run.session == session else { return }
        let members = photos.filter { run.photos[$0] != nil }
        guard !members.isEmpty else { return }
        let job = Job(
            change: .follow(source, undone), photos: members, title: title, stepTitle: title, session: session,
            done: done,
        )
        if progress != nil, let last = queue.last, last.isFollow, last.session == session {
            queue[queue.count - 1] = job
            return
        }
        enqueue(job)
    }

    /// The open photo's steps that a new step replaced, after an Undo: none of them applies again.
    func forget(_ steps: some Sequence<UUID>) {
        for id in steps {
            run?.steps[id] = nil
        }
    }

    /// The open photo's history was cleared: its earlier steps can't be followed back.
    func endRun() {
        run = nil
    }

    private func record(_ step: RunStep) {
        if run?.session != step.session {
            run = AutoSyncRun(session: step.session)
        }
        run?.steps[step.id] = step.carried
    }

    private func enqueue(_ job: Job) {
        guard !job.photos.isEmpty else { return }
        if progress == nil {
            start(job)
        } else {
            queue.append(job)
        }
    }

    private func start(_ job: Job) {
        progress = Progress(title: job.title, done: 0, total: job.photos.count)
        title = job.title
        report = nil
        before = [:]
        written = [:]
        task = Task { [weak self] in
            await self?.process(job)
        }
    }

    /// Waits for the batch running, if any.
    func idle() async {
        await task?.value
    }

    /// Returns once the batch's save of `url`, if one is on its way, has landed.
    func wait(for url: URL) async {
        await writing[url]?.value
    }

    /// `save` run on the editor's save queue, unless `url` is open in the editor, which makes
    /// `change` instead. Between the check and the save being registered there is no suspension,
    /// so the editor opening it reads it after the save.
    private func land<T: Sendable>(
        _ url: URL, _ change: EditorChange, title: String, _ save: @escaping @Sendable (SidecarStore) -> T,
    ) async -> Landed<T> {
        while let editor, editor.isOpen(url) {
            let outcome = await editor.apply(change, to: url, title: title)
            if case .notOpen = outcome {
                continue
            }
            return .inEditor(outcome)
        }
        let (store, saves) = (store, saves)
        let saving = Task.detached {
            guard let saves else { return save(store) }
            return await saves.read { save(store) }
        }
        let landing = Task { _ = await saving.value }
        writing[url] = landing
        let result = await saving.value
        if writing[url] == landing {
            writing[url] = nil
        }
        return .saved(result)
    }

    /// Puts back every photo of the last batch not edited since, as a batch of its own: batches
    /// started meanwhile wait for it.
    func undo(done: @escaping (URL, EditRecipe) -> Void) {
        guard canUndo else { return }
        let written = written
        let before = before
        let title = "Undo \(title)"
        self.written = [:]
        self.before = [:]
        progress = Progress(title: title, done: 0, total: written.count)
        report = nil
        task = Task { [weak self] in
            await self?.putBack(written, before: before, title: title, done: done)
        }
    }

    private func putBack(
        _ written: [URL: Sidecar], before: [URL: EditRecipe?], title: String, done: (URL, EditRecipe) -> Void,
    ) async {
        var unread = 0
        for (url, after) in written {
            guard !Task.isCancelled else { break }
            defer { progress?.done += 1 }
            guard let previous = before[url] else { continue }
            await saves?.wait(for: url)
            await beforeWriting(url)
            let landed = await land(url, .edit(previous ?? EditRecipe(), over: after.recipe), title: title) { store in
                Self.puttingBack(after, to: previous, title: title, for: url, in: store)
            }
            switch landed {
            case let .saved(.done(recipe)), let .inEditor(.applied(recipe?)):
                run?.photos[url] = nil
                done(url, recipe)
            case .saved(.unreadable):
                unread += 1
            case .saved(.editedSince), .inEditor:
                continue
            }
        }
        let photos = "\(unread) photo\(unread == 1 ? "" : "s")"
        let parts = [
            Task.isCancelled ? "Stopped before the end." : nil,
            unread > 0 ? "\(photos) couldn't be put back: the edit can't be read." : nil,
        ].compactMap(\.self)
        report = parts.isEmpty ? nil : parts.joined(separator: " ")
        progress = nil
        if !queue.isEmpty {
            start(queue.removeFirst())
            await task?.value
        }
    }

    /// The photo at `url` given back `previous` (nil: it had no sidecar), if its edit is still
    /// as the batch left it, `after`. Read and written in one go on the save queue.
    private nonisolated static func puttingBack(
        _ after: Sidecar, to previous: EditRecipe?, title: String, for url: URL, in store: SidecarStore,
    ) -> PuttingBack {
        guard store.protection(for: url) == nil, case let .success(read) = Result(catching: {
            try store.loadThrowing(for: url)
        }) else { return .unreadable }
        guard let current = read, current.recipe == after.recipe else { return .editedSince }
        if let previous {
            try? store.save(recording(previous, in: current, from: after.recipe, title: title), for: url)
            return .done(previous)
        }
        if current.hasSameContent(as: after) {
            store.delete(for: url)
        } else {
            // Rated, say, since the sync made it: only the edit goes back.
            try? store.saveOrRemove(recording(EditRecipe(), in: current, from: after.recipe, title: title), for: url)
        }
        return .done(EditRecipe())
    }

    private func process(_ job: Job) async {
        var engine: (any EditingEngine)?
        var skipped = 0
        var editedSince = 0
        var changedMeanwhile = 0
        var failedMasks = 0
        let inRun = job.session != nil && run?.session == job.session
        for url in job.photos {
            guard !Task.isCancelled else { break }
            defer { progress?.done += 1 }
            /// The editor made the change, or left the photo as it is.
            func madeInEditor(_ outcome: EditorOutcome) {
                run?.photos[url] = nil
                switch outcome {
                case let .applied(recipe?):
                    job.done(url, recipe)
                case .left where job.isFollow:
                    editedSince += 1
                case .left:
                    skipped += 1
                case .applied(nil), .notOpen:
                    break
                }
            }
            if !job.isFollow, let editor, editor.isOpen(url) {
                let outcome = await editor.apply(.change(job.change), to: url, title: job.stepTitle)
                if case .notOpen = outcome {} else {
                    madeInEditor(outcome)
                    continue
                }
            }
            await saves?.wait(for: url)
            // Sidecars are read and written off the main thread: on a busy disk one write can take seconds.
            let store = store
            // Nil when it's protected; a failure when it's there but can't be read now.
            let read = await Task.detached { () -> Result<Sidecar?, any Error>? in
                store.protection(for: url) == nil ? Result { try store.loadThrowing(for: url) } : nil
            }.value
            guard case let .success(existing)? = read else {
                skipped += 1
                continue
            }
            let original = existing?.recipe ?? EditRecipe()
            // The run goes on for a photo it last left as it is; otherwise it starts over from here.
            let member = inRun ? run?.photos[url].flatMap { $0.last == original ? $0 : nil } : nil
            var change = job.change
            var start = original
            if case let .follow(source, undone) = job.change {
                guard let run, let member else {
                    if run?.photos[url] != nil {
                        editedSince += 1
                    }
                    continue
                }
                change = .paste(source, run.carried(to: member, without: undone))
                start = member.base ?? EditRecipe()
            }
            guard let applied = await applying(change, to: start, current: original, url, &engine) else { continue }
            let next = applied.recipe
            failedMasks += applied.failedMasks
            guard next != original else {
                if var member {
                    member.reached.formUnion(job.steps)
                    run?.photos[url] = member
                }
                continue
            }
            var session = member?.session
                ?? HistorySession(steps: [
                    HistoryStep(action: .open, title: existing == nil ? "Import" : "Opened", recipe: original),
                ])
            session.steps.append(HistoryStep(action: change.action, title: job.stepTitle, recipe: next))
            if session.steps.count > Self.maximumRunSteps {
                session.steps.removeFirst(session.steps.count - Self.maximumRunSteps)
            }
            await beforeWriting(url)
            let inEditor: EditorChange = job.isFollow ? .edit(next, over: original) : .change(job.change)
            let saved: Sidecar
            switch await land(url, inEditor, title: job.stepTitle, { [session] store in
                Self.saving(next, session: session, over: original, for: url, in: store)
            }) {
            case let .saved(.saved(sidecar)):
                saved = sidecar
            case .saved(.unreadable):
                skipped += 1
                continue
            case .saved(.editedSince):
                changedMeanwhile += 1
                continue
            case .saved(.failed):
                continue
            case let .inEditor(outcome):
                madeInEditor(outcome)
                continue
            }
            // updateValue: a photo without a sidecar keeps its nil (a subscript would drop the key).
            before.updateValue(existing?.recipe, forKey: url)
            written[url] = saved
            if inRun {
                run?.photos[url] = AutoSyncRun.Member(
                    base: member.map(\.base) ?? existing?.recipe, reached: (member?.reached ?? []).union(job.steps),
                    last: saved.recipe, session: session,
                )
            } else {
                run?.photos[url] = nil
            }
            job.done(url, next)
        }
        report = Self.report(
            skipped: skipped, editedSince: editedSince, changedMeanwhile: changedMeanwhile, failedMasks: failedMasks,
            cancelled: Task.isCancelled,
        )
        progress = nil
        if !queue.isEmpty {
            start(queue.removeFirst())
            await task?.value
        }
    }

    /// `recipe` and `session` saved for the photo at `url` if its edit is still `original`,
    /// keeping what else changed since (a rating, say). Read and written in one go on the save
    /// queue, and never over a sidecar that can't be read.
    private nonisolated static func saving(
        _ recipe: EditRecipe, session: HistorySession, over original: EditRecipe, for url: URL, in store: SidecarStore,
    ) -> Saving {
        guard store.protection(for: url) == nil, case let .success(current) = Result(catching: {
            try store.loadThrowing(for: url)
        }) else { return .unreadable }
        guard (current?.recipe ?? EditRecipe()) == original else { return .editedSince }
        var sidecar = current ?? Sidecar(recipe: recipe)
        sidecar.recipe = recipe
        sidecar.modified = Date()
        sidecar.session = session
        guard (try? store.save(sidecar, for: url)) != nil else { return .failed }
        // As read back, so Undo can tell the photo hasn't been edited since (dates round).
        return .saved(store.load(for: url) ?? sidecar)
    }

    /// `change` made to `start` for the photo at `url`, whose edit is `current`: the AI masks it
    /// brings, and an Auto white balance, computed for that photo. Nil when it changes nothing.
    private func applying(
        _ change: Change, to start: EditRecipe, current: EditRecipe, _ url: URL, _ engine: inout (any EditingEngine)?,
    ) async -> (recipe: EditRecipe, failedMasks: Int)? {
        var next = start
        var masks: Set<UUID>?
        var autoWhiteBalance = false
        switch change {
        case let .paste(source, selection):
            let pasted = start.pasting(source, selection)
                .reusingAIMasks(from: current, in: EditRecipe.pastedMasks(from: source, selection))
            next = await anchored(pasted.recipe, url)
            masks = pasted.recompute
            if selection.items.contains("whiteBalance") {
                // As Shot is the photo's own, read when it opens; Auto is measured for it.
                if next.whiteBalanceMode == .asShot {
                    next.reset([.temperature, .tint])
                }
                autoWhiteBalance = next.whiteBalanceMode == .auto
            }
        case .updateAIMasks:
            masks = nil
        case let .healDust(found):
            masks = []
            let specks = found[url] ?? []
            guard !specks.isEmpty else { return nil }
            engine = engine ?? makeEngine()
            var opened = false
            if let engine {
                opened = await (try? engine.open(url)) != nil
            }
            for speck in specks {
                var spot = RetouchSpot(center: speck.center, source: speck.center, radius: speck.radius)
                let found = opened ? await engine?.retouchSource(for: spot, recipe: start) : nil
                spot.source = found ?? ImagePoint(x: min(speck.center.x + speck.radius * 2.5, 1), y: speck.center.y)
                next.spots.append(spot)
            }
        case .follow:
            return nil
        }
        let needsMasks = next.masks.contains { layer in
            (masks?.contains(layer.id) ?? true) && layer.components.contains { $0.shape.isAIRaster }
        }
        var failedMasks = 0
        if needsMasks || autoWhiteBalance {
            engine = engine ?? makeEngine()
            if let engine, await (try? engine.open(url)) != nil {
                if autoWhiteBalance, let wb = await engine.autoWhiteBalance() {
                    next[.temperature] = wb.temperature
                    next[.tint] = wb.tint
                }
                if needsMasks {
                    let (recomputed, failed) = await EditorModel.recomputingAIMasks(next, in: masks, engine: engine)
                    next = recomputed
                    failedMasks = failed
                }
            }
        }
        return (next, failedMasks)
    }

    /// `edit` with the photo's own exposure anchor (`EditRecipe.anchored`), its camera read from the
    /// file only when the edit needs an anchor it hasn't got.
    private func anchored(_ edit: EditRecipe, _ url: URL) async -> EditRecipe {
        guard edit.baseLook.isReproduction,
              edit.exposureAnchor == nil else { return edit.anchored(edit.exposureAnchor) }
        let photo: ExposureAnchor? = if let photoAnchor {
            await photoAnchor(url)
        } else {
            .typical(for: nil)
        }
        return edit.anchored(photo)
    }

    /// `sidecar` with its edit changed to `recipe` from `current`, in a history session of its own,
    /// for a change made without opening the photo.
    private nonisolated static func recording(
        _ recipe: EditRecipe, in sidecar: Sidecar, from current: EditRecipe, title: String,
    ) -> Sidecar {
        var sidecar = sidecar
        sidecar.recipe = recipe
        sidecar.modified = Date()
        sidecar.session = HistorySession(steps: [
            HistoryStep(action: .open, title: "Opened", recipe: current),
            HistoryStep(action: .paste, title: title, recipe: recipe),
        ])
        return sidecar
    }

    private static func report(
        skipped: Int, editedSince: Int, changedMeanwhile: Int, failedMasks: Int, cancelled: Bool,
    ) -> String? {
        var parts: [String] = []
        if cancelled {
            parts.append("Stopped before the end.")
        }
        if skipped > 0 {
            let photos = "\(skipped) photo\(skipped == 1 ? " was" : "s were")"
            parts.append("\(photos) left alone: edited by a newer Redlamp, or the edit can't be read.")
        }
        if editedSince > 0 {
            let photos = "\(editedSince) photo\(editedSince == 1 ? " was" : "s were")"
            parts.append("\(photos) left alone: edited since Auto Sync changed them.")
        }
        if changedMeanwhile > 0 {
            let photos = "\(changedMeanwhile) photo\(changedMeanwhile == 1 ? " was" : "s were")"
            parts.append("\(photos) left alone: edited while the batch ran.")
        }
        if failedMasks > 0 {
            parts.append("\(failedMasks) AI mask\(failedMasks == 1 ? "" : "s") couldn't be computed for its photo.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

private extension SettingsSync.Change {
    var action: HistoryAction {
        switch self {
        case .paste, .follow: .paste
        case .updateAIMasks: .mask(nil)
        case .healDust: .retouch
        }
    }
}

extension MaskShape {
    /// A bitmap an AI model computed for one photo (Depth Range's depth map too).
    var isAIRaster: Bool {
        switch self {
        case .ai, .depthRange: true
        default: false
        }
    }
}
