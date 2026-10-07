import Foundation
import Observation
import RedlampDesign
import RedlampLibrary

/// The Library grid's groups (LIB-41): the source's photos under Group By's groups, as the library groups
/// them (`LibraryGrouping`), each group a header the grid opens and closes (`GroupedList`), over the app's
/// own photo IDs (`FolderLibrary.photoIDs`), so the grid's selection is `EditorModel.photoSelection`.
///
/// Grouping reads the column store, so it needs the source shown from the library. It's worked out off the
/// main thread when the photos, the key or the setting change, one grouping at a time, the last change
/// grouped once the one before is in; a list grouped by the same key keeps what was open. A group opens or
/// closes on the main thread in microseconds, with a diff of the grid's items. A closed group's photos are
/// never selected, so nothing out of sight is acted on. Each header's picks are the photos' badges, as the
/// cells show them, ahead of the index while a culling change reaches it.
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

    @ObservationIgnored private weak var model: EditorModel?
    /// The source's photos in their groups; nil while ungrouped, without the library, and until the first
    /// grouping is in.
    @ObservationIgnored @_spi(Harness) public private(set) var list: GroupedList?
    /// Each group's picks, from the photos' badges.
    @ObservationIgnored @_spi(Harness) public private(set) var picks: [Int] = []
    /// Bumped by every change, for the views showing the groups' counts.
    @_spi(Harness) public private(set) var revision = 0
    /// Whether groups the list gains come open: not after Close All Groups.
    @ObservationIgnored private var opensNew = true
    @ObservationIgnored private var observers: [UUID: @MainActor (Change) -> Void] = [:]
    @ObservationIgnored private var observation: LibraryObservation?
    @ObservationIgnored private var selectionTracker: AnyObject?
    @ObservationIgnored private var grouping = false
    @ObservationIgnored private var pending = false
    /// Each photo's ID in the index, by its ID here, for the source they were found for.
    @ObservationIgnored private var indexIDs: [Int64: Int64] = [:]
    @ObservationIgnored private var indexedSource: PhotoSource?
    /// How long the last grouping took off the main thread, for `--library-perf`.
    @ObservationIgnored @_spi(Harness) public private(set) var lastGrouping: Duration = .zero

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
        return Grouping(key: state.groupKey, setting: MomentSetting(), source: library.photoList.source)
    }

    // MARK: - Grouping

    /// Groups the source's photos again, off the main thread, as they are now; ungroups them when Group By is
    /// none or the source isn't shown from the library.
    func regroup() {
        guard let model, let wanted, let core = model.library.service?.core else {
            pending = false
            if list != nil {
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
        let request = Request(
            items: library.items, ids: library.photoIDs, known: indexIDs,
            sort: library.filters?.sort.query ?? QuerySort(), grouping: wanted,
        )
        Task { [weak self] in
            let started = ContinuousClock.now
            let result = await Self.group(request, index: core.index, engine: core.engine)
            guard let self else { return }
            grouping = false
            lastGrouping = ContinuousClock.now - started
            let now = self.wanted
            if let result {
                indexIDs.merge(result.found) { _, new in new }
                if result.grouping == now {
                    adopt(result.groups)
                }
            }
            if pending || request.grouping != now {
                regroup()
            }
        }
    }

    private struct Request: Sendable {
        var items: [LibraryItem]
        var ids: ContiguousArray<Int64>
        var known: [Int64: Int64]
        var sort: QuerySort
        var grouping: Grouping
    }

    private struct Result: Sendable {
        var groups: PhotoGroups
        /// The index's IDs found for photos `known` didn't have.
        var found: [Int64: Int64]
        var grouping: Grouping
    }

    /// The request's photos grouped as the library groups their rows in the index, relabelled with the IDs
    /// here; photos the index doesn't have are left out.
    private nonisolated static func group(_ request: Request, index: LibraryIndex, engine: QueryEngine) async
        -> Result? {
        let (items, ids, known) = (request.items, request.ids, request.known)
        guard items.count == ids.count else { return nil }
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
        guard let grouping = try? await engine.grouping() else { return nil }
        let (source, sort) = (request.grouping.source, request.sort)
        let groups = grouping.groups(
            of: PhotoList(source: source, sort: sort, ids: indexed), by: request.grouping.key,
            setting: request.grouping.setting,
        )
        return Result(
            groups: groups.relabelled(as: PhotoList(source: source, sort: sort, ids: own)), found: found,
            grouping: request.grouping,
        )
    }

    /// Shows `groups`, with the groups open that were open in the list it replaces, matched by their value,
    /// or for moments, which keep none from one grouping to the next, by the first of their photos it had.
    /// The same photos in the same groups change only the headers whose names changed.
    private func adopt(_ groups: PhotoGroups) {
        if let old = list, old.groups.key == groups.key, Self.sameGroups(old.groups, groups) {
            var grouped = GroupedList(groups, stacks: Stacks())
            Self.open(&grouped, as: old)
            list = grouped
            let renamed = IndexSet(groups.indices.filter { old.groups[$0].name != groups[$0].name })
            if !renamed.isEmpty {
                changed(.headers(renamed))
            }
            return
        }
        var grouped = GroupedList(groups, stacks: Stacks())
        if let old = list, old.groups.key == groups.key {
            Self.open(&grouped, as: old, opensNew: opensNew)
        } else {
            opensNew = true
        }
        set(grouped)
    }

    /// Whether two groupings hold the same photos in the same groups, in the same order.
    private static func sameGroups(_ old: PhotoGroups, _ new: PhotoGroups) -> Bool {
        old.photos == new.photos && old.map(\.count) == new.map(\.count) && old.map(\.value) == new.map(\.value)
    }

    /// Opens and closes `grouped`'s groups as their matches in `old` are; groups without one open when
    /// `opensNew`.
    private static func open(_ grouped: inout GroupedList, as old: GroupedList, opensNew: Bool = true) {
        let groups = grouped.groups
        var open = [Bool](repeating: opensNew, count: groups.count)
        switch groups.key {
        case .moment, .momentCamera:
            for group in groups.indices {
                if let match = groups[group].photos.lazy.compactMap(old.groups.index(of:)).first {
                    open[group] = old.isOpen(match)
                }
            }
        default:
            var byValue: [GroupValue: Int] = [:]
            for (group, detail) in old.groups.enumerated() {
                byValue[detail.value] = group
            }
            for group in groups.indices {
                if let match = byValue[groups[group].value] {
                    open[group] = old.isOpen(match)
                }
            }
        }
        let closing = open.count { !$0 }
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
        revision += 1
        for observer in observers.values {
            observer(change)
        }
    }

    private func libraryChanged(_ diff: LibraryDiff) {
        guard model?.libraryViews.groupKey != .ungrouped else { return }
        if !diff.reset, !diff.updated.isEmpty, list != nil {
            badgesChanged(diff.updated)
        }
        regroup()
    }

    // MARK: - Picks

    private func countPicks() {
        guard let list, let model else {
            picks = []
            return
        }
        let library = model.library
        let (items, photos) = (library.items, library.photoList)
        picks = list.groups.map { group in
            group.photos.reduce(0) { count, id in
                count + (photos.index(of: id).map { items[$0].metadata.flag == .pick ? 1 : 0 } ?? 0)
            }
        }
    }

    /// The badges of these rows changed: their groups' picks are counted again.
    private func badgesChanged(_ rows: IndexSet) {
        guard let list, let model else { return }
        let library = model.library
        let (items, ids, photos) = (library.items, library.photoIDs, library.photoList)
        var touched = IndexSet()
        for row in rows where ids.indices.contains(row) {
            if let group = list.groups.index(of: ids[row]) {
                touched.insert(group)
            }
        }
        var changed = IndexSet()
        for group in touched where picks.indices.contains(group) {
            let count = list.groups[group].photos.reduce(0) { count, id in
                count + (photos.index(of: id).map { items[$0].metadata.flag == .pick ? 1 : 0 } ?? 0)
            }
            if count != picks[group] {
                picks[group] = count
                changed.insert(group)
            }
        }
        guard !changed.isEmpty else { return }
        self.changed(.headers(changed))
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
        let diff = grouped.openAll()
        list = grouped
        changed(.items(diff))
    }

    @_spi(Harness) public func closeAll() {
        guard var grouped = list else { return }
        opensNew = false
        let diff = grouped.closeAll()
        list = grouped
        model?.deselectClosed(in: grouped)
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
    /// the first on show after its group, or the last before it.
    func shownPhoto(_ offset: Int, from id: Int64) -> Int64? {
        guard let list, let group = list.groups.index(of: id) else { return nil }
        if let item = list.index(of: id) {
            let next = item + offset
            if list.indices.contains(next), case let .photo(photo) = list[next] {
                return photo
            }
        }
        var next = group + offset
        while list.groups.indices.contains(next) {
            if list.isOpen(next), let photo = offset > 0 ? list.groups[next].photos.first
                : list.groups[next].photos.last {
                return photo
            }
            next += offset
        }
        return nil
    }

    /// The photos on show from `start` through `end`, in the grid's order, both on show.
    func shownPhotos(from start: Int64, through end: Int64) -> [Int64] {
        guard let list, let first = list.index(of: start), let last = list.index(of: end) else { return [] }
        var photos: [Int64] = []
        for item in min(first, last) ... max(first, last) {
            if case let .photo(photo) = list[item] {
                photos.append(photo)
            }
        }
        return photos
    }

    /// The photos on show, in the grid's order.
    @_spi(Harness) public var shownPhotos: [Int64] {
        guard let list else { return [] }
        var photos: [Int64] = []
        photos.reserveCapacity(list.count)
        for item in list {
            if case let .photo(photo) = item {
                photos.append(photo)
            }
        }
        return photos
    }
}
