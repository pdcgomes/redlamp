import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// Culling (LIB-15): ratings, flags, colour labels, custom labels and marks.
///
/// - **In Library** each change reaches the whole selection (or the photo clicked, when it isn't in it), as
///   one change with Undo and Redo. It's shown at once in the grid, the filmstrip and the loupe, then made in
///   the background: as one of the library's batches (`LibraryMetadata`) for the photos it has indexed, the
///   photo Develop has open among them, each photo given its own values, and through the photos' own saves
///   for the rest. Redo is the Undo of the Undo where the journal still has it. Undo and Redo take turns with
///   the library's other changes in the order they were made (`EditorModel+LibraryUndo`). A photo whose
///   sidecar the library can't read or write is reported in the activity log and shown as the library has it.
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
            return libraryUndoKind == .culling && undoCulling()
        case .redo where module == .library:
            return libraryRedoKind == .culling && redoCulling()
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
        case .undo where module == .library: libraryUndoKind == .culling
        case .redo where module == .library: libraryRedoKind == .culling
        default: CullingChange(action) == nil ? nil : canCull
        }
    }

    /// Whether a culling change reaches a photo now: in Library one listed, the selection's or the active one; in
    /// Develop the active photo, or the one opening.
    private var canCull: Bool {
        guard module == .library else { return (opening ?? selection) != nil }
        return library.count > 0 && (!photoSelection.isEmpty || selection.flatMap(library.index(of:)) != nil)
    }

    /// Makes `change`: in Library on the selection, in Develop on the active photo, or the one opening;
    /// `advance` then makes the photo after them active, in the grid's order (`GridOrder`): past closed groups,
    /// and from cell to cell among stacks. False when it reaches no photo: in Library, none listed.
    @discardableResult
    func cull(_ change: CullingChange, advance: Bool = false) -> Bool {
        guard let active = opening ?? selection else { return false }
        var culled: [Int64] = []
        if module == .library {
            let rows = selectedRows
            guard !rows.isEmpty else { return false }
            if advance {
                let ids = library.photoIDs
                culled = rows.compactMap { ids.indices.contains($0) ? ids[$0] : nil }
            }
            cull(change, rows: rows)
        } else {
            culled = library.photoID(of: active).map { [$0] } ?? []
            cullActivePhoto(change)
        }
        if advance, let next = gridOrder.cell(after: culled), let url = library.url(ofPhoto: next) {
            select(url)
            coverClosedStacks()
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

    /// The rows of the photos selected, in order; the active photo's alone when nothing else is selected. The
    /// selection is read once: each read is an observed access, and the menus' checks follow what they read.
    internal var selectedRows: [Int] {
        let selected = photoSelection
        guard !selected.isEmpty else { return selection.flatMap(library.index(of:)).map { [$0] } ?? [] }
        let ids = library.photoIDs
        var rows: [Int] = []
        rows.reserveCapacity(selected.count)
        for row in ids.indices where selected.contains(ids[row]) {
            rows.append(row)
        }
        return rows
    }

    // MARK: - Undo and Redo

    /// Takes back the Library's last culling change: each photo that still shows what it gave goes back.
    @discardableResult
    func undoCulling() -> Bool {
        guard module == .library, let step = cullingUndo.popLast() else { return false }
        step.turn = nextLibraryTurn()
        cullingRedo.append(step)
        let shown = find(step) { shown, place in
            shown.matches(step.after[place], in: step.field) ? step.before[place] : nil
        }
        let sequence = cullingQueue.request(step.photos)
        show(shown.values, field: step.field, rows: shown.rows, photoIDs: shown.photoIDs, sequence: sequence)
        make(step, sequence: sequence, as: .undo)
        activity.record(.action, "Undo \(step.title)")
        return true
    }

    /// Makes again the culling change Undo took back last: each photo that still shows what it had before it
    /// gets it again.
    @discardableResult
    func redoCulling() -> Bool {
        guard module == .library, let step = cullingRedo.popLast() else { return false }
        step.turn = nextLibraryTurn()
        cullingUndo.append(step)
        let shown = find(step) { shown, place in
            shown.matches(step.before[place], in: step.field) ? step.after[place] : nil
        }
        let sequence = cullingQueue.request(step.photos)
        show(shown.values, field: step.field, rows: shown.rows, photoIDs: shown.photoIDs, sequence: sequence)
        make(step, sequence: sequence, as: .redo)
        activity.record(.action, "Redo \(step.title)")
        return true
    }

    /// The rows `step`'s photos are listed at now, with their IDs and the values `value` gives each from what
    /// it shows; those it gives none, and those no longer listed, are left out. A photo that moved is looked for
    /// by its ID, then by its URL: a selection of thousands is found again within a frame. A large source's rows not
    /// read aren't shown, and show the library's values once they're read.
    private func find(
        _ step: CullingStep, _ value: (CullingValues, Int) -> CullingValues?,
    ) -> (rows: [Int], photoIDs: [Int64], values: [CullingValues]) {
        let items = library.items
        let ids = library.photoIDs
        let list = library.photoList
        var found: (rows: [Int], photoIDs: [Int64], values: [CullingValues]) = ([], [], [])
        for place in step.photos.indices {
            var row = step.rows[place]
            if !ids.indices.contains(row) || ids[row] != step.photoIDs[place] {
                guard let moved = list.index(of: step.photoIDs[place]) ?? library.index(of: step.photos[place])
                else { continue }
                row = moved
            }
            guard let item = items.row(row), let value = value(CullingValues(item.metadata), place) else { continue }
            found.rows.append(row)
            found.photoIDs.append(ids[row])
            found.values.append(value)
        }
        return found
    }

    // MARK: - Making a change

    /// Gives the photos of `rows` (places in `items`) what `change` asks for, as one change with Undo: shown
    /// at once, then made in the background. A read-only photo open in Develop is left as it is.
    internal func cull(_ change: CullingChange, rows: [Int]) {
        // A large source's photos whose rows aren't read are read first, and found again by their IDs.
        let ids = library.photoIDs
        let unread = rows.filter { ids.indices.contains($0) && library.items.row($0) == nil }.map { ids[$0] }
        guard unread.isEmpty else {
            let photos = rows.filter(ids.indices.contains).map { ids[$0] }
            return library.whenRead(unread) { [weak self] in
                guard let self else { return }
                let list = library.photoList
                cull(change, rows: photos.compactMap(list.index(of:)))
            }
        }
        guard let step = cullingStep(change, rows: rows) else { return }
        let sequence = cullingQueue.request(step.photos)
        show(step.after, field: change.field, rows: step.rows, photoIDs: step.photoIDs, sequence: sequence)
        step.turn = nextLibraryTurn()
        cullingUndo.append(step)
        endLibraryRedo()
        var labels: Set<String> = []
        for values in step.after {
            if let label = values.customLabel {
                labels.insert(label)
            }
        }
        remember(Array(labels))
        make(step, sequence: sequence, as: .change)
    }

    /// Nothing culling took back is made again.
    internal func dropCullingRedo() {
        guard !cullingRedo.isEmpty else { return }
        let freed = DroppedSteps(cullingRedo)
        cullingRedo = []
        release(freed)
    }

    /// Lets go of the `count` oldest culling changes on Undo, as Library's one limit asks (`EditorModel+LibraryUndo`).
    internal func dropOldestCulling(_ count: Int) {
        let freed = DroppedSteps(Array(cullingUndo.prefix(count)))
        cullingUndo.removeFirst(min(count, cullingUndo.count))
        release(freed)
    }

    /// Lets go of `freed`'s steps in the background, `freed` holding the last reference to them.
    private func release(_ freed: DroppedSteps) {
        library.scheduler.submit(.background) { freed.steps = [] }
    }

    /// What `change` makes of the photos of `rows` that it changes, or nil when it changes none. It reads the
    /// library's photos and lets go of them before they change: holding them would copy them all. Loops rather
    /// than closures: a closure formed here checks it's on the main actor each time it's called, a photo at a
    /// time.
    private func cullingStep(_ change: CullingChange, rows: [Int]) -> CullingStep? {
        let items = library.items
        let ids = library.photoIDs
        let readOnly = isReadOnly ? selection.flatMap(library.index(of:)) : nil
        var shown: [Int] = []
        var current: [CullingValues] = []
        shown.reserveCapacity(rows.count)
        current.reserveCapacity(rows.count)
        for row in rows where items.indices.contains(row) && row != readOnly {
            shown.append(row)
            current.append(CullingValues(items[row].metadata))
        }
        let wanted = change.resolved(current)
        var changed: [Int] = []
        var photoIDs: [Int64] = []
        var photos: [URL] = []
        var before: [CullingValues] = []
        var after: [CullingValues] = []
        changed.reserveCapacity(shown.count)
        photoIDs.reserveCapacity(shown.count)
        photos.reserveCapacity(shown.count)
        before.reserveCapacity(shown.count)
        after.reserveCapacity(shown.count)
        for place in shown.indices where !wanted[place].matches(current[place], in: change.field) {
            let row = shown[place]
            changed.append(row)
            photoIDs.append(ids[row])
            photos.append(items[row].url)
            before.append(current[place])
            after.append(wanted[place])
        }
        guard !changed.isEmpty else { return nil }
        return CullingStep(
            title: change.title, field: change.field, photos: photos, rows: changed, photoIDs: photoIDs,
            before: before, after: after,
        )
    }

    /// Shows `values` (one for each of `rows`, the places of the photos of `photoIDs`) in the photos' badges
    /// as one change, and in the active photo's metadata when it's among them; kept shown as change
    /// `sequence` until the library's lists have caught up with it.
    private func show(
        _ values: [CullingValues], field: CullingField, rows: [Int], photoIDs: [Int64], sequence: UInt64,
    ) {
        cullingOverlay.add(CullingOverlay.Change(sequence: sequence, field: field, photos: photoIDs, values: values))
        // Develop's open photo: what it hasn't saved is saved first, and from then on its saves count the
        // change as another writer's, so they never write it over the batch's.
        let open = info != nil && !isReadOnly && selection.flatMap(library.index(of:)).map(rows.contains) == true
        if open {
            saveNow()
        }
        if !rows.isEmpty {
            cullingOverlay.publishing = true
            library.setMetadata(rows) { place, metadata in values[place].apply(field, to: &metadata) }
            cullingOverlay.publishing = false
            if let active = selection.flatMap(library.index(of:)), let place = rows.firstIndex(of: active) {
                values[place].apply(field, to: &photoMetadata)
            }
        }
        if open, let selection {
            saves.enqueue(.track(nil, opened: sidecarToSave), for: selection)
        }
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

    /// What a culling step's background work makes of it.
    private enum Making {
        case change, undo, redo
    }

    /// Makes `step` in the background, after the changes asked for before it: its values, or takes them
    /// back, or makes them again.
    private func make(_ step: CullingStep, sequence: UInt64, as making: Making) {
        let previous = cullingTail
        cullingTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            switch making {
            case .change: await write(step, sequence: sequence, redoing: false)
            case .undo: await takeBack(step, sequence: sequence)
            case .redo: await write(step, sequence: sequence, redoing: true)
            }
            library.service?.photosChanged(cullingQueue.finished(sequence))
            cullingOverlay.finished(sequence)
            if step.field == .label {
                refreshCustomLabels()
            }
        }
    }

    /// Writes the step's values: through the library for the photos it has indexed, as one batch, and
    /// through the others' own saves. With `redoing`, the library takes back the Undo that took them back
    /// when its journal still has it, and makes a new batch when it doesn't.
    private func write(_ step: CullingStep, sequence: UInt64, redoing: Bool) async {
        let field = step.field
        var written = CullingWritten()
        if let service = library.service, service.isReady {
            await waitForSaves(of: step.photos)
            if redoing, !step.undos.isEmpty,
               let redone = await service.redoCulling(
                   step.undos,
                   photos: step.ids,
                   sequence: sequence,
                   queue: cullingQueue,
               ) {
                written = redone
                written.unindexed = step.saved.map { step.photos[$0] }
            } else {
                written = await service.cull(
                    step.photos, fields: step.after.map { $0.fields(field) }, sequence: sequence, queue: cullingQueue,
                )
                step.ids = written.ids
            }
        } else {
            written.unindexed = step.photos
        }
        step.batches = written.batches
        step.undos = []
        let unindexed = Set(written.unindexed)
        step.saved = step.photos.indices.filter { unindexed.contains(step.photos[$0]) }
        let held = step.held
        await save(step.saved.map { place in
            let (url, before, after) = (step.photos[place], step.before[place], step.after[place])
            return (url, { @Sendable (metadata: inout PhotoMetadata) in
                let current = CullingValues(metadata)
                guard !redoing || current.matches(held.value(for: url) ?? before, in: field) else { return }
                held.keep(current, for: url)
                after.apply(field, to: &metadata)
            })
        })
        await finish(
            written, of: step, title: redoing ? "Redo \(step.title)" : step.title, undoing: false, sequence: sequence,
        )
    }

    /// Takes the step back: its batches through the library, which keeps their Undos for Redo, and its other
    /// photos through their own saves, each field that still holds what the step gave it.
    private func takeBack(_ step: CullingStep, sequence: UInt64) async {
        let field = step.field
        var written = CullingWritten()
        if !step.batches.isEmpty, let service = library.service, service.isReady {
            await waitForSaves(of: step.photos)
            written = await service.undoCulling(step.batches, photos: step.ids, sequence: sequence, queue: cullingQueue)
        }
        step.undos = written.batches
        step.batches = []
        let held = step.held
        await save(step.saved.map { place in
            let (url, before, after) = (step.photos[place], step.before[place], step.after[place])
            return (url, { @Sendable (metadata: inout PhotoMetadata) in
                if CullingValues(metadata).matches(after, in: field) {
                    (held.value(for: url) ?? before).apply(field, to: &metadata)
                }
            })
        })
        await finish(written, of: step, title: "Undo \(step.title)", undoing: true, sequence: sequence)
    }

    /// Returns once the saves asked for any of `photos` before the call are on disk, so a batch reads their
    /// sidecars as those saves leave them.
    private func waitForSaves(of photos: [URL]) async {
        let saves = saves
        for photo in await Task.detached(priority: .userInitiated, operation: { saves.pending(photos) }).value {
            await saves.wait(for: photo)
        }
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

    /// What's left once the library has made its part of a step (`title`, as Undo names it): the photos it
    /// couldn't write are reported, and show what the library has of them, from their rows (a sidecar it
    /// couldn't read can't say), unless a change asked for after it changes them again.
    private func finish(
        _ written: CullingWritten, of step: CullingStep, title: String, undoing: Bool, sequence: UInt64,
    ) async {
        for error in written.errors {
            activity.record(.error, "\(title) wasn't saved to every photo: \(error)")
        }
        report(written.reasons, of: step, title: title, undoing: undoing)
        guard !written.unwritten.isEmpty else { return }
        let later = cullingQueue.changedLater(than: sequence)
        let unwritten = written.unwritten.filter { !later.contains($0) }
        guard !unwritten.isEmpty else { return }
        cullingOverlay.drop(sequence)
        var badges = await library.service?.badges(of: unwritten) ?? [:]
        let rest = unwritten.filter { badges[$0] == nil }
        let sidecars = library.sidecars
        for (url, metadata) in await Task.detached(priority: .userInitiated, operation: {
            rest.map { ($0, sidecars.store(for: $0).summary(for: $0)?.metadata ?? PhotoMetadata()) }
        }).value {
            badges[url] = metadata
        }
        let shown = cullingQueue.changedLater(than: sequence)
        var rows: [Int] = []
        var values: [CullingValues] = []
        for url in unwritten where !shown.contains(url) {
            guard let row = library.index(of: url), let metadata = badges[url] else { continue }
            rows.append(row)
            values.append(CullingValues(metadata))
        }
        show(values, fields: CullingField.allCases, rows: rows)
    }

    /// Says in the activity log which of the step's photos the library couldn't write, and why: "Undo 3 Stars
    /// couldn't put back Photo C: its sidecar can't be read".
    private func report(_ reasons: [URL: String], of step: CullingStep, title: String, undoing: Bool) {
        let photos = reasons.isEmpty ? [] : step.photos.filter { reasons[$0] != nil }
        guard !photos.isEmpty else { return }
        let named = photos.prefix(3).map(activity.alias(for:))
        let who = switch photos.count {
        case 1: named[0]
        case 2, 3: named.dropLast().joined(separator: ", ") + " and " + (named.last ?? "")
        default: "\(photos.count) photos (\(named.joined(separator: ", ")) and \(photos.count - named.count) more)"
        }
        let why = Set(reasons.values).sorted().joined(separator: "; ")
        activity.record(
            .error,
            undoing ? "\(title) couldn't put back \(who): \(why)" : "\(title) wasn't saved to \(who): \(why)",
        )
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
        forgetCulling(url)
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

    /// Develop changed `url` itself, or a save showed what's on disk: no culling change stands over it.
    internal func forgetCulling(_ url: URL) {
        guard !cullingOverlay.isEmpty, let id = library.photoID(of: url) else { return }
        cullingOverlay.forget(id)
    }

    /// A list's update, or a save's report, is about to show photos as they were before a culling change the
    /// library hasn't caught up with: their rows show the change instead, before anyone is told of them.
    internal func keepCullingShown(_ diff: LibraryDiff) {
        guard !cullingOverlay.publishing, !cullingOverlay.isEmpty, !diff.isEmpty else { return }
        cullingOverlay.expire()
        let latest = cullingOverlay.latest()
        guard !latest.isEmpty else { return }
        let rows = diff.reset ? IndexSet(items.indices) : diff.updated.union(diff.inserted).union(diff.read)
        let ids = library.photoIDs
        // The photos shown with a change, when they're fewer than the rows: a million rows reset otherwise.
        let list = library.photoList
        let reached = latest.count < rows.count
            ? latest.keys.compactMap(list.index(of:)).filter(rows.contains).sorted() : Array(rows)
        for row in reached where library.items.indices.contains(row) && ids.indices.contains(row) {
            guard let shown = latest[ids[row]], let item = library.items.row(row) else { continue }
            let current = CullingValues(item.metadata)
            for field in shown.fields where !current.matches(shown.values, in: field) {
                shown.values.apply(field, to: &library.items[row].metadata)
            }
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

    /// Reads the library's custom labels and their counts again, once the read under way is done: when
    /// other photos are shown, and after a change to labels.
    internal func refreshCustomLabels() {
        guard let service = library.service, service.isReady else { return }
        guard customLabelsReading == nil else {
            customLabelsStale = true
            return
        }
        customLabelsReading = Task { [weak self] in
            let counts = await service.customLabels()
            guard let self else { return }
            customLabelCounts = counts
            remember(counts.map(\.name))
            customLabelsReading = nil
            if customLabelsStale {
                customLabelsStale = false
                refreshCustomLabels()
            }
        }
    }

    private func remember(_ names: [String]) {
        let new = Set(names).subtracting(customLabels)
        guard !new.isEmpty else { return }
        customLabels = (customLabels + new).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// One of the Library's culling changes, as Undo takes it back and Redo makes it again.
@MainActor
final class CullingStep {
    let title: String
    let field: CullingField
    let photos: [URL]
    /// Where the photos were listed when it was made, and their IDs there.
    let rows: [Int]
    let photoIDs: [Int64]
    /// Each photo's fields before the change and after it.
    let before: [CullingValues]
    let after: [CullingValues]
    /// The library's batches that made it last, for its Undo, and its photos' IDs in the index.
    var batches: [UUID] = []
    var ids: [Int64: URL] = [:]
    /// The Undos that took those batches back, for Redo to take back in turn.
    var undos: [UUID] = []
    /// The photos (by place) their own saves write: those the library hadn't indexed.
    var saved: [Int] = []
    /// What their sidecars held before it, which Undo puts back: the grid may have shown other apps' values.
    let held = CullingHeld()
    /// Its turn in Library's Undo and Redo (`EditorModel+LibraryUndo`).
    var turn = 0

    init(
        title: String, field: CullingField, photos: [URL], rows: [Int], photoIDs: [Int64],
        before: [CullingValues], after: [CullingValues],
    ) {
        self.title = title
        self.field = field
        self.photos = photos
        self.rows = rows
        self.photoIDs = photoIDs
        self.before = before
        self.after = after
    }
}

/// The steps a change drops from Undo and Redo, freed in the background: a step of a whole selection holds
/// thousands of URLs, which take milliseconds to free. Only the background job lets go of them, so the main
/// thread is never the last to.
private final class DroppedSteps: @unchecked Sendable {
    var steps: [CullingStep]

    init(_ steps: [CullingStep]) {
        self.steps = steps
    }
}

/// What photos' sidecars held before a culling change their own saves made, as each save found them.
final class CullingHeld: Sendable {
    private let values = Mutex<[URL: CullingValues]>([:])

    /// The first one found: a save tried again, or Redo's, finds the sidecar as the change or Undo left it.
    func keep(_ held: CullingValues, for url: URL) {
        values.withLock { values in
            if values[url] == nil {
                values[url] = held
            }
        }
    }

    func value(for url: URL) -> CullingValues? {
        values.withLock { $0[url] }
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
/// it's made, its photos' values taking the place of older ones. Photos are known by their IDs in the
/// library's list (`FolderLibrary.photoIDs`), as thousands of them are looked up within a frame.
struct CullingOverlay {
    struct Change {
        let sequence: UInt64
        let field: CullingField
        let photos: [Int64]
        let values: [CullingValues]
        var finished: ContinuousClock.Instant?
    }

    /// How long a change made stays shown, for the lists to catch up with it.
    static let kept = Duration.seconds(2)

    private var changes: [Change] = []
    private var cached: [Int64: (values: CullingValues, fields: Set<CullingField>)]?
    /// Culling is showing a change itself.
    var publishing = false

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

    /// Develop changed the photo itself, or a save showed what's on disk: no change of culling's stands over
    /// it.
    mutating func forget(_ photo: Int64) {
        guard !changes.isEmpty else { return }
        changes = changes.compactMap { change in
            guard let place = change.photos.firstIndex(of: photo) else { return change }
            var photos = change.photos
            var values = change.values
            photos.remove(at: place)
            values.remove(at: place)
            guard !photos.isEmpty else { return nil }
            return Change(
                sequence: change.sequence, field: change.field, photos: photos, values: values,
                finished: change.finished,
            )
        }
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
    mutating func latest() -> [Int64: (values: CullingValues, fields: Set<CullingField>)] {
        if let cached {
            return cached
        }
        var latest: [Int64: (values: CullingValues, fields: Set<CullingField>)] = [:]
        for change in changes {
            for (place, photo) in change.photos.enumerated() {
                var entry = latest[photo] ?? (change.values[place], [])
                change.values[place].apply(change.field, to: &entry.values)
                entry.fields.insert(change.field)
                latest[photo] = entry
            }
        }
        cached = latest
        return latest
    }
}

extension FolderLibrary {
    /// Changes the badges of the photos in `rows`, in order, as one change, each of which `change` changes:
    /// a pass over them in one mutation of `items`, for a selection of thousands. A large source's rows not read
    /// yet show the change once they are (`EditorModel.keepCullingShown`).
    func setMetadata(_ rows: [Int], _ change: (Int, inout PhotoMetadata) -> Void) {
        _ = items.changeMetadata(rows, comparing: false, change)
        publish(LibraryDiff(updated: IndexSet(rows: rows)))
    }

    /// Changes the badges of the photos in `rows` as one change; `change` hears each photo's place in `rows`.
    func updateMetadata(_ rows: [Int], _ change: (Int, inout PhotoMetadata) -> Void) {
        let updated = items.changeMetadata(rows, comparing: true, change)
        if !updated.isEmpty {
            publish(LibraryDiff(updated: IndexSet(rows: updated)))
        }
    }
}
