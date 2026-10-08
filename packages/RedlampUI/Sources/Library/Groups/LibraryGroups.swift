import Foundation
import Observation
import RedlampDesign
import RedlampLibrary

/// The Library grid's groups (LIB-41): the source's photos under Group By's groups, as the library groups
/// them (`LibraryGrouping`), each group a header the grid opens and closes (`GroupedList`), over the app's
/// own photo IDs (`FolderLibrary.photoIDs`), so the grid's selection is `EditorModel.photoSelection`.
///
/// Grouping reads the column store, so it needs the source shown from the library. It's worked out off the
/// main thread when the photos, the key, the setting or the stacks change, one grouping at a time, the last
/// change grouped once the one before is in; a list grouped by the same key keeps what was open. A group opens
/// or closes on the main thread in microseconds, with a diff of the grid's items. A closed group's photos are
/// never selected, so nothing out of sight is acted on. Each header's picks are the photos' badges, as the
/// cells show them, ahead of the index while a culling change reaches it. Stacks (LIB-28) stay whole in the
/// group of the photo standing for them, closed inside it as the filmstrip has them (`LibraryStacks`).
@MainActor
@Observable
@_spi(Harness) public final class LibraryGroups {
    /// What changed in the grid's items, for the views that follow them.
    @_spi(Harness) public enum Change: Equatable {
        /// Grouped afresh: by another key or setting, or after the photos changed.
        case regrouped
        /// Groups opened or closed: the grid's items changed as the diff says.
        case items(PhotoListDiff)
        /// These groups' headers show other picks or names.
        case headers(IndexSet)
    }

    /// How many of the list's moments have no pick, while grouped by moment: the photos without a capture
    /// time count as one more moment, as `MomentCoverage` counts them.
    @_spi(Harness) public struct Coverage: Equatable, Sendable {
        @_spi(Harness) public var unpicked: Int
        @_spi(Harness) public var moments: Int
    }

    /// The groups as the menus and the palette follow them, the list itself not being observed: a new grouping,
    /// and the first group opened or the last closed, not every group's change.
    @_spi(Harness) public struct Outline: Equatable {
        /// Counts the groupings the list has had.
        var groupings = 0
        var someOpen = false
        var someClosed = false
    }

    @ObservationIgnored private weak var model: EditorModel?
    /// The source's photos in their groups; nil while ungrouped, without the library, and until the first
    /// grouping is in.
    @ObservationIgnored @_spi(Harness) public private(set) var list: GroupedList?
    @_spi(Harness) public private(set) var outline = Outline()
    /// Each group's picks, from the photos' badges.
    @ObservationIgnored @_spi(Harness) public private(set) var picks: [Int] = []
    @_spi(Harness) public private(set) var coverage: Coverage?
    /// Only the moments without a pick are open (`showUnpicked`).
    @_spi(Harness) public private(set) var showsUnpicked = false
    /// Whether groups the list gains come open: not after Close All Groups.
    @ObservationIgnored private var opensNew = true
    @ObservationIgnored private var observers: [UUID: @MainActor (Change) -> Void] = [:]
    @ObservationIgnored private var observation: LibraryObservation?
    @ObservationIgnored private var selectionTracker: AnyObject?
    @ObservationIgnored private var grouping = false
    /// The grouping that follows badges' changes once they're quiet.
    @ObservationIgnored private var quiet: Task<Void, Never>?
    @ObservationIgnored private var pending = false
    /// Each photo's ID in the index, by its ID here, for the source they were found for.
    @ObservationIgnored private var indexIDs: [Int64: Int64] = [:]
    @ObservationIgnored private var indexedSource: PhotoSource?
    /// The stacks' openings and closings counted when the grouping in progress took them.
    @ObservationIgnored private var stackOpenings = 0
    /// How long the last grouping took off the main thread, for `--library-perf`, and its parts: the photos'
    /// IDs in the index, the engine's grouping handed over, the groups made, and the list of them.
    @ObservationIgnored @_spi(Harness) public private(set) var lastGrouping: Duration = .zero
    @ObservationIgnored @_spi(Harness) public private(set) var lastGroupingParts: [Duration] = []
    /// How long the main thread took to show the last grouping, the views following it included.
    @ObservationIgnored @_spi(Harness) public private(set) var lastAdoption: Duration = .zero

