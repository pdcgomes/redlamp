import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// One of the panels' changes, as Library's Undo takes it back and Redo makes it again: one batch or a few
/// made together (a keyword renamed and given its options).
@MainActor
final class PanelStep {
    let title: String
    let changes: [PanelChange]
    /// The photos it's made on, for their saves and Develop's open photo, and their IDs in the index.
    let photos: [URL]
    let ids: [Int64]
    /// Each change's batch as it was made last, and its Undo as it was taken back last.
    var batches: [UUID?]
    var undos: [UUID?]
    /// Culling's newest change when it was made or made again; and, when it was taken back, culling's newest
    /// to make again and every change culling had: they tell Undo and Redo which of the two goes first, and
    /// Redo that a change made since leaves nothing to make again.
    var cullingBefore: CullingStep?
    var cullingRedoBefore: CullingStep?
    var cullingKnown: [CullingStep] = []

    init(title: String, changes: [PanelChange], photos: [URL], ids: [Int64]) {
        self.title = title
        self.changes = changes
        self.photos = photos
        self.ids = ids
        batches = Array(repeating: nil, count: changes.count)
        undos = Array(repeating: nil, count: changes.count)
    }
}

public extension LibraryPanels {
    /// Changes Undo can take back.
    static let undoLimit = 20

    // MARK: - Keywording (LIB-21)

    /// The keywords typed in the keywording panel's field, Lightroom Classic's way (`KeywordList.entered`),
    /// each one the list has or a new one, added to the photos selected.
    @discardableResult
    func addKeywords(_ text: String) -> Bool {
        let list = keywordList ?? KeywordList(counts: [:], definitions: KeywordDefinitions())
        return add(list.entered(text))
    }

    @discardableResult
    func add(_ keywords: [KeywordPath]) -> Bool {
        let ids = selection.ids
        guard !keywords.isEmpty, !ids.isEmpty, !keywords.allSatisfy({ selection.hasEverywhere($0) == true }) else {
            return false
        }
        var overlay = PanelOverlay(ids: ids)
        overlay.adding = keywords
        return make(
            [.keywords(.add(keywords, to: ids))], title: Self.title("Add", keywords, ids.count), overlay: overlay,
        )
    }

    /// Takes `keyword` off the photos selected.
    @discardableResult
    func remove(_ keyword: KeywordPath) -> Bool {
        let ids = selection.ids
        guard !ids.isEmpty, (selection.keywords[keyword] ?? 0) > 0 else { return false }
        var overlay = PanelOverlay(ids: ids)
        overlay.removing = [keyword]
        return make(
            [.keywords(.remove([keyword], from: ids))], title: Self.title("Remove", [keyword], ids.count, from: true),
            overlay: overlay,
        )
    }

    /// Puts `keyword` on every photo selected, or takes it off them all when every one has it: a keyword
    /// list's checkbox and a keyword set's button.
    @discardableResult
    func toggle(_ keyword: KeywordPath) -> Bool {
        selection.hasEverywhere(keyword) == true ? remove(keyword) : add([keyword])
    }

    /// ⌥1 to ⌥9: the active set's keyword in that place, toggled on the photos selected.
    @discardableResult
    func applyKeywordSet(_ number: Int) -> Bool {
        guard let keyword = activeSet?.keyword(forShortcut: number) else { return false }
        return toggle(keyword)
    }

    func canApplyKeywordSet(_ number: Int) -> Bool {
        activeSet?.keyword(forShortcut: number) != nil && !selection.ids.isEmpty
    }

