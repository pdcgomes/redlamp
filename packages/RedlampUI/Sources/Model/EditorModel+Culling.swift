import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// Culling (LIB-15): ratings, flags, colour labels, custom labels and marks.
///
/// - **In Library** each change reaches the whole selection (or the photo clicked, when it isn't in it), as
///   one change with Undo and Redo. It's shown at once in the grid, the filmstrip and the loupe, then made in
///   the background: through the library's batches (`LibraryMetadata`) for the photos it has indexed, through
///   the photos' own saves for the rest, and through Develop's save for the photo Develop has open, so that
///   save never races a batch writing the same sidecar.
/// - **In Develop** each change reaches the active photo, as it always has, and isn't on Library's Undo.
/// - A toggle (P, X, 6 to 9, a custom label, B) sets its value on every photo it reaches, or takes it off
///   them all when every one has it already. `[` and `]` step each photo's own rating.
/// - ⇧ with any of them, or Auto Advance for all of them, then makes the photo after them active.
/// - Lists hear of a batch once the index holds it, or, when changes have been asked for since, once the
///   last of them is in the index too; and what culling shows stays shown until they've caught up
///   (`CullingOverlay`), so a list's update never shows an older value over a newer one. A batch that fails,
///   and photos whose sidecars this build can't write, show what their sidecars hold.
public extension EditorModel {
    static let autoAdvanceKey = "culling.autoAdvance"
    /// Culling changes Undo can take back.
    static let cullingUndoLimit = 20

    // MARK: - Keys, menus and the palette

    /// Lightroom Classic's Photo ▸ Auto Advance.
    func toggleAutoAdvance() {
        autoAdvance.toggle()
        library.defaults?.set(autoAdvance, forKey: Self.autoAdvanceKey)
    }

    var canUndoCulling: Bool {
        !cullingUndo.isEmpty
    }

    var canRedoCulling: Bool {
        !cullingRedo.isEmpty
    }

    /// The culling changes Undo can take back, for the regression suite to take back its own.
    @_spi(Harness) var cullingUndoCount: Int {
        cullingUndo.count
    }

    /// Whether culling changes are still being made in the background.
    @_spi(Harness) var isWritingCulling: Bool {
        !cullingQueue.isIdle
    }

    /// The rating, flag, label and mark actions in either module, Undo and Redo in Library, and Auto Advance;
    /// nil for every other, and for `[`, `]` and X where Develop's brushes and crop take them.
    internal func performCullingShortcut(_ action: ShortcutAction, shifted: Bool) -> Bool? {
        switch action {
        case .autoAdvance:
            toggleAutoAdvance()
            return true
        case .undo where module == .library:
            return undoCulling()
        case .redo where module == .library:
            return redoCulling()
        case .decreaseRating where sizedBrush != nil, .increaseRating where sizedBrush != nil:
            return nil
        case .flagReject where module == .develop && activeTool == .crop:
            return nil
        default:
            guard let change = CullingChange(action) else { return nil }
            return cull(change, advance: shifted || autoAdvance)
        }
    }