    init(model: EditorModel) {
        self.model = model
        observation = model.library.observe { [weak self] diff in self?.libraryChanged(diff) }
        selectionTracker = Tracker { [weak self, weak model] in
            guard let model else { return }
            _ = model.selection
            self?.revealActivePhoto()
        }
        regroup()
    }

    /// Calls `handler` after every change, until the returned token is released.
    @_spi(Harness) public func observe(_ handler: @escaping @MainActor (Change) -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    /// What the grouping in progress or the next one is made of.
    private struct Grouping: Equatable, Sendable {
        var key: GroupKey
        var setting: MomentSetting
        var source: PhotoSource
    }

    private var wanted: Grouping? {
        guard let model else { return nil }
        let library = model.library
        let state = model.libraryViews
        guard state.groupKey != .ungrouped, library.isShownFromLibrary, library.service?.core != nil else {
            return nil
        }
        return Grouping(
            key: state.groupKey, setting: MomentSetting(looseness: state.looseness), source: library.photoList.source,
        )
    }

    // MARK: - Grouping

    /// Groups the source's photos again, off the main thread, as they are now; ungroups them when Group By is
    /// none or the source isn't shown from the library.
    func regroup() {
        guard let model, let wanted, let core = model.library.service?.core else {
            pending = false
            if list != nil {
                showsUnpicked = false
                set(nil)
            }
            return
        }
        guard !grouping else {
            pending = true
            return
        }
        grouping = true
        pending = false
        let library = model.library
        if wanted.source != indexedSource {
            indexIDs = [:]
            indexedSource = wanted.source
        }
        let stacks = model.gridStacks
        stackOpenings = stacks.openings
        let request = Request(
            items: library.items, ids: library.photoIDs, known: indexIDs,
            sort: library.filters?.sort.query ?? QuerySort(), grouping: wanted, finder: stacks.finder,
            stacks: stacks.list, opensStacks: stacks.opensNew,
        )
        // Detached, so the grouping starts at once rather than once the main thread has drawn the change of Group
        // By that asked for it.
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = ContinuousClock.now
            let result = await Self.group(request, index: core.index, engine: core.engine)
            await self?.grouped(result, as: request.grouping, since: started)
        }
    }

    /// The grouping asked for as `asked` is made: shown if it's still the one wanted, and the next asked for
    /// meanwhile started.
    private func grouped(_ result: Result?, as asked: Grouping, since started: ContinuousClock.Instant) {
        grouping = false
        lastGrouping = ContinuousClock.now - started
        let now = wanted
        if let result {
            lastGroupingParts = result.parts
            indexIDs.merge(result.found) { _, new in new }
            if result.grouping == now {
                let adopting = ContinuousClock.now
                adopt(result.grouped)
                lastAdoption = ContinuousClock.now - adopting
            }
        }
        if pending || asked != now {
            regroup()
        }
    }

    private struct Request: Sendable {
        var items: [LibraryItem]
        var ids: ContiguousArray<Int64>
        var known: [Int64: Int64]
        var sort: QuerySort
        var grouping: Grouping
        var finder: LibraryStackFinder
        /// The stacks as the filmstrip shows them, open and closed, and whether stacks come open.
        var stacks: StackedList?
        var opensStacks: Bool
    }

    private struct Result: Sendable {
        /// The groups, every one open: made here, as it's a pass over the photos.
        var grouped: GroupedList
        /// The index's IDs found for photos `known` didn't have.
        var found: [Int64: Int64]
        var grouping: Grouping
        var parts: [Duration] = []
    }

