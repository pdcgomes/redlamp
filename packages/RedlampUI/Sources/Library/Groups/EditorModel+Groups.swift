import Foundation
import RedlampLibrary

/// Group By in the Library grid (LIB-41): the key and moments' Tighter–Looser setting, kept with each
/// source's view; groups opened and closed, by their headers, the menus and the palette; ⌥← and ⌥→ to the
/// first photo of the group before or after the active photo's; the moments without a pick; and ← and →,
/// in the grid, the loupe, Develop and the filmstrip, through the photos in the grid's order, leaving out
/// closed groups' photos.
public extension EditorModel {
    /// Whether the source can be grouped: it's shown from the library, whose column store grouping reads.
    var canGroupPhotos: Bool {
        library.isShownFromLibrary && library.service?.core != nil
    }

    func setGroupKey(_ key: GroupKey) {
        guard key == .ungrouped || canGroupPhotos else { return }
        _ = gridGroups
        libraryViews.setGroupKey(key)
    }

    /// The Tighter–Looser control, from `MomentSetting.tightest` (more moments) to `loosest`.
    func setLooseness(_ looseness: Int) {
        _ = gridGroups
        libraryViews.setLooseness(looseness)
    }

    /// A click on group `group`'s header opens or closes it; an ⌥-click, every group.
    func toggleGroup(_ group: Int, all: Bool = false) {
        gridGroups.toggle(group, all: all)
    }

    func openAllGroups() {
        gridGroups.openAll()
    }

    func closeAllGroups() {
        gridGroups.closeAll()
    }

    /// Only the moments without a pick open, or every group again.
    func showUnpickedMoments(_ show: Bool) {
        gridGroups.showUnpicked(show)
    }

    var showsUnpickedMoments: Bool {
        gridGroups.showsUnpicked
    }

    /// ⌥← and ⌥→: the first photo of the group before or after the active photo's, alone, its group opened if
    /// it was closed.
    @discardableResult
    func moveToGroup(by offset: Int) -> Bool {
        guard let target = groupBeside(by: offset), let list = gridGroups.list,
              let first = list.groups[target].photos.first, let url = library.url(ofPhoto: first)
        else { return false }
        gridGroups.open(target)
        select(url)
        selectionAnchor = url
        return true
    }
}

extension EditorModel {
    /// The grid's groups, made the first time they're asked for.
    @_spi(Harness) public var gridGroups: LibraryGroups {
        if let groups = libraryViews.groups {
            return groups
        }
        let groups = LibraryGroups(model: self)
        libraryViews.groups = groups
        return groups
    }

    /// The group of the active photo, or the one opening.
    var activeGroup: Int? {
        (opening ?? selection).flatMap(library.photoID(of:)).flatMap(gridGroups.group(of:))
    }

    /// Whether the active photo is in a closed group: every group was closed, so no photo is on show.
    var activePhotoIsClosed: Bool {
        activeGroup.map { !gridGroups.isOpen($0) } ?? false
    }

    /// The group `offset` before or after the active photo's; without one, the first or the last.
    private func groupBeside(by offset: Int) -> Int? {
        guard let list = gridGroups.list, !list.groups.isEmpty else { return nil }
        guard let group = activeGroup else { return offset > 0 ? 0 : list.groups.count - 1 }
        let target = group + offset
        return list.groups.indices.contains(target) ? target : nil
    }

    /// ← and → while grouped: the photo on show after or before the active one, alone.
    private func stepInGroups(by offset: Int) {
        guard let from = opening ?? selection, let id = library.photoID(of: from),
              let next = gridGroups.shownPhoto(offset, from: id), let url = library.url(ofPhoto: next)
        else { return }
        select(url)
    }