    /// Makes `name` the set ⌥1 to ⌥9 apply. It isn't on Undo: it changes no photo.
    func chooseKeywordSet(_ name: String) {
        guard let service = model?.library.service, let keywords, name != keywords.active.name else { return }
        let sets = keywords.sets.filter { $0.name != KeywordSet.recentName }
        let custom = sets == KeywordSet.builtIn ? nil : sets
        let active = name == KeywordSet.recentName ? nil : name
        if let chosen = keywords.sets.first(where: { $0.name == name }) {
            self.keywords?.active = chosen
        }
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            let outcome = await service.setKeywordSets(custom, active: active)
            self?.reportFailure(outcome, of: "Choose the keyword set “\(name)”")
            self?.refreshKeywords()
        }
    }

    // MARK: - The keyword list (LIB-21)

    /// Renames `keyword` to `name` within the keyword holding it, and gives it `options`, as one change.
    @discardableResult
    func edit(_ keyword: KeywordPath, name: String, options: KeywordOptions) -> Bool {
        guard let renamed = keyword.parent.map({ $0.appending(name) }) ?? KeywordPath(names: [name]) else {
            return false
        }
        var changes: [PanelChange] = []
        if renamed != keyword {
            changes.append(.keywords(.rename(keyword, to: renamed)))
        }
        if options != keywordList?[keyword]?.options || renamed != keyword {
            changes.append(.keywords(.define(renamed, options)))
        }
        guard !changes.isEmpty else { return false }
        return make(changes, title: "Edit “\(keyword.displayName)”", onSelection: false)
    }

    /// Merges `source` into `target`: its photos get `target` instead, the keywords inside it go inside
    /// `target`, and its synonyms join `target`'s.
    @discardableResult
    func merge(_ source: KeywordPath, into target: KeywordPath) -> Bool {
        guard source != target else { return false }
        return make(
            [.keywords(.merge([source], into: target))],
            title: "Merge “\(source.displayName)” into “\(target.displayName)”", onSelection: false,
        )
    }

    /// Takes `keyword` and every keyword inside it off every photo and out of the list.
    @discardableResult
    func delete(_ keyword: KeywordPath) -> Bool {
        make([.keywords(.delete([keyword]))], title: "Delete “\(keyword.displayName)”", onSelection: false)
    }

    /// Puts the keywords `text` names in the list, with no photos yet.
    @discardableResult
    func create(_ text: String) -> Bool {
        let list = keywordList ?? KeywordList(counts: [:], definitions: KeywordDefinitions())
        let keywords = list.entered(text).filter { list[$0] == nil }
        guard !keywords.isEmpty else { return false }
        return make(
            keywords.map { .keywords(.define($0, KeywordOptions())) }, title: Self.title("Create", keywords, nil),
            onSelection: false,
        )
    }

    /// Drops the keywords no photo has, nor any keyword inside them, from the list.
    @discardableResult
    func purgeUnusedKeywords() -> Bool {
        make([.keywords(.purgeUnused)], title: "Purge Unused Keywords", onSelection: false)
    }

    /// A keyword list row's arrow: the photos of the source shown that have `keyword` or one inside it,
    /// through the filter bar's text.
    func showPhotos(of keyword: KeywordPath) {
        guard let filters = model?.libraryFilters else { return }
        filters.setText(QueryCompletion(field: .keyword, value: keyword.text).term)
        if !filters.filter.sections.contains(.text) {
            filters.show(.text, adding: true)
        }
        filters.setBarShown(true)
    }

    /// Reads Lightroom Classic's keyword-list file at `url` into the list, as one change with Undo: how many
    /// keywords it held, or nil when it couldn't be read.
    func importKeywords(from url: URL) async -> Int? {
        let read = await Task.detached { () -> Result<[LightroomKeywordFile.Keyword], any Error> in
            Result { try LightroomKeywordFile.read(Data(contentsOf: url)) }
        }.value
        switch read {
        case let .success(keywords):
            guard !keywords.isEmpty else { return 0 }
            let title = "Import \(keywords.count == 1 ? "a keyword" : "\(keywords.count) keywords")"
            guard make([.keywords(.importList(keywords))], title: title, onSelection: false) else { return nil }
            await written()
            return problem == nil ? keywords.count : nil
        case let .failure(error):
            problem = "\(url.lastPathComponent) isn't a keyword list: \(error)"
            model?.activity.record(.error, problem ?? "")
            return nil
        }
    }

    /// Writes the keyword list to `url` as Lightroom Classic's keyword-list file.
    func exportKeywords(to url: URL) async -> LightroomKeywordFile.Export? {
        guard let service = model?.library.service else { return nil }
        await tail?.value
        switch await service.exportKeywords(to: url) {
        case let .success(export):
            model?.activity.record(.action, "Export \(export.keywords) keywords")
            return export
        case let .failure(error):
            problem = "The keywords weren't exported: \(error)"
            model?.activity.record(.error, problem ?? "")
            return nil
        }
    }

    // MARK: - Metadata (LIB-22)

    /// Gives every photo selected `text` for `field`, an empty text clearing it.
    @discardableResult
    func set(_ field: MetadataPreset.Field, to text: String) -> Bool {
        let ids = selection.ids
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ids.isEmpty, selection.fields[field] != (value.isEmpty ? .none : .same(value)) else { return false }
        let given = value.isEmpty ? nil : value
        let metadataField: MetadataField = switch field {
        case .title: .title(given)
        case .caption: .caption(given)
        case .creator: .creator(given)
        case .copyright: .copyright(given)
        case .sublocation: .sublocation(given)
        case .city: .city(given)
        case .state: .state(given)
        case .country: .country(given)
        case .countryCode: .countryCode(given)
        }
        var overlay = PanelOverlay(ids: ids)
        overlay.fields[field] = given.map(SharedValue.same) ?? SharedValue.none
        return make(
            [.metadata(.set([metadataField], on: ids))],
            title: "Set \(Self.name(of: field)) of \(Self.count(ids.count))", overlay: overlay,
        )
    }

    /// Gives every photo selected the fields `preset` ticks, each replacing, appending to or prefixing what
    /// it has.
    @discardableResult
    func apply(_ preset: MetadataPreset) -> Bool {
        let ids = selection.ids
        guard !ids.isEmpty, !preset.fields.isEmpty else { return false }
        return make([.metadata(.preset(preset, to: ids))], title: "Apply “\(preset.name)” to \(Self.count(ids.count))")
    }

    /// Keeps `preset` in place of the one named `replacing` (or its own name).
    func save(_ preset: MetadataPreset, replacing name: String? = nil) async -> Bool {
        guard let service = model?.library.service else { return false }
        let saved = await service.save(preset, replacing: name)
        refreshPresets()
        return saved
    }

    func deletePreset(named name: String) async -> Bool {
        guard let service = model?.library.service else { return false }
        let removed = await service.removePreset(named: name)
        refreshPresets()
        return removed
    }

    /// Adds `seconds` to the capture time of every photo selected, or takes them off.
    @discardableResult
    func shiftCaptureTime(by seconds: Int) -> Bool {
        let ids = selection.ids
        guard !ids.isEmpty, seconds != 0 else { return false }
        return make(
            [.captureTime(.shift(ids, by: seconds))],
            title: "Shift the capture time of \(Self.count(ids.count)) by \(CaptureTimeChange.describe(shift: seconds))",
        )
    }

    /// Gives the active photo `time` by the camera's clock, read as UTC, and shifts the others selected by as
    /// much, as Lightroom Classic's Edit Capture Time does.
    @discardableResult
    func setCaptureTime(_ time: Date) -> Bool {
        guard let id = selection.activeID, !selection.ids.isEmpty else { return false }
        let others = selection.ids.filter { $0 != id }
        return make(
            [.captureTime(.set(id, to: time, shifting: others))],
            title: "Set the capture time of \(Self.count(others.count + 1)) to \(CaptureTimeChange.describe(time: time))",
        )
    }

    // MARK: - Undo and Redo

    /// Library's Undo: the panels' last change when it came after culling's last; nil when culling's goes
    /// first.
    func undoInLibrary() -> Bool? {
        guard let model, let step = undoSteps.last, model.cullingUndo.last === step.cullingBefore else { return nil }
        undoSteps.removeLast()
        step.cullingRedoBefore = model.cullingRedo.last
        step.cullingKnown = model.cullingUndo + model.cullingRedo
        redoSteps.append(step)
        problem = nil
        model.activity.record(.action, "Undo \(step.title)")
        saveOpenPhoto(of: step)
        enqueue(step, as: .undo)
        return true
    }

    /// Library's Redo: the panels' change Undo took back last, when it was taken back after culling's; nil
    /// when culling's goes first, or a change made since leaves nothing to make again.
    func redoInLibrary() -> Bool? {
        guard let model, let step = nextRedo else {
            if model.map({ isStale(redoSteps.last, in: $0) }) == true {
                redoSteps.removeAll()
            }
            return nil
        }
        redoSteps.removeLast()
        step.cullingBefore = model.cullingUndo.last
        undoSteps.append(step)
        problem = nil
        model.activity.record(.action, "Redo \(step.title)")
        saveOpenPhoto(of: step)
        enqueue(step, as: .redo)
        return true
    }

    /// True when Library's Undo would take back one of the panels' changes or culling's; nil when only
    /// culling's could say.
    var canUndoInLibrary: Bool? {
        undoSteps.isEmpty ? nil : true
    }

    var canRedoInLibrary: Bool? {
        nextRedo == nil ? nil : true
    }

    /// Returns once every change asked for has been made.
    @_spi(Harness) func written() async {
        while let tail {
            await tail.value
            if self.tail == tail {
                break
            }
        }
    }

    @_spi(Harness) var undoCount: Int {
        undoSteps.count
    }
}