    /// The request's photos grouped as the library groups their rows in the index, relabelled with the IDs
    /// here; photos the index doesn't have are left out.
    private nonisolated static func group(_ request: Request, index: LibraryIndex, engine: QueryEngine) async
        -> Result? {
        let (items, ids, known) = (request.items, request.ids, request.known)
        guard items.count == ids.count else { return nil }
        let clock = ContinuousClock()
        var mark = clock.now
        var parts: [Duration] = []
        func lap() {
            let now = clock.now
            parts.append(now - mark)
            mark = now
        }
        var found: [Int64: Int64] = [:]
        let missing = ids.indices.filter { known[ids[$0]] == nil }
        if !missing.isEmpty {
            let byURL = await LibraryService.indexIDs(of: missing.map { items[$0].url }, in: index)
            for place in missing {
                if let id = byURL[items[place].url] {
                    found[ids[place]] = id
                }
            }
        }
        var indexed = ContiguousArray<Int64>()
        var own = ContiguousArray<Int64>()
        indexed.reserveCapacity(ids.count)
        own.reserveCapacity(ids.count)
        var taken = Set<Int64>(minimumCapacity: ids.count)
        for id in ids {
            guard let indexID = known[id] ?? found[id], taken.insert(indexID).inserted else { continue }
            indexed.append(indexID)
            own.append(id)
        }
        lap()
        let stacks = await request.finder.stacks(in: index, engine: engine) ?? Stacks()
        guard let grouping = try? await engine.grouping(stacks: stacks) else { return nil }
        lap()
        let (source, sort) = (request.grouping.source, request.sort)
        let groups = grouping.groups(
            of: PhotoList(source: source, sort: sort, ids: indexed), by: request.grouping.key,
            setting: request.grouping.setting,
        )
        lap()
        let relabelled = groups.relabelled(as: PhotoList(source: source, sort: sort, ids: own))
        var byIndex: [Int64: Int64] = [:]
        byIndex.reserveCapacity(indexed.count)
        for (place, id) in indexed.enumerated() {
            byIndex[id] = own[place]
        }
        var grouped = GroupedList(relabelled, stacks: stacks.relabelled(above: ids.max() ?? -1) { byIndex[$0] })
        if let shown = request.stacks {
            grouped.openStacks(as: shown)
        } else if request.opensStacks {
            grouped.openAllStacks()
        }
        lap()
        return Result(grouped: grouped, found: found, grouping: request.grouping, parts: parts)
    }

    /// Shows `made`'s groups, with the groups open that were open in the list it replaces, matched by their
    /// value, or for moments, which keep none from one grouping to the next, by the first of their photos it
    /// had. The same photos in the same groups change only the headers whose names changed.
    private func adopt(_ made: GroupedList) {
        var made = made
        if let stacks = model?.libraryViews.stacks, stacks.openings != stackOpenings, let shown = stacks.list {
            made.openStacks(as: shown)
        }
        let groups = made.groups
        if let old = list, old.groups.key == groups.key, let renamed = Self.renamed(old.groups, groups),
           Self.sameCells(old, made) {
            guard !renamed.isEmpty || old.groups.setting != groups.setting else { return }
            var grouped = made
            Self.open(&grouped, as: old)
            list = grouped
            if !renamed.isEmpty {
                changed(.headers(renamed))
            }
            return
        }
        var grouped = made
        if let old = list, old.groups.key == groups.key {
            Self.open(&grouped, as: old, opensNew: opensNew)
        } else {
            opensNew = true
            showsUnpicked = false
        }
        set(grouped)
    }

    /// Whether two groupings show the same cells: their stacks are the same, opened alike.
    private static func sameCells(_ old: GroupedList, _ new: GroupedList) -> Bool {
        old.stacked.count == new.stacked.count && old.stacked.elementsEqual(new.stacked)
    }

    /// The groups whose names changed, when two groupings hold the same photos in the same groups, in the same
    /// order; nil when they don't.
    private static func renamed(_ old: PhotoGroups, _ new: PhotoGroups) -> IndexSet? {
        guard old.count == new.count, old.photos == new.photos else { return nil }
        var renamed = IndexSet()
        for group in new.indices {
            guard old.photos(ofGroup: group).count == new.photos(ofGroup: group).count,
                  old.value(ofGroup: group) == new.value(ofGroup: group)
            else { return nil }
            if old.name(ofGroup: group) != new.name(ofGroup: group) {
                renamed.insert(group)
            }
        }
        return renamed
    }