    /// ⇧ with a click or an arrow key while grouped: the photos on show from the photo last clicked or moved
    /// to without ⇧ through `url`, in the grid's order, `url` active. Other clicks are `click`'s.
    func clickInGrid(_ url: URL, toggling: Bool = false, extending: Bool = false) {
        let groups = gridGroups
        guard extending, !toggling, groups.list != nil, let id = library.photoID(of: url) else {
            return click(url, toggling: toggling, extending: extending)
        }
        let anchor = [selectionAnchor, selection].compactMap(\.self).first { library.index(of: $0) != nil }
        guard let anchorID = anchor.flatMap(library.photoID(of:)), groups.list?.isVisible(anchorID) == true else {
            return select(url)
        }
        photoSelection.select(groups.shownPhotos(from: anchorID, through: id), active: id, in: library.photoList)
        select(url, keepingSelection: true)
    }

    // MARK: - Closed groups leave the selection

    /// Group `group` closed: its photos leave the selection, and when the active photo was one of them, the
    /// selected photo on show nearest after the group becomes active, else the nearest before it; with
    /// none selected, the photo on show nearest after it, alone, else before it. With no photo on show,
    /// nothing is selected and the active photo stays, so it's there again when its group opens.
    func leaveClosedGroup(_ group: Int, in list: GroupedList) {
        leaveClosed([group], in: list)
    }

    /// Every closed group's photos leave the selection, as `leaveClosedGroup` takes them out.
    func deselectClosed(in list: GroupedList) {
        let closed = list.groups.indices.filter { !list.isOpen($0) }
        guard !closed.isEmpty else { return }
        leaveClosed(closed, in: list)
    }

    private func leaveClosed(_ groups: [Int], in list: GroupedList) {
        var selected = photoSelection
        let photos = library.photoList
        if !selected.isEmpty {
            for group in groups {
                for id in list.groups[group].photos where selected.contains(id) {
                    selected.toggle(id, in: photos)
                }
            }
        }
        guard let active = selection.flatMap(library.photoID(of:)), let group = list.groups.index(of: active),
              !list.isOpen(group)
        else {
            if selected != photoSelection {
                photoSelection = selected
            }
            return
        }
        if let next = Self.nearest(to: group, in: list, where: selected.contains),
           let url = library.url(ofPhoto: next) {
            selected.activate(next)
            photoSelection = selected
            select(url, keepingSelection: true)
            selectionAnchor = url
        } else if let next = Self.nearest(to: group, in: list, where: { _ in true }),
                  let url = library.url(ofPhoto: next) {
            select(url)
            selectionAnchor = url
        } else {
            photoSelection = PhotoSelection()
        }
    }

    /// The first photo on show after group `group` that `matches`, else the last before it.
    private static func nearest(to group: Int, in list: GroupedList, where matches: (Int64) -> Bool) -> Int64? {
        for next in list.groups.indices where next > group && list.isOpen(next) {
            if let found = list.groups[next].photos.first(where: matches) {
                return found
            }
        }
        for previous in (0 ..< min(group, list.groups.count)).reversed() where list.isOpen(previous) {
            if let found = list.groups[previous].photos.last(where: matches) {
                return found
            }
        }
        return nil
    }

    // MARK: - Keys and menus

    /// Group By's actions, ← and → and Select All while grouped, and the culling keys while the active photo
    /// is in a closed group, which reach nothing; nil for every other.
    func performGroupShortcut(_ action: ShortcutAction) -> Bool? {
        if let key = action.groupKey {
            guard key == .ungrouped || canGroupPhotos else { return false }
            setGroupKey(key)
            showLibrary(.grid)
            return true
        }
        switch action {
        case .tighterMoments, .looserMoments:
            guard canPerformGroupShortcut(action) == true else { return false }
            setLooseness(libraryViews.looseness + (action == .looserMoments ? 1 : -1))
        case .toggleGroup:
            guard let group = activeGroup else { return false }
            gridGroups.toggle(group)
        case .openAllGroups:
            guard canPerformGroupShortcut(action) == true else { return false }
            openAllGroups()
        case .closeAllGroups:
            guard canPerformGroupShortcut(action) == true else { return false }
            closeAllGroups()
        case .unpickedMoments:
            guard gridGroups.coverage != nil else { return false }
            showUnpickedMoments(!gridGroups.showsUnpicked)
        case .previousGroup, .nextGroup:
            return moveToGroup(by: action == .nextGroup ? 1 : -1)
        case .previousPhoto, .nextPhoto:
            guard gridGroups.list != nil else { return nil }
            stepInGroups(by: action == .nextPhoto ? 1 : -1)
        case .selectAllPhotos:
            guard let list = gridGroups.list, list.groups.indices.contains(where: { !list.isOpen($0) }) else {
                return nil
            }
            selectShownPhotos()
        default:
            guard CullingChange(action) != nil, module == .library, photoSelection.isEmpty, activePhotoIsClosed else {
                return nil
            }
            return false
        }
        return true
    }