extension LibraryPanels {
    private enum Making {
        case change, undo, redo
    }

    /// The step Redo would make again: the panels' last taken back, when culling took back none after it and
    /// no change was made since.
    private var nextRedo: PanelStep? {
        guard let model, let step = redoSteps.last, !isStale(step, in: model),
              model.cullingRedo.last === step.cullingRedoBefore
        else { return nil }
        return step
    }

    /// Whether a culling change was made since `step` was taken back: a step culling didn't have then.
    private func isStale(_ step: PanelStep?, in model: EditorModel) -> Bool {
        guard let step else { return false }
        let known = Set(step.cullingKnown.map(ObjectIdentifier.init))
        return model.cullingUndo.contains { !known.contains(ObjectIdentifier($0)) }
    }

    /// Makes `changes` as one step with Undo, `overlay` showing it until the library has it. Made `onSelection`,
    /// the photos selected wait for their saves, and Develop's open photo among them saves first; a change to
    /// the keyword list reaches the photos with its keywords, wherever they are.
    @discardableResult
    func make(
        _ changes: [PanelChange], title: String, overlay: PanelOverlay? = nil, onSelection: Bool = true,
    ) -> Bool {
        guard let model, model.library.service?.isReady == true else { return false }
        let step = PanelStep(
            title: title, changes: changes, photos: onSelection ? model.selectedPhotos : [],
            ids: onSelection ? selection.ids : [],
        )
        problem = nil
        push(step)
        if let overlay {
            overlays.append((step, overlay))
            var shown = selection
            overlay.apply(to: &shown)
            selection = shown
        }
        model.activity.record(.action, title)
        saveOpenPhoto(of: step)
        enqueue(step, as: .change)
        return true
    }