    /// Opens and closes `grouped`'s groups as their matches in `old` are; groups without one open when
    /// `opensNew`.
    private static func open(_ grouped: inout GroupedList, as old: GroupedList, opensNew: Bool = true) {
        let groups = grouped.groups
        var open = [Bool](repeating: opensNew, count: groups.count)
        switch groups.key {
        case .moment, .momentCamera:
            for group in groups.indices {
                for photo in groups.photos(ofGroup: group) {
                    if let match = old.groups.index(of: photo) {
                        open[group] = old.isOpen(match)
                        break
                    }
                }
            }
        default:
            var byValue: [GroupValue: Int] = [:]
            for group in old.groups.indices {
                byValue[old.groups.value(ofGroup: group)] = group
            }
            for group in groups.indices {
                if let match = byValue[groups.value(ofGroup: group)] {
                    open[group] = old.isOpen(match)
                }
            }
        }
        var closing = 0
        for isOpen in open where !isOpen {
            closing += 1
        }
        if closing * 2 > open.count {
            grouped.closeAll()
            for group in open.indices where open[group] {
                grouped.open(group)
            }
        } else {
            for group in open.indices where !open[group] {
                grouped.close(group)
            }
        }
    }

    private func set(_ grouped: GroupedList?) {
        list = grouped
        countPicks()
        if let grouped {
            model?.deselectClosed(in: grouped)
        }
        changed(.regrouped)
    }

    private func changed(_ change: Change) {
        var next = outline
        if change == .regrouped {
            next.groupings += 1
        }
        (next.someOpen, next.someClosed) = (false, false)
        if let list {
            for group in list.groups.indices {
                if list.isOpen(group) {
                    next.someOpen = true
                } else {
                    next.someClosed = true
                }
                if next.someOpen, next.someClosed {
                    break
                }
            }
        }
        if next != outline {
            outline = next
        }
        for observer in observers.values {
            observer(change)
        }
    }

