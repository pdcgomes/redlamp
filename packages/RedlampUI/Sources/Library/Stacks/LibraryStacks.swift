import Foundation
import Observation
import RedlampDesign
import RedlampLibrary

/// The Library's stacks (LIB-28), for the grid and the filmstrip: the source's photos with each raw and its
/// JPEG, each burst and each stack made by hand shown as one cell with its count until it's opened
/// (`StackedList`), as the library finds them in its index (`LibraryStackFinder`), over the app's own photo
/// IDs (`FolderLibrary.photoIDs`), so the grid's selection is `EditorModel.photoSelection`.
///
/// Stacks are found off the main thread when the photos come or go and when a stack is made or taken apart,
/// one stacking at a time, the stacks open before open after. A stack opens or closes on the main thread in
/// microseconds, with a diff of the cells, in the grid's groups too (`LibraryGroups`). A closed stack's cell
/// selects all of its photos (`EditorModel.coverClosedStacks`), so culling, keywords, drags and moves reach
/// every photo it stands for and nothing out of sight is selected alone.
@MainActor
@Observable
@_spi(Harness) public final class LibraryStacks {
    /// What changed in the list's cells, for the views that follow them.
    @_spi(Harness) public enum Change: Equatable {
        /// Stacked afresh: photos came or went, stacks were made or taken apart, or the source shows stacks for
        /// the first time or no longer.
        case restacked
        /// Stacks opened or closed: the cells changed as the diff says.
        case items(PhotoListDiff)
    }

    /// The stacks as the menus and the palette follow them, the list itself not being observed. Nothing here changes
    /// as a stack opens or closes: SwiftUI makes the whole menu bar again for each change.
    @_spi(Harness) public struct Outline: Equatable {
        /// Counts the stackings shown.
        @_spi(Harness) public internal(set) var stackings = 0
        /// Whether the list shows a stack, open or closed.
        @_spi(Harness) public internal(set) var hasStacks = false
    }

    @ObservationIgnored private weak var model: EditorModel?
    /// The source's photos with their stacks; nil without the library, while the source has no stack, and until
    /// its stacks are first found.
    @ObservationIgnored @_spi(Harness) public private(set) var list: StackedList?
    @_spi(Harness) public private(set) var outline = Outline()
    /// Whether the stacks a list gains come open: after Open All Stacks, until Close All Stacks.
    @ObservationIgnored private(set) var opensNew = false
    /// Counts the list's changes, for a grouping made meanwhile to open its stacks as the list has them.
    @ObservationIgnored private(set) var openings = 0
    @ObservationIgnored let finder = LibraryStackFinder()
    /// Each photo's ID in the index, by its ID here, as the stackings found them.
    @ObservationIgnored private(set) var indexIDs: [Int64: Int64] = [:]
    @ObservationIgnored private var observers: [UUID: @MainActor (Change) -> Void] = [:]
    @ObservationIgnored private var observation: LibraryObservation?
    @ObservationIgnored private var indexing: LibraryObservation?
    @ObservationIgnored private var selectionTracker: Tracker?
    @ObservationIgnored private var stacking = false
    @ObservationIgnored private var pending = false
    /// What the next stacking forgets first: the stacks found before, and their photos' names.
    @ObservationIgnored private var forgetting = (stacks: false, names: false)
    /// The stacking that follows badges' changes once they're quiet, for a stack changed in a sidecar by another
    /// Mac or app.
    @ObservationIgnored private var quiet: Task<Void, Never>?
    /// How long the last stacking took off the main thread, and how many have been made, for the measurements.
    @ObservationIgnored @_spi(Harness) public private(set) var lastStacking: Duration = .zero
    @ObservationIgnored @_spi(Harness) public private(set) var stackingsMade = 0

    /// How long badges' changes are quiet before the stacks are found again.
    static let quietPause = Duration.seconds(1)

    init(model: EditorModel) {
        self.model = model
        observation = model.library.observe { [weak self] diff in self?.libraryChanged(diff) }
        // The library indexed more photos, whose names stacks are found from; and a folder listed from the disk is
        // shown from the library once it's indexed, without a change when nothing differs.
        indexing = model.library.service?.observe { [weak self] in
            self?.restackWhenQuiet(names: true)
        }
        selectionTracker = Tracker { [weak model] in
            guard let model else { return }
            _ = (model.photoSelection, model.selection)
            model.coverClosedStacks()
        }
        restack()
    }