    /// Develop's open photo, when `step` is made on it: what it hasn't saved is saved first, and from then on
    /// its saves count the batch's change as another writer's, so they never write it over the batch's. The
    /// batch waits for both (`waitForSaves`).
    private func saveOpenPhoto(of step: PanelStep) {
        guard let model, model.info != nil, !model.isReadOnly, let url = model.selection, step.photos.contains(url)
        else { return }
        model.saveNow()
        model.saves.enqueue(.track(nil, opened: model.sidecarToSave), for: url)
    }

    /// `step` on Undo, newest; nothing left to Redo, culling's included.
    private func push(_ step: PanelStep) {
        guard let model else { return }
        step.cullingBefore = model.cullingUndo.last
        undoSteps.append(step)
        if undoSteps.count > Self.undoLimit {
            undoSteps.removeFirst(undoSteps.count - Self.undoLimit)
        }
        redoSteps.removeAll()
        model.cullingRedo.removeAll()
    }

    private func enqueue(_ step: PanelStep, as making: Making) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            await self?.run(step, as: making)
        }
    }

    /// Makes, takes back or makes again `step`'s batches, one after another, off the main thread, its photos'
    /// saves first; then shows what the library has.
    private func run(_ step: PanelStep, as making: Making) async {
        guard let model, let service = model.library.service else { return }
        await waitForSaves(of: step.photos)
        let title = making == .undo ? "Undo \(step.title)" : making == .redo ? "Redo \(step.title)" : step.title
        let report = progressReport(title, total: max(step.ids.count, 1))
        var reasons: [String: String] = [:]
        var failure: String?
        switch making {
        case .change, .redo:
            for (place, change) in step.changes.enumerated() {
                let outcome = making == .change ? await service.run(change, progress: report)
                    : await service.redo(change, undo: step.undos[place])
                step.batches[place] = outcome.batch
                reasons.merge(outcome.reasons) { first, _ in first }
                if let error = outcome.error {
                    failure = error
                    break
                }
            }
        case .undo:
            for place in step.changes.indices.reversed() {
                guard let batch = step.batches[place] else { continue }
                let outcome = await service.undo(step.changes[place], batch: batch)
                step.undos[place] = outcome.batch
                reasons.merge(outcome.reasons) { first, _ in first }
                if let error = outcome.error {
                    failure = error
                    break
                }
            }
        }
        progress = nil
        if making == .change, failure == nil, step.batches.allSatisfy({ $0 == nil }) {
            // It changed nothing, so there's nothing to take back.
            undoSteps.removeAll { $0 === step }
        }
        if let failure {
            problem = "\(title) wasn't made: \(failure)"
            model.activity.record(.error, problem ?? "")
            if making == .change, step.batches.allSatisfy({ $0 == nil }) {
                undoSteps.removeAll { $0 === step }
            }
        }
        if !reasons.isEmpty {
            let why = Set(reasons.values).sorted().joined(separator: "; ")
            model.activity.record(.error, "\(title) wasn't saved to \(Self.count(reasons.count)): \(why)")
        }
        await service.settled()
        overlays.removeAll { $0.step === step }
        refresh()
        if step.changes.contains(where: \.isKeywords) {
            refreshKeywords()
        }
    }

    /// Hands a batch's progress to the panels from the threads writing its sidecars, at most every 50 ms.
    private func progressReport(_ title: String, total: Int) -> @Sendable (Int, Int) -> Void {
        progress = PanelProgress(title: title, done: 0, total: total)
        let last = Mutex<ContinuousClock.Instant?>(nil)
        return { done, total in
            let due = last.withLock { last in
                let now = ContinuousClock.now
                guard done == total || last.map({ now - $0 > .milliseconds(50) }) ?? true else { return false }
                last = now
                return true
            }
            guard due else { return }
            Task { @MainActor in
                guard self.progress?.title == title else { return }
                self.progress = PanelProgress(title: title, done: done, total: total)
            }
        }
    }

    /// Returns once the saves asked for any of `photos` before the call are on disk, so a batch reads their
    /// sidecars as those saves leave them.
    private func waitForSaves(of photos: [URL]) async {
        guard let saves = model?.saves, !photos.isEmpty else { return }
        let pending = await Task.detached(priority: .userInitiated) { saves.pending(photos) }.value
        for photo in pending {
            await saves.wait(for: photo)
        }
    }

    func reportFailure(_ outcome: PanelOutcome, of title: String) {
        guard let error = outcome.error else { return }
        problem = "\(title) wasn't made: \(error)"
        model?.activity.record(.error, problem ?? "")
    }

    // MARK: - Words

    /// `Add “Places › Portugal › Lisbon” to 120 photos`, `Remove 3 keywords from a photo`.
    static func title(_ verb: String, _ keywords: [KeywordPath], _ photos: Int?, from: Bool = false) -> String {
        let what = keywords.count == 1 ? "“\(keywords[0].displayName)”" : "\(keywords.count) keywords"
        guard let photos else { return "\(verb) \(what)" }
        return "\(verb) \(what) \(from ? "from" : "to") \(count(photos))"
    }

    /// `12 photos`, `a photo`.
    static func count(_ photos: Int) -> String {
        photos == 1 ? "a photo" : "\(photos.formatted(.number.locale(Locale(identifier: "en_US")))) photos"
    }

    static func name(of field: MetadataPreset.Field) -> String {
        switch field {
        case .title: "the title"
        case .caption: "the caption"
        case .creator: "the creator"
        case .copyright: "the copyright"
        case .sublocation: "the sublocation"
        case .city: "the city"
        case .state: "the state or province"
        case .country: "the country"
        case .countryCode: "the country code"
        }
    }
}