    /// Whether `performCullingShortcut` would do something now; nil for the actions it leaves alone.
    internal func canPerformCullingShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .autoAdvance: true
        case .undo where module == .library: canUndoCulling
        case .redo where module == .library: canRedoCulling
        default: CullingChange(action) == nil ? nil : (opening ?? selection) != nil
        }
    }

    /// Makes `change`: in Library on the selection, in Develop on the active photo, or the one opening;
    /// `advance` then makes the photo after them active.
    @discardableResult
    func cull(_ change: CullingChange, advance: Bool = false) -> Bool {
        guard let active = opening ?? selection else { return false }
        let rows: [Int]
        if module == .library {
            rows = selectedRows
            cull(change, rows: rows)
        } else {
            rows = library.index(of: active).map { [$0] } ?? []
            cullActivePhoto(change)
        }
        if advance, let last = rows.max(), items.indices.contains(last + 1) {
            select(items[last + 1].url)
        }
        return true
    }

    /// A click on a cell's stars, flag, label or mark, or a photo's context menu: `change` on `photo`, or on
    /// the selection when `photo` is in it.
    func cull(_ change: CullingChange, from photo: URL) {
        guard module == .library, let row = library.index(of: photo) else { return }
        let inSelection = library.photoID(of: photo).map(photoSelection.contains) == true || photo == selection
        cull(change, rows: inSelection ? selectedRows : [row])
        activity.record(.action, change.title)
    }

    /// The custom label `name` on the photos a culling key would reach, toggled as a colour's key toggles it.
    func setCustomLabel(_ name: String) {
        cull(.toggleCustomLabel(name), advance: autoAdvance)
        activity.record(.action, CullingChange.toggleCustomLabel(name).title)
    }

    /// The rows of the photos selected, in order; the active photo's alone when nothing else is selected.
    internal var selectedRows: [Int] {
        guard !photoSelection.isEmpty else { return selection.flatMap(library.index(of:)).map { [$0] } ?? [] }
        let ids = library.photoIDs
        var rows: [Int] = []
        rows.reserveCapacity(photoSelection.count)
        for row in ids.indices where photoSelection.contains(ids[row]) {
            rows.append(row)
        }
        return rows
    }

    // MARK: - Undo and Redo

    /// Takes back the Library's last culling change: each photo that still shows what it gave goes back.
    @discardableResult
    func undoCulling() -> Bool {
        guard module == .library, let step = cullingUndo.popLast() else { return false }
        cullingRedo.append(step)
        var rows: [Int] = []
        var photos: [URL] = []
        var values: [CullingValues] = []
        let items = items
        for (place, url) in step.photos.enumerated() {
            guard let row = library.index(of: url) else { continue }
            let shown = CullingValues(items[row].metadata)
            if shown.matches(step.after[place], in: step.field) {
                rows.append(row)
                photos.append(url)
                values.append(step.before[place])
            }
        }
        let sequence = cullingQueue.request(step.photos)
        show(values, field: step.field, rows: rows, photos: photos, sequence: sequence)
        make(step, sequence: sequence, undoing: true)
        activity.record(.action, "Undo \(step.title)")
        return true
    }

    /// Makes again the culling change Undo took back last.
    @discardableResult
    func redoCulling() -> Bool {
        guard module == .library, let step = cullingRedo.popLast() else { return false }
        cullingUndo.append(step)
        var rows: [Int] = []
        var photos: [URL] = []
        var values: [CullingValues] = []
        for (place, url) in step.photos.enumerated() {
            guard let row = library.index(of: url) else { continue }
            rows.append(row)
            photos.append(url)
            values.append(step.after[place])
        }
        let sequence = cullingQueue.request(step.photos)
        show(values, field: step.field, rows: rows, photos: photos, sequence: sequence)
        make(step, sequence: sequence, undoing: false)
        activity.record(.action, "Redo \(step.title)")
        return true
    }

    // MARK: - Making a change

    /// Gives the photos of `rows` (places in `items`) what `change` asks for, as one change with Undo: shown
    /// at once, then made in the background. A read-only photo open in Develop is left as it is.
    internal func cull(_ change: CullingChange, rows: [Int]) {
        let items = items
        let readOnly = isReadOnly ? selection.flatMap(library.index(of:)) : nil
        let rows = rows.filter { items.indices.contains($0) && $0 != readOnly }
        let current = rows.map { CullingValues(items[$0].metadata) }
        let wanted = change.resolved(current)
        var changed: [Int] = []
        var photos: [URL] = []
        var before: [CullingValues] = []
        var after: [CullingValues] = []
        for (place, row) in rows.enumerated() where !wanted[place].matches(current[place], in: change.field) {
            changed.append(row)
            photos.append(items[row].url)
            before.append(current[place])
            after.append(wanted[place])
        }
        guard !changed.isEmpty else { return }
        let step = CullingStep(title: change.title, field: change.field, photos: photos, before: before, after: after)
        let sequence = cullingQueue.request(photos)
        show(after, field: change.field, rows: changed, photos: photos, sequence: sequence)
        cullingUndo.append(step)
        if cullingUndo.count > Self.cullingUndoLimit {
            cullingUndo.removeFirst(cullingUndo.count - Self.cullingUndoLimit)
        }
        cullingRedo.removeAll()
        remember(after.compactMap(\.customLabel))
        make(step, sequence: sequence, undoing: false)
    }

    /// Shows `values` (one for each of `rows`, the places of `photos`) in the photos' badges as one change,
    /// and in the active photo's metadata when it's among them; kept shown as change `sequence` until the
    /// library's lists have caught up with it.
    private func show(
        _ values: [CullingValues], field: CullingField, rows: [Int], photos: [URL], sequence: UInt64,
    ) {
        cullingOverlay.add(CullingOverlay.Change(sequence: sequence, field: field, photos: photos, values: values))
        show(values, fields: [field], rows: rows)
    }

    private func show(_ values: [CullingValues], fields: [CullingField], rows: [Int]) {
        guard !rows.isEmpty else { return }
        cullingOverlay.publishing = true
        library.updateMetadata(rows) { place, metadata in
            for field in fields {
                values[place].apply(field, to: &metadata)
            }
        }
        cullingOverlay.publishing = false
        if let active = selection.flatMap(library.index(of:)), let place = rows.firstIndex(of: active) {
            for field in fields {
                values[place].apply(field, to: &photoMetadata)
            }
        }
    }

    /// Makes `step` in the background, after the changes asked for before it: its values, or with `undoing`,
    /// takes them back. The photo Develop has open is saved by Develop now.
    private func make(_ step: CullingStep, sequence: UInt64, undoing: Bool) {
        var editor: Int?
        if let selection, info != nil, !isReadOnly, let place = step.photos.firstIndex(of: selection) {
            editor = place
            saveNow()
        }
        let previous = cullingTail
        cullingTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if undoing {
                await takeBack(step, sequence: sequence, editor: editor)
            } else {
                await write(step, sequence: sequence, editor: editor)
            }
            library.service?.photosChanged(cullingQueue.finished(sequence))
            cullingOverlay.finished(sequence)
        }
    }

    /// Writes the step's values: through the library for the photos it has indexed, each group of photos
    /// given the same fields a batch, and through the others' own saves.
    private func write(_ step: CullingStep, sequence: UInt64, editor: Int?) async {
        let field = step.field
        let places = step.photos.indices.filter { $0 != editor }
        var groups: [[MetadataField]: [Int]] = [:]
        for place in places {
            groups[step.after[place].fields(field), default: []].append(place)
        }
        let requests = groups.sorted { $0.value[0] < $1.value[0] }.map { fields, places in
            CullingGroup(fields: fields, photos: places.map { step.photos[$0] })
        }
        var written = CullingWritten()
        if let service = library.service, service.isReady {
            written = await service.cull(requests, sequence: sequence, queue: cullingQueue)
        } else {
            written.unindexed = places.map { step.photos[$0] }
        }
        step.batches = written.batches
        step.ids = written.ids
        let unindexed = Set(written.unindexed)
        step.saved = places.filter { unindexed.contains(step.photos[$0]) } + (editor.map { [$0] } ?? [])
        await save(step.saved.filter { $0 != editor }.map { (step.photos[$0], step.after[$0].setting(field)) })
        await finish(written, of: step, sequence: sequence)
    }

    /// Takes the step back: its batches through the library, and its other photos through their own saves,
    /// each field that still holds what the step gave it.
    private func takeBack(_ step: CullingStep, sequence: UInt64, editor: Int?) async {
        let field = step.field
        var written = CullingWritten()
        if !step.batches.isEmpty, let service = library.service, service.isReady {
            written = await service.undoCulling(step.batches, photos: step.ids, sequence: sequence, queue: cullingQueue)
        }
        let saved = step.saved.filter { $0 != editor }.map { place in
            let (before, after) = (step.before[place], step.after[place])
            return (step.photos[place], { @Sendable (metadata: inout PhotoMetadata) in
                if CullingValues(metadata).matches(after, in: field) {
                    before.apply(field, to: &metadata)
                }
            })
        }
        step.batches = []
        step.saved = []
        await save(saved)
        await finish(written, of: step, sequence: sequence)
    }

    /// Changes each photo's culling metadata through its own save, as the sidecar is on disk then.
    private func save(_ writes: [(URL, @Sendable (inout PhotoMetadata) -> Void)]) async {
        guard !writes.isEmpty else { return }
        let saves = saves
        await Task.detached(priority: .userInitiated) {
            for (url, change) in writes {
                saves.enqueue(.metadata(change), for: url)
            }
        }.value
    }

    /// What's left once the library has made its part of a step: photos it couldn't write show what their
    /// sidecars hold, unless a change asked for after it changes them again, and what failed is logged.
    private func finish(_ written: CullingWritten, of step: CullingStep, sequence: UInt64) async {
        for error in written.errors {
            activity.record(.error, "\(step.title) wasn't saved to every photo: \(error)")
        }
        let later = cullingQueue.changedLater(than: sequence)
        let unwritten = written.unwritten.filter { !later.contains($0) }
        guard !unwritten.isEmpty else { return }
        cullingOverlay.drop(sequence)
        let sidecars = library.sidecars
        let summaries = await Task.detached(priority: .userInitiated) {
            unwritten.map { ($0, sidecars.store(for: $0).summary(for: $0)?.metadata ?? PhotoMetadata()) }
        }.value
        let shown = cullingQueue.changedLater(than: sequence)
        var rows: [Int] = []
        var values: [CullingValues] = []
        for (url, metadata) in summaries where !shown.contains(url) {
            guard let row = library.index(of: url) else { continue }
            rows.append(row)
            values.append(CullingValues(metadata))
        }
        show(values, fields: CullingField.allCases, rows: rows)
    }

    // MARK: - Develop

    /// `change` on the active photo, saved with its edit as Develop saves it; a read-only photo's metadata
    /// doesn't change, since it wouldn't be saved. While another photo opens, the change is that photo's.
    private func cullActivePhoto(_ change: CullingChange) {
        guard let url = opening ?? selection, opening != nil || !isReadOnly else { return }
        let before = CullingValues(opening == nil ? photoMetadata : library.item(for: url)?.metadata ?? PhotoMetadata())
        let after = change.resolved([before])[0]
        guard !after.matches(before, in: change.field) else { return }
        let setting = after.setting(change.field)
        if opening == nil {
            setting(&photoMetadata)
        }
        var shown = CullingOverlay.Change(sequence: 0, field: change.field, photos: [url], values: [after])
        shown.finished = .now
        cullingOverlay.add(shown)
        library.update(url) { setting(&$0.metadata) }
        remember(after.customLabel.map { [$0] } ?? [])
        if info != nil, opening == nil {
            saveNow()
        } else {
            // The metadata shown may be the filmstrip's, not yet the file's: only what `change` set goes to
            // the file, and again onto the file's when it opens.
            metadataChangesWhileOpening.append(setting)
            saves.enqueue(.metadata(setting), for: url)
        }
    }

    // MARK: - Keeping changes shown

    /// A list's update, or a save's report, showed photos as they were before a culling change the library
    /// hasn't caught up with: they show the change again in the next turn of the run loop, before the frame
    /// after this one.
    internal func keepCullingShown(_ diff: LibraryDiff) {
        guard !cullingOverlay.publishing, !cullingOverlay.isFixing, !diff.isEmpty, !cullingOverlay.isEmpty else {
            return
        }
        cullingOverlay.isFixing = true
        Task { [weak self] in
            guard let self else { return }
            cullingOverlay.isFixing = false
            cullingOverlay.expire()
            var rows: [Int] = []
            var shown: [(values: CullingValues, fields: Set<CullingField>)] = []
            let items = items
            for (url, latest) in cullingOverlay.latest() {
                guard let row = library.index(of: url) else { continue }
                let current = CullingValues(items[row].metadata)
                if latest.fields.contains(where: { !current.matches(latest.values, in: $0) }) {
                    rows.append(row)
                    shown.append(latest)
                }
            }
            guard !rows.isEmpty else { return }
            cullingOverlay.publishing = true
            library.updateMetadata(rows) { place, metadata in
                for field in shown[place].fields {
                    shown[place].values.apply(field, to: &metadata)
                }
            }
            cullingOverlay.publishing = false
        }
    }

    // MARK: - Custom labels

    /// The custom labels of `found`, the photos of a folder just listed, among those the menus offer.
    internal func noteCustomLabels(in found: [LibraryItem]) {
        var names = Set<String>()
        for item in found {
            if let name = item.metadata.customLabel {
                names.insert(name)
            }
        }
        remember(Array(names))
    }

    private func remember(_ names: [String]) {
        let new = Set(names).subtracting(customLabels)
        guard !new.isEmpty else { return }
        customLabels = (customLabels + new).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

// MARK: - Changes

/// What a culling action asks for, before it's worked out for each photo it reaches.
public enum CullingChange: Sendable, Hashable {
    case rating(Int)
    /// `]` and `[`: each photo's own rating, one up or down.
    case ratingStep(Int)
    case flag(PhotoFlag?)
    /// P and X: the flag on every photo, or on none when every one has it.
    case toggleFlag(PhotoFlag)
    /// A colour, or none: a custom label goes too.
    case label(ColorLabel?)
    /// 6 to 9 and purple: the colour on every photo, or on none when every one has it.
    case toggleLabel(ColorLabel)
    /// A custom label by its name, as a colour toggles.
    case toggleCustomLabel(String)
    /// B: every photo marked, or none when every one is.
    case toggleMark
    case mark(Bool)

    /// The change an action's key makes; nil for actions that aren't culling.
    init?(_ action: ShortcutAction) {
        switch action {
        case .rating0: self = .rating(0)
        case .rating1: self = .rating(1)
        case .rating2: self = .rating(2)
        case .rating3: self = .rating(3)
        case .rating4: self = .rating(4)
        case .rating5: self = .rating(5)
        case .decreaseRating: self = .ratingStep(-1)
        case .increaseRating: self = .ratingStep(1)
        case .flagPick: self = .toggleFlag(.pick)
        case .flagReject: self = .toggleFlag(.reject)
        case .unflag: self = .flag(nil)
        case .labelRed: self = .toggleLabel(.red)
        case .labelYellow: self = .toggleLabel(.yellow)
        case .labelGreen: self = .toggleLabel(.green)
        case .labelBlue: self = .toggleLabel(.blue)
        case .labelPurple: self = .toggleLabel(.purple)
        case .clearLabel: self = .label(nil)
        case .toggleMark: self = .toggleMark
        default: return nil
        }
    }

    var field: CullingField {
        switch self {
        case .rating, .ratingStep: .rating
        case .flag, .toggleFlag: .flag
        case .label, .toggleLabel, .toggleCustomLabel: .label
        case .toggleMark, .mark: .mark
        }
    }

    /// `Rating`, `Red Label`, `Label “Urgent”`, as Undo and the activity log name it.
    var title: String {
        switch self {
        case let .rating(stars): stars == 0 ? "Clear Rating" : stars == 1 ? "1 Star" : "\(stars) Stars"
        case let .ratingStep(step): step > 0 ? "Increase Rating" : "Decrease Rating"
        case .flag(nil): "Unflag"
        case .flag(.pick), .toggleFlag(.pick): "Flag as Pick"
        case .flag(.reject), .toggleFlag(.reject): "Flag as Rejected"
        case let .label(label): label.map { "\($0.rawValue.capitalized) Label" } ?? "No Label"
        case let .toggleLabel(label): "\(label.rawValue.capitalized) Label"
        case let .toggleCustomLabel(name): "Label “\(name)”"
        case .toggleMark: "Mark / Unmark"
        case let .mark(marked): marked ? "Mark" : "Unmark"
        }
    }

    /// What each photo's culling fields become, from what they are.
    func resolved(_ photos: [CullingValues]) -> [CullingValues] {
        switch self {
        case let .rating(stars):
            return photos.map { var photo = $0; photo.rating = min(max(stars, 0), 5); return photo }
        case let .ratingStep(step):
            return photos.map { var photo = $0; photo.rating = min(max(photo.rating + step, 0), 5); return photo }
        case let .flag(flag):
            return photos.map { var photo = $0; photo.flag = flag; return photo }
        case let .toggleFlag(flag):
            let every = photos.allSatisfy { $0.flag == flag }
            return Self.flag(every ? nil : flag).resolved(photos)
        case let .label(label):
            return photos.map { var photo = $0; photo.label = label; photo.customLabel = nil; return photo }
        case let .toggleLabel(label):
            let every = photos.allSatisfy { $0.label == label }
            return Self.label(every ? nil : label).resolved(photos)
        case let .toggleCustomLabel(name):
            let every = photos.allSatisfy { $0.label == nil && $0.customLabel == name }
            return photos.map { photo in
                var photo = photo
                photo.label = nil
                photo.customLabel = every ? nil : name
                return photo
            }
        case .toggleMark:
            return Self.mark(!photos.allSatisfy(\.mark)).resolved(photos)
        case let .mark(marked):
            return photos.map { var photo = $0; photo.mark = marked; return photo }
        }
    }
}

/// The fields culling changes, one a change: a label and a custom label are one field.
enum CullingField: CaseIterable, Sendable {
    case rating, flag, label, mark
}

/// A photo's culling fields as its badges show them.
struct CullingValues: Hashable, Sendable {
    var rating = 0
    var flag: PhotoFlag?
    var label: ColorLabel?
    var customLabel: String?
    var mark = false

    init(_ metadata: PhotoMetadata) {
        rating = metadata.rating
        flag = metadata.flag
        label = metadata.label
        customLabel = metadata.label == nil ? metadata.customLabel : nil
        mark = metadata.mark
    }

    func matches(_ other: CullingValues, in field: CullingField) -> Bool {
        switch field {
        case .rating: rating == other.rating
        case .flag: flag == other.flag
        case .label: label == other.label && customLabel == other.customLabel
        case .mark: mark == other.mark
        }
    }

    /// `metadata` with `field` as these values have it.
    func apply(_ field: CullingField, to metadata: inout PhotoMetadata) {
        switch field {
        case .rating: metadata.rating = rating
        case .flag: metadata.flag = flag
        case .label:
            metadata.label = label
            metadata.customLabel = customLabel
        case .mark: metadata.mark = mark
        }
    }

    /// `apply`, for a sidecar's metadata as it is on disk when it's saved.
    func setting(_ field: CullingField) -> @Sendable (inout PhotoMetadata) -> Void {
        let values = self
        return { values.apply(field, to: &$0) }
    }

    /// What the library gives a photo for `field` to be as these values have it.
    func fields(_ field: CullingField) -> [MetadataField] {
        switch field {
        case .rating: [.rating(rating)]
        case .flag: [.flag(flag)]
        case .label: [customLabel.map { .namedLabel($0) } ?? .label(label)]
        case .mark: [.mark(mark)]
        }
    }
}

/// One of the Library's culling changes, as Undo takes it back and Redo makes it again.
@MainActor
final class CullingStep {
    let title: String
    let field: CullingField
    let photos: [URL]
    /// Each photo's fields before the change and after it.
    let before: [CullingValues]
    let after: [CullingValues]
    /// The library's batches that made it last, for its Undo, and its photos' IDs in the index.
    var batches: [UUID] = []
    var ids: [Int64: URL] = [:]
    /// The photos (by place) their own saves wrote: those the library hasn't indexed, and the one Develop
    /// had open.
    var saved: [Int] = []

    init(title: String, field: CullingField, photos: [URL], before: [CullingValues], after: [CullingValues]) {
        self.title = title
        self.field = field
        self.photos = photos
        self.before = before
        self.after = after
    }
}

/// The culling changes asked for and not yet made, in the order they were asked for. Lists hear of the
/// photos a batch put in the index only once no change asked for after it is still to come.
final class CullingQueue: Sendable {
    private let state = Mutex(State())

    private struct State {
        var requested: UInt64 = 0
        var pending: [UInt64: [URL]] = [:]
        /// Photos in the index whose lists haven't heard of them, waiting for the latest change.
        var deferred = Set<Int64>()
    }

    /// A change asked for, of `photos`: its number.
    func request(_ photos: [URL]) -> UInt64 {
        state.withLock { state in
            state.requested += 1
            state.pending[state.requested] = photos
            return state.requested
        }
    }

    /// The index holds change `sequence`'s `photos`: those the lists hear of now, with any held back, or none
    /// while a change asked for after it is to come.
    func indexed(_ photos: [Int64], by sequence: UInt64) -> [Int64] {
        state.withLock { state in
            state.deferred.formUnion(photos)
            guard sequence == state.requested else { return [] }
            defer { state.deferred = [] }
            return Array(state.deferred)
        }
    }

    /// Change `sequence` is made: the photos held back for it that the lists hear of now.
    func finished(_ sequence: UInt64) -> [Int64] {
        state.withLock { state in
            state.pending[sequence] = nil
            guard sequence == state.requested, !state.deferred.isEmpty else { return [] }
            defer { state.deferred = [] }
            return Array(state.deferred)
        }
    }

    var isIdle: Bool {
        state.withLock { $0.pending.isEmpty }
    }

    /// The photos changes asked for after `sequence` change.
    func changedLater(than sequence: UInt64) -> Set<URL> {
        state.withLock { state in
            state.pending.filter { $0.key > sequence }.values.reduce(into: Set<URL>()) { $0.formUnion($1) }
        }
    }
}

/// The culling values shown while the library's lists catch up with them: a list's update reads the index
/// some 100 ms after a batch, when a later change may already show. Each change is kept until a while after
/// it's made, its photos' values taking the place of older ones.
struct CullingOverlay {
    struct Change {
        let sequence: UInt64
        let field: CullingField
        let photos: [URL]
        let values: [CullingValues]
        var finished: ContinuousClock.Instant?
    }

    /// How long a change made stays shown, for the lists to catch up with it.
    static let kept = Duration.seconds(2)

    private var changes: [Change] = []
    private var cached: [URL: (values: CullingValues, fields: Set<CullingField>)]?
    /// Culling is showing a change itself.
    var publishing = false
    var isFixing = false

    var isEmpty: Bool {
        changes.isEmpty
    }

    mutating func add(_ change: Change) {
        changes.append(change)
        cached = nil
    }

    mutating func finished(_ sequence: UInt64) {
        for index in changes.indices where changes[index].sequence == sequence {
            changes[index].finished = .now
        }
    }

    /// The change didn't reach the library, which shows what the sidecars hold.
    mutating func drop(_ sequence: UInt64) {
        changes.removeAll { $0.sequence == sequence }
        cached = nil
    }

    mutating func expire() {
        let now = ContinuousClock.now
        let count = changes.count
        changes.removeAll { change in change.finished.map { now - $0 > Self.kept } ?? false }
        if changes.count != count {
            cached = nil
        }
    }

    /// Each photo's latest values, with the fields they're for.
    mutating func latest() -> [URL: (values: CullingValues, fields: Set<CullingField>)] {
        if let cached {
            return cached
        }
        var latest: [URL: (values: CullingValues, fields: Set<CullingField>)] = [:]
        for change in changes {
            for (place, url) in change.photos.enumerated() {
                var entry = latest[url] ?? (change.values[place], [])
                change.values[place].apply(change.field, to: &entry.values)
                entry.fields.insert(change.field)
                latest[url] = entry
            }
        }
        cached = latest
        return latest
    }
}

extension CullingValues {
    /// These values with `field` as `other` has it.
    func apply(_ field: CullingField, to other: inout CullingValues) {
        switch field {
        case .rating: other.rating = rating
        case .flag: other.flag = flag
        case .label:
            other.label = label
            other.customLabel = customLabel
        case .mark: other.mark = mark
        }
    }
}

extension FolderLibrary {
    /// Changes the badges of the photos in `rows` as one change; `change` hears each photo's place in `rows`.
    func updateMetadata(_ rows: [Int], _ change: (Int, inout PhotoMetadata) -> Void) {
        var updated = IndexSet()
        for (place, row) in rows.enumerated() where items.indices.contains(row) {
            let before = items[row].metadata
            change(place, &items[row].metadata)
            if items[row].metadata != before {
                updated.insert(row)
            }
        }
        if !updated.isEmpty {
            publish(LibraryDiff(updated: updated))
        }
    }
}