    /// Calls `handler` after every change, until the returned token is released.
    @_spi(Harness) public func observe(_ handler: @escaping @MainActor (Change) -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    // MARK: - Stacking

    /// Finds the source's stacks again, off the main thread, and shows them; `forgetting` the stacks found
    /// before, and their photos' names with `names`. Without the library, or for a source not shown from it,
    /// there are none.
    func restack(forgetting: Bool = false, names: Bool = false) {
        guard let model else { return }
        self.forgetting.stacks = self.forgetting.stacks || forgetting
        self.forgetting.names = self.forgetting.names || forgetting && names
        let library = model.library
        guard library.isShownFromLibrary, let core = library.service?.core else {
            pending = false
            if list != nil {
                show(nil, changed: true)
            }
            return
        }
        guard !stacking else {
            pending = true
            return
        }
        stacking = true
        pending = false
        let request = Request(
            items: library.items, ids: library.photoIDs, list: library.photoList, previous: list,
            opensNew: opensNew, finder: finder, photoIDs: model.libraryPanels.photoIDs, forgetting: self.forgetting,
        )
        self.forgetting = (false, false)
        // Detached, so the stacking starts at once rather than once the main thread has drawn what asked for it.
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = ContinuousClock.now
            let result = await Self.stack(request, index: core.index, engine: core.engine)
            await self?.stacked(result, for: request.list.source, since: started)
        }
    }

    private struct Request: Sendable {
        var items: [LibraryItem]
        var ids: ContiguousArray<Int64>
        var list: PhotoList
        var previous: StackedList?
        var opensNew: Bool
        var finder: LibraryStackFinder
        var photoIDs: PanelPhotoIDs
        var forgetting: (stacks: Bool, names: Bool)
    }

    private struct Result: Sendable {
        /// Nil when the list shows no stack.
        var list: StackedList?
        /// Whether its cells or their badges differ from the list it follows.
        var changed: Bool
        var indexIDs: [Int64: Int64]
    }

    /// The request's photos with the library's stacks, relabelled with the IDs here, the stacks open in the list
    /// before open in it.
    private nonisolated static func stack(_ request: Request, index: LibraryIndex, engine: QueryEngine) async
        -> Result? {
        let (items, ids) = (request.items, request.ids)
        guard items.count == ids.count else { return nil }
        if request.forgetting.stacks {
            await request.finder.forget(names: request.forgetting.names)
        }
        let photos = ids.indices.map { (list: ids[$0], url: items[$0].url) }
        let byOwn = await request.photoIDs.ids(of: photos, in: index)
        guard let found = await request.finder.stacks(in: index, engine: engine) else { return nil }
        var byIndex: [Int64: Int64] = [:]
        byIndex.reserveCapacity(byOwn.count)
        for (own, indexed) in byOwn {
            byIndex[indexed] = own
        }
        let stacks = found.relabelled(above: ids.max() ?? -1) { byIndex[$0] }
        var stacked: StackedList
        var changed = true
        if let previous = request.previous {
            var selection = StackSelection()
            let (updated, diff) = previous.updated(list: request.list, stacks: stacks, selection: &selection)
            (stacked, changed) = (updated, !diff.isEmpty)
        } else {
            stacked = StackedList(request.list, stacks: stacks)
        }
        if request.opensNew, stacked.stacksShown.closed > 0 {
            stacked.openAll()
            changed = true
        }
        let shown = stacked.stacksShown
        return Result(list: shown.open + shown.closed > 0 ? stacked : nil, changed: changed, indexIDs: byOwn)
    }

    private func stacked(_ result: Result?, for source: PhotoSource, since started: ContinuousClock.Instant) {
        stacking = false
        lastStacking = ContinuousClock.now - started
        stackingsMade += 1
        if let result, model?.library.photoList.source == source {
            indexIDs.merge(result.indexIDs) { _, new in new }
            show(result.list, changed: result.changed || (list == nil) != (result.list == nil))
        }
        if pending || model.map({ $0.library.photoList.source != source }) == true {
            restack()
        }
    }

    private func show(_ made: StackedList?, changed: Bool) {
        list = made
        guard changed else { return }
        self.changed(.restacked)
        model?.coverClosedStacks()
        model?.libraryViews.groups?.restacked()
    }

    private func changed(_ change: Change) {
        openings += 1
        var next = outline
        if change == .restacked {
            next.stackings += 1
        }
        let shown = list?.stacksShown ?? (open: 0, closed: 0)
        next.hasStacks = shown.open + shown.closed > 0
        if next != outline {
            outline = next
        }
        for observer in observers.values {
            observer(change)
        }
    }