// MARK: - Keys, menus and the palette

extension EditorModel {
    /// Library's Undo and Redo when the panels' change goes first, the keyword set's keys, Edit Capture Time
    /// and the keyword-list files; nil for every other action.
    func performPanelShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .undo where module == .library: return libraryPanels.undoInLibrary()
        case .redo where module == .library: return libraryPanels.redoInLibrary()
        case .editCaptureTime:
            guard module == .library else { return false }
            return PanelSheets.editCaptureTime(model: self)
        case .importKeywords: return KeywordFiles.importKeywords(model: self)
        case .exportKeywords: return KeywordFiles.exportKeywords(model: self)
        default:
            guard let number = action.keywordSetNumber else { return nil }
            guard module == .library else { return false }
            return libraryPanels.applyKeywordSet(number)
        }
    }

    /// Whether `performPanelShortcut` would do something now; nil for the actions it leaves to others.
    func canPerformPanelShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .undo where module == .library: return libraryPanels.canUndoInLibrary
        case .redo where module == .library: return libraryPanels.canRedoInLibrary
        case .editCaptureTime: return module == .library && !libraryPanels.selection.ids.isEmpty
        case .importKeywords, .exportKeywords: return library.service?.isReady == true
        default:
            guard let number = action.keywordSetNumber else { return nil }
            return module == .library && libraryPanels.canApplyKeywordSet(number)
        }
    }
}