    /// Photos that came, went or moved are grouped again at once; badges, which change only the picks, are
    /// counted here, and the grouping follows once they've been quiet a moment, for a photo whose capture time,
    /// camera or size changed with its file.
    private func libraryChanged(_ diff: LibraryDiff) {
        guard model?.libraryViews.groupKey != .ungrouped else { return }
        guard !diff.reset, diff.removed.isEmpty, diff.inserted.isEmpty, list != nil else { return regroup() }
        badgesChanged(diff.updated)
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.regroup()
        }
    }

    // MARK: - Picks

    private func countPicks() {
        guard let list, let model else {
            picks = []
            coverage = nil
            return
        }
        picks = Self.picks(of: list.groups, in: model.library)
        updateCoverage()
    }

    /// Each group's picks, in one pass over the photos shown: loops, as a closure formed in the main actor's
    /// code checks it's on the main actor each time it's called, a photo at a time.
    private static func picks(of groups: PhotoGroups, in library: FolderLibrary) -> [Int] {
        let (items, ids) = (library.items, library.photoIDs)
        var picks = [Int](repeating: 0, count: groups.count)
        for row in items.indices where row < ids.count && items[row].metadata.flag == .pick {
            if let group = groups.index(of: ids[row]) {
                picks[group] += 1
            }
        }
        return picks
    }

    /// The badges of these rows changed: their groups' picks are counted again.
    private func badgesChanged(_ rows: IndexSet) {
        guard let list, let model, !rows.isEmpty else { return }
        let counted = Self.picks(of: list.groups, in: model.library)
        var changed = IndexSet()
        for group in counted.indices where !picks.indices.contains(group) || counted[group] != picks[group] {
            changed.insert(group)
        }
        guard !changed.isEmpty else { return }
        picks = counted
        updateCoverage()
        self.changed(.headers(changed))
    }

    private func updateCoverage() {
        guard let list, let moments = momentOfGroup(list.groups) else {
            coverage = nil
            return
        }
        var last = -1
        for moment in moments {
            last = max(last, moment ?? -1)
        }
        // Each moment's, by its number, and the photos without a capture time's: 0 none, 1 no pick, 2 a pick.
        var marks = [UInt8](repeating: 0, count: last + 1)
        var timeless: UInt8 = 0
        for group in moments.indices {
            let mark: UInt8 = picks.indices.contains(group) && picks[group] > 0 ? 2 : 1
            if let moment = moments[group] {
                marks[moment] = max(marks[moment], mark)
            } else {
                timeless = max(timeless, mark)
            }
        }
        var next = Coverage(unpicked: timeless == 1 ? 1 : 0, moments: timeless == 0 ? 0 : 1)
        for mark in marks where mark > 0 {
            next.moments += 1
            next.unpicked += mark == 1 ? 1 : 0
        }
        if next != coverage {
            coverage = next
        }
    }

    /// Each group's moment, nil for the photos without a capture time, while grouped by moment; nil for
    /// other keys.
    private func momentOfGroup(_ groups: PhotoGroups) -> [Int?]? {
        switch groups.key {
        case .moment, .momentCamera:
            var moments: [Int?] = []
            moments.reserveCapacity(groups.count)
            for group in groups.indices {
                switch groups.value(ofGroup: group) {
                case let .moment(moment), let .momentCamera(moment, _): moments.append(moment)
                default: moments.append(nil)
                }
            }
            return moments
        default: return nil
        }
    }

    // MARK: - Opening and closing

    @_spi(Harness) public func isOpen(_ group: Int) -> Bool {
        list?.isOpen(group) ?? false
    }

    /// Opens group `group` if it's closed, else closes it; with `all`, every group, as an ⌥-click does.
    func toggle(_ group: Int, all: Bool = false) {
        guard let list, list.groups.indices.contains(group) else { return }
        switch (list.isOpen(group), all) {
        case (true, false): close(group)
        case (false, false): open(group)
        case (true, true): closeAll()
        case (false, true): openAll()
        }
    }

    @_spi(Harness) public func open(_ group: Int) {
        guard var grouped = list, grouped.groups.indices.contains(group), !grouped.isOpen(group) else { return }
        let diff = grouped.open(group)
        list = grouped
        changed(.items(diff))
    }

    /// Closes group `group`; its photos leave the selection, and when the active photo is one of them, the
    /// photo selected nearest after it becomes active (`EditorModel.leaveClosedGroup`).
    @_spi(Harness) public func close(_ group: Int) {
        guard var grouped = list, grouped.groups.indices.contains(group), grouped.isOpen(group) else { return }
        let diff = grouped.close(group)
        list = grouped
        model?.leaveClosedGroup(group, in: grouped)
        changed(.items(diff))
    }

    @_spi(Harness) public func openAll() {
        guard var grouped = list else { return }
        opensNew = true
        showsUnpicked = false
        let diff = grouped.openAll()
        list = grouped
        changed(.items(diff))
    }

    @_spi(Harness) public func closeAll() {
        guard var grouped = list else { return }
        opensNew = false
        showsUnpicked = false
        let diff = grouped.closeAll()
        list = grouped
        model?.deselectClosed(in: grouped)
        changed(.items(diff))
    }

    /// Only the moments without a pick open, the others closed, as the library's coverage finds them; off,
    /// every group open again.
    func showUnpicked(_ show: Bool) {
        guard var grouped = list, let moments = momentOfGroup(grouped.groups) else { return }
        guard show else { return openAll() }
        var picked: [Int?: Bool] = [:]
        for (group, moment) in moments.enumerated() {
            picked[moment, default: false] = picked[moment, default: false] || picks[group] > 0
        }
        grouped.openAll()
        for (group, moment) in moments.enumerated() where picked[moment] == true {
            grouped.close(group)
        }
        list = grouped
        showsUnpicked = true
        model?.deselectClosed(in: grouped)
        changed(.regrouped)
    }

    // MARK: - Stacks

    /// The stacks were found again: the photos are grouped again with them.
    func restacked() {
        guard list != nil else { return }
        regroup()
    }

    /// Opens the stack whose first cell is `cell` in its group, as `shown`, the filmstrip's stacks, now has it; a
    /// stack in a closed group opens as its group does.
    func openStack(_ cell: Int64, as shown: StackedList) {
        guard var grouped = list else { return }
        var diff = grouped.openStack(cell)
        if diff.isEmpty {
            diff = grouped.openStacks(as: shown)
        }
        apply(grouped, diff)
    }

    /// Closes the open stack `cell` is in, as `shown` now has it.
    func closeStack(_ cell: Int64, as shown: StackedList) {
        guard var grouped = list else { return }
        var diff = grouped.closeStack(cell)
        if diff.isEmpty {
            diff = grouped.openStacks(as: shown)
        }
        apply(grouped, diff)
    }

    func openAllStacks() {
        guard var grouped = list else { return }
        let diff = grouped.openAllStacks()
        apply(grouped, diff)
    }

    func closeAllStacks() {
        guard var grouped = list else { return }
        let diff = grouped.closeAllStacks()
        apply(grouped, diff)
    }

    private func apply(_ grouped: GroupedList, _ diff: PhotoListDiff) {
        guard !diff.isEmpty else { return }
        list = grouped
        changed(.items(diff))
    }

    /// The active photo became one in a closed group, by a click in the filmstrip or a step that isn't the
    /// grid's: its group opens, so the grid shows it.
    private func revealActivePhoto() {
        guard let model, let list, let selection = model.selection, let id = model.library.photoID(of: selection),
              let group = list.groups.index(of: id), !list.isOpen(group)
        else { return }
        open(group)
    }

    // MARK: - The grid's order

    /// The group holding photo `id`.
    @_spi(Harness) public func group(of id: Int64) -> Int? {
        list?.groups.index(of: id)
    }

    /// The photo on show `offset` (1 or -1) after `id` in the grid's order; from a photo of a closed group,
    /// the first on show after its group, or the last before it. A closed stack is its cell.
    func shownPhoto(_ offset: Int, from id: Int64) -> Int64? {
        list?.cell(offset, from: id)
    }

    /// The first photo on show, or the last.
    @_spi(Harness) public func endPhoto(first: Bool) -> Int64? {
        guard let list else { return nil }
        let order = first ? Array(list.groups.indices) : Array(list.groups.indices.reversed())
        for group in order where list.isOpen(group) {
            if let photo = Self.cell(atEdgeOf: group, first: first, in: list) {
                return photo
            }
        }
        return nil
    }

    /// Open group `group`'s first cell, or its last; nil when it has none.
    private static func cell(atEdgeOf group: Int, first: Bool, in list: GroupedList) -> Int64? {
        let cells = list.cellCount(of: group)
        guard cells > 0 else { return nil }
        let header = list.index(ofHeader: group)
        if case let .photo(photo) = list[header + (first ? 1 : cells)] {
            return photo
        }
        return nil
    }

    /// The photos on show from `start` through `end`, in the grid's order, both on show, and every photo of the
    /// closed stacks among them.
    func shownPhotos(from start: Int64, through end: Int64) -> [Int64] {
        guard let list, let first = list.index(of: start), let last = list.index(of: end) else { return [] }
        var photos: [Int64] = []
        for item in min(first, last) ... max(first, last) {
            if case let .photo(photo) = list[item] {
                photos += list.stacked.photos(of: photo)
            }
        }
        return photos
    }

    /// The photos on show, in the grid's order, with every photo of the closed stacks.
    @_spi(Harness) public var shownPhotos: [Int64] {
        guard let list else { return [] }
        var photos: [Int64] = []
        photos.reserveCapacity(list.count)
        for item in list {
            if case let .photo(photo) = item {
                photos += list.stacked.photos(of: photo)
            }
        }
        return photos
    }
}