    /// Photos that came or went are stacked again at once, with their names read again; badges' changes, once
    /// they've been quiet a moment, for a stack another Mac or app changed in a sidecar.
    private func libraryChanged(_ diff: LibraryDiff) {
        guard !diff.isEmpty else { return }
        guard !diff.reset, diff.removed.isEmpty, diff.inserted.isEmpty else {
            return restack(forgetting: true, names: true)
        }
        restackWhenQuiet()
    }

    /// Finds the stacks again once changes have been quiet a moment, with `names` their photos' names too.
    private func restackWhenQuiet(names: Bool = false) {
        forgetting.names = forgetting.names || names
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(for: Self.quietPause)
            guard !Task.isCancelled else { return }
            self?.restack(forgetting: true)
        }
    }

    // MARK: - Opening and closing

    /// Opens the closed stack whose first cell is `cell`: a burst or a stack made by hand, else a raw and its JPEG.
    @_spi(Harness) public func open(_ cell: Int64) {
        guard var stacked = list else { return }
        let diff = stacked.open(cell)
        guard !diff.isEmpty else { return }
        list = stacked
        changed(.items(diff))
        model?.libraryViews.groups?.openStack(cell, as: stacked)
    }

    /// Closes the open stack `cell` is in, a raw and its JPEG before the burst or stack made by hand holding them;
    /// when any of its photos was selected, all of them are, and the first is active when one of them was.
    @_spi(Harness) public func close(_ cell: Int64) {
        guard var stacked = list, let model else { return }
        let diff = stacked.close(cell)
        guard !diff.isEmpty else { return }
        list = stacked
        if let first = stacked.cell(for: cell) {
            model.keepSelected(stacked.photos(of: first), standingFor: first)
        }
        changed(.items(diff))
        model.libraryViews.groups?.closeStack(cell, as: stacked)
    }

    /// Opens every stack; the stacks the list gains come open until every one is closed again.
    @_spi(Harness) public func openAll() {
        opensNew = true
        guard var stacked = list, stacked.stacksShown.closed > 0 else { return }
        let diff = stacked.openAll()
        list = stacked
        changed(.items(diff))
        model?.libraryViews.groups?.openAllStacks()
    }

    /// Closes every stack, each selected whole when any of its photos was.
    @_spi(Harness) public func closeAll() {
        opensNew = false
        guard var stacked = list, let model, stacked.stacksShown.open > 0 else { return }
        let diff = stacked.closeAll()
        list = stacked
        model.coverClosedStacks(anyPhotoSelecting: true)
        changed(.items(diff))
        model.libraryViews.groups?.closeAllStacks()
    }

    /// Opens the outermost stack holding `photo` if it's closed, else closes it, as S does: a burst or a stack
    /// made by hand before a raw and its JPEG.
    @_spi(Harness) public func toggle(_ photo: Int64) {
        guard let stacked = list, let cell = stacked.cell(for: photo), let outer = stacked.shownStacks(of: cell).first
        else { return }
        guard outer.isOpen else { return open(outer.first) }
        closeWhole(outer, from: cell)
    }

    /// A click on a cell's badge: opens or closes the stack it's the first cell of, `pair` the raw and its JPEG
    /// shown there rather than the burst or stack made by hand.
    @_spi(Harness) public func toggle(badgeOf cell: Int64, pair: Bool) {
        guard let stacked = list, let shown = stacked.shownStacks(of: cell).first(where: { stack in
            (stack.kind == .pair) == pair && stack.first == cell
        }) else { return }
        guard shown.isOpen else { return open(cell) }
        closeWhole(shown, from: cell)
    }

    /// Closes `stack` from its cell `cell`, which a raw and its JPEG open inside it would close first.
    private func closeWhole(_ stack: (first: Int64, kind: Stack.Kind, isOpen: Bool), from cell: Int64) {
        for _ in 0 ..< 2 {
            close(cell)
            guard let shown = list?.shownStacks(of: cell),
                  shown.contains(where: { $0.first == stack.first && $0.kind == stack.kind && $0.isOpen })
            else { return }
        }
    }

    /// Whether `photo` has a cell of its own, or stands for a closed stack's photos.
    func isOnShow(_ photo: Int64) -> Bool {
        list?.isShown(photo) ?? true
    }
}

public extension EditorModel {
    /// The Library's stacks, made the first time they're asked for.
    @_spi(Harness) var gridStacks: LibraryStacks {
        if let stacks = libraryViews.stacks {
            return stacks
        }
        let stacks = LibraryStacks(model: self)
        libraryViews.stacks = stacks
        return stacks
    }
}