    /// Whether `performGroupShortcut` would do something now; nil for the actions it leaves alone.
    func canPerformGroupShortcut(_ action: ShortcutAction) -> Bool? {
        if let key = action.groupKey {
            return key == .ungrouped || canGroupPhotos
        }
        let groups = gridGroups
        let list = groups.list
        switch action {
        case .tighterMoments, .looserMoments:
            guard libraryViews.groupKey.usesMoments, canGroupPhotos else { return false }
            return action == .looserMoments ? libraryViews.looseness < MomentSetting.loosest
                : libraryViews.looseness > MomentSetting.tightest
        case .toggleGroup: return activeGroup != nil
        case .openAllGroups: return list.map { list in list.groups.indices.contains { !list.isOpen($0) } } ?? false
        case .closeAllGroups: return list.map { list in list.groups.indices.contains(where: list.isOpen) } ?? false
        case .unpickedMoments: return groups.coverage != nil
        case .previousGroup, .nextGroup: return groupBeside(by: action == .nextGroup ? 1 : -1) != nil
        case .previousPhoto, .nextPhoto:
            guard list != nil else { return nil }
            guard let id = (opening ?? selection).flatMap(library.photoID(of:)) else { return false }
            return groups.shownPhoto(action == .nextPhoto ? 1 : -1, from: id) != nil
        case .selectAllPhotos:
            guard let list, list.groups.indices.contains(where: { !list.isOpen($0) }) else { return nil }
            return selection != nil && photoSelection.count < list.count - list.groups.count
        default:
            guard CullingChange(action) != nil, module == .library, photoSelection.isEmpty, activePhotoIsClosed else {
                return nil
            }
            return false
        }
    }

    /// ⌘⌥A while groups are closed: the photos on show, the active one staying active when it's among them.
    private func selectShownPhotos() {
        let shown = gridGroups.shownPhotos
        guard selection != nil, let first = shown.first else { return }
        let active = selection.flatMap(library.photoID(of:))
            .flatMap { gridGroups.list?.isVisible($0) == true ? $0 : nil }
        photoSelection.select(shown, active: active ?? first, in: library.photoList)
        if active == nil, let url = library.url(ofPhoto: first) {
            select(url, keepingSelection: true)
            selectionAnchor = url
        }
    }
}

public extension ShortcutAction {
    /// The key a Group By action chooses.
    var groupKey: GroupKey? {
        switch self {
        case .groupByNone: .ungrouped
        case .groupByMoment: .moment
        case .groupByDay: .day
        case .groupByFolder: .folder
        case .groupByCamera: .camera
        case .groupByLens: .lens
        case .groupByOrientation: .orientation
        case .groupByMomentCamera: .momentCamera
        default: nil
        }
    }
}

public extension GroupKey {
    /// Its name in the grid's toolbar.
    var title: String {
        switch self {
        case .ungrouped: "None"
        case .moment: "Moment"
        case .day: "Day"
        case .folder: "Folder"
        case .camera: "Camera"
        case .lens: "Lens"
        case .orientation: "Orientation"
        case .momentCamera: "Moment, then Camera"
        }
    }

    /// Whether it groups by moments, which the Tighter–Looser setting finds.
    var usesMoments: Bool {
        self == .moment || self == .momentCamera
    }
}
