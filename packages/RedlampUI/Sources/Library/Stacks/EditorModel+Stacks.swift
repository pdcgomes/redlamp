import Foundation
import RedlampDocument
import RedlampLibrary

/// Stacks in the Library (LIB-28), with Lightroom Classic's keys: S opens or closes the active photo's stack,
/// ⌘G stacks the photos selected, ⇧⌘G takes them out of their stacks and ⇧S shows the active photo for its
/// stack, each also in the Photo menu's Stacking, the grid's context menu and the palette, with Open All Stacks
/// and Close All Stacks. Stacking and unstacking are batches of the library's with Undo, among the panels'
/// changes (`LibraryPanels`), shown once the library has them.
///
/// A closed stack's cell selects all of its photos: whatever changes the selection, the photos a closed stack
/// stands for are selected with its cell and only with it, and a photo inside a closed stack that becomes active
/// gives way to its cell. ← and →, the grid's and the filmstrip's clicks and keys, and culling's advance go from
/// cell to cell.
public extension EditorModel {
    /// Whether the active photo is in a stack shown as one, open or closed, for S.
    var canToggleStack: Bool {
        guard let stacked = libraryViews.stacks?.list, let id = (opening ?? selection).flatMap(library.photoID(of:)),
              let cell = stacked.cell(for: id)
        else { return false }
        return !stacked.shownStacks(of: cell).isEmpty
    }

    /// ⌘G: the photos selected stacked by hand, from any folders, the active photo on top, as one change with Undo.
    @discardableResult
    func stackSelectedPhotos() -> Bool {
        guard canStackSelection else { return false }
        let photos = selectedForStacks
        let top = selection.flatMap(library.photoID(of:)).flatMap { gridStacks.indexIDs[$0] }
        return makeStackChange(
            .stack(photos.ids, top: top), title: "Stack \(LibraryPanels.count(photos.ids.count))", photos: photos,
        )
    }

    /// ⇧⌘G: the photos selected taken out of their stacks, each standing alone, as one change with Undo. A raw and
    /// its JPEG stay one photo.
    @discardableResult
    func unstackSelectedPhotos() -> Bool {
        guard canUnstackSelection else { return false }
        let photos = selectedForStacks
        return makeStackChange(
            .unstack(photos.ids), title: "Unstack \(LibraryPanels.count(photos.ids.count))", photos: photos,
        )
    }

    /// ⇧S: the active photo shown for its burst or stack made by hand, as one change with Undo.
    @discardableResult
    func moveToTopOfStack() -> Bool {
        guard canMoveToTopOfStack, let url = selection, let own = library.photoID(of: url),
              let id = gridStacks.indexIDs[own], let stacks = libraryViews.stacks?.list?.stacks,
              let stack = stacks.stack(containing: own)
        else { return false }
        let photos = stackPhotos(stacks.allPhotos(of: stack))
        return makeStackChange(.top(id), title: "Move \(url.lastPathComponent) to the Top of Its Stack", photos: photos)
    }

    /// Whether ⌘G would stack anything: two photos selected or more, not counting a raw's JPEG, which the library
    /// has, and not every photo of one stack already.
    var canStackSelection: Bool {
        guard library.service?.isReady == true, library.isShownFromLibrary else { return false }
        let selected = selectedOwnIDs
        guard selected.count > 1 else { return false }
        let stacks = libraryViews.stacks?.list?.stacks ?? Stacks()
        var frames = Set<Int64>()
        var groups = Set<Stack>()
        for id in selected {
            frames.insert(stacks.pair(containing: id)?.top ?? id)
            groups.insert(stacks.stack(containing: id) ?? Stack(kind: .manual, photos: [id]))
        }
        guard frames.count > 1, let only = groups.first, groups.count == 1, only.photos.count > 1 else {
            return frames.count > 1
        }
        let shown = Set(selected)
        return !stacks.allPhotos(of: only).allSatisfy { !library.photoList.contains($0) || shown.contains($0) }
    }

    /// Whether ⇧⌘G would take anything out of a stack: a photo selected is in a burst or a stack made by hand.
    var canUnstackSelection: Bool {
        guard library.service?.isReady == true, let stacks = libraryViews.stacks?.list?.stacks else { return false }
        return selectedOwnIDs.contains { stacks.stack(containing: $0) != nil }
    }

    /// Whether ⇧S would change a stack's top: the active photo is in a burst or a stack made by hand, not on top.
    var canMoveToTopOfStack: Bool {
        guard library.service?.isReady == true, let stacks = libraryViews.stacks?.list?.stacks,
              let id = selection.flatMap(library.photoID(of:)), let stack = stacks.stack(containing: id)
        else { return false }
        return (stacks.pair(containing: id)?.top ?? id) != stack.top
    }

    /// What photo `id`'s cell shows of the stacks it's the first cell of in `stacked`: a burst's or a stack made by
    /// hand's count, and a raw and its JPEG's other extensions (`+JPG`).
    internal func stackBadges(
        of id: Int64,
        in stacked: StackedList,
    ) -> (count: GridBadges.Kind?, pair: GridBadges.Kind?) {
        let (stack, pair) = stacked.badges(of: id)
        guard stack != nil || pair != nil else { return (nil, nil) }
        let others = pair.map { _ in
            (stacked.stacks.pair(containing: id)?.photos ?? []).filter { $0 != id }.compactMap { photo in
                library.url(ofPhoto: photo).map { "+" + $0.pathExtension.uppercased() }
            }.joined()
        }
        return (
            stack.map { .stackCount($0.count, open: $0.isOpen) },
            pair
                .flatMap { badge in
                    others.map { .pairText($0.isEmpty ? "+\(badge.count - 1)" : $0, open: badge.isOpen) }
                },
        )
    }

    /// The focus stack suggested for merging (`stackSuggestions`) that `photo` is a frame of.
    func focusSuggestion(containing photo: URL) -> StackSuggestion? {
        stackSuggestions.first { $0.frames.contains(photo) }
    }

    /// The photos `url`'s cell stands for: every photo of a closed stack, else the photo alone.
    func photos(standingFor url: URL) -> [URL] {
        guard let stacked = libraryViews.stacks?.list, let id = library.photoID(of: url) else { return [url] }
        let photos = stacked.photos(of: id).compactMap(library.url(ofPhoto:))
        return photos.isEmpty ? [url] : photos
    }

    // MARK: - The selection

    /// A click on a cell's stars, flag, label or mark, or its context menu: `change` on the selection when the cell
    /// is in it, else on every photo the cell stands for, as `cull(_:from:)` does for a photo.
    func cull(_ change: CullingChange, fromCell photo: URL) {
        guard module == .library, let id = library.photoID(of: photo), let stacked = libraryViews.stacks?.list,
              !photoSelection.contains(id), photo != selection
        else { return cull(change, from: photo) }
        let photos = stacked.photos(of: id)
        guard photos.count > 1 else { return cull(change, from: photo) }
        let list = library.photoList
        cull(change, rows: photos.compactMap(list.index(of:)))
        activity.record(.action, change.title)
    }

    /// Keeps each closed stack's photos selected with its cell, and only with it, and moves the active photo from
    /// inside a closed stack to its cell; with `anyPhotoSelecting`, a closed stack any of whose photos is selected is
    /// selected whole, as stacks just closed are.
    func coverClosedStacks(anyPhotoSelecting: Bool = false) {
        guard let stacked = libraryViews.stacks?.list else { return }
        let active = selection.flatMap(library.photoID(of:))
        if let covered = photoSelection.covering(stacked, active: active, anyPhoto: anyPhotoSelecting) {
            photoSelection = covered
        }
        if let active, !stacked.isShown(active), let cell = stacked.cell(for: active),
           let url = library.url(ofPhoto: cell) {
            select(url, keepingSelection: true)
            selectionAnchor = url
        }
    }

    /// `photos`, a stack just closed whose first cell is `cell`: all of them selected when any was, `cell` active
    /// when the active photo was one of them.
    internal func keepSelected(_ photos: [Int64], standingFor cell: Int64) {
        let active = selection.flatMap(library.photoID(of:))
        guard let active, photos.contains(active) || photos.contains(where: photoSelection.contains) else { return }
        var kept = photoSelection
        let list = library.photoList
        for photo in photos where !kept.contains(photo) {
            kept.toggle(photo, in: list)
        }
        if photos.contains(active), let url = library.url(ofPhoto: cell) {
            kept.activate(cell)
            photoSelection = kept
            select(url, keepingSelection: true)
            selectionAnchor = url
        } else {
            kept.activate(active)
            photoSelection = kept
        }
    }

    /// A click in the filmstrip, or in the grid while it's ungrouped, among cells with stacks: ⌘ adds or takes away
    /// a closed stack whole, ⇧ selects the cells from the photo last clicked or moved to without ⇧ through `url`,
    /// every photo of the closed stacks among them. Other clicks are `click`'s.
    func clickInStacks(_ url: URL, toggling: Bool = false, extending: Bool = false) {
        defer { coverClosedStacks() }
        guard let stacked = libraryViews.stacks?.list, let id = library.photoID(of: url), toggling || extending,
              let target = stacked.index(of: id)
        else { return click(url, toggling: toggling, extending: extending) }
        let list = library.photoList
        if extending, !toggling {
            let anchor = [selectionAnchor, selection].compactMap(\.self).first { library.index(of: $0) != nil }
            guard let from = anchor.flatMap(library.photoID(of:)).flatMap(stacked.cell(for:))
                .flatMap(stacked.index(of:))
            else { return select(url) }
            var photos: [Int64] = []
            for index in min(from, target) ... max(from, target) {
                photos += stacked.photos(of: stacked[index])
            }
            photoSelection.select(photos, active: id, in: list)
            select(url, keepingSelection: true)
            return
        }
        let photos = stacked.photos(of: id)
        guard toggling, photos.count > 1 else { return click(url, toggling: toggling, extending: extending) }
        var next = photoSelection
        if next.contains(id) {
            guard next.count > photos.count else { return }
            for photo in photos where next.contains(photo) {
                next.toggle(photo, in: list)
            }
            photoSelection = next
            if let active = selection.flatMap(library.photoID(of:)), photos.contains(active),
               let other = next.active.flatMap(library.url(ofPhoto:)) {
                select(other, keepingSelection: true)
                selectionAnchor = other
            }
        } else {
            for photo in photos where !next.contains(photo) {
                next.toggle(photo, in: list)
            }
            next.activate(id)
            photoSelection = next
            select(url, keepingSelection: true)
            selectionAnchor = url
        }
    }

    // MARK: - Keys, menus and the palette

    /// A stack's action from `photo`'s context menu: on the selection when `photo` is in it, else on `photo`'s cell,
    /// which is selected first; Open / Close Stack opens or closes `photo`'s stack alone.
    func performStackAction(_ action: ShortcutAction, on photo: URL) {
        if action == .toggleStack, let id = library.photoID(of: photo) {
            return gridStacks.toggle(id)
        }
        if !isInSelection(photo) {
            clickInGrid(photo)
        }
        perform(action)
    }

    /// Whether `performStackAction` would do something for `photo`.
    func canPerformStackAction(_ action: ShortcutAction, on photo: URL) -> Bool {
        guard !isModalDialogOpen else { return false }
        guard !isInSelection(photo) else { return canPerform(action) }
        guard let stacked = libraryViews.stacks?.list, let id = library.photoID(of: photo) else {
            return action == .openAllStacks || action == .closeAllStacks ? canPerform(action) : false
        }
        let stacks = stacked.stacks
        switch action {
        case .stackPhotos: return false
        case .unstackPhotos: return library.service?.isReady == true && stacks.stack(containing: id) != nil
        case .moveToStackTop:
            guard library.service?.isReady == true, let stack = stacks.stack(containing: id) else { return false }
            return (stacks.pair(containing: id)?.top ?? id) != stack.top
        case .toggleStack: return !stacked.shownStacks(of: stacked.cell(for: id) ?? id).isEmpty
        default: return canPerform(action)
        }
    }

    /// Whether `photo` is selected, or is the active photo.
    private func isInSelection(_ photo: URL) -> Bool {
        photo == selection || library.photoID(of: photo).map(photoSelection.contains) == true
    }

    /// The stacks' actions; ← and →, culling's advance and Deselect Other Photos among cells; and taking a stack's
    /// change back or making it again, which the panels' Undo does. Nil for every other action.
    internal func performStackShortcut(_ action: ShortcutAction, shifted: Bool) -> Bool? {
        switch action {
        case .toggleStack:
            guard canToggleStack, let id = (opening ?? selection).flatMap(library.photoID(of:)) else { return false }
            gridStacks.toggle(id)
        case .openAllStacks:
            guard canPerformStackShortcut(action) == true else { return false }
            gridStacks.openAll()
        case .closeAllStacks:
            guard canPerformStackShortcut(action) == true else { return false }
            gridStacks.closeAll()
        case .stackPhotos: return stackSelectedPhotos()
        case .unstackPhotos: return unstackSelectedPhotos()
        case .moveToStackTop: return moveToTopOfStack()
        case .previousPhoto, .nextPhoto:
            guard libraryViews.groups?.list == nil, let stacked = libraryViews.stacks?.list else { return nil }
            return step(by: action == .nextPhoto ? 1 : -1, in: stacked)
        case .deselectOtherPhotos:
            guard libraryViews.stacks?.list != nil else { return nil }
            guard canPerformStackShortcut(action) == true else { return false }
            deselectOtherPhotos()
            coverClosedStacks()
        case .undo where module == .library:
            if libraryPanels.undoSteps.last?.changes.contains(where: \.isStacks) == true {
                restackAfterPanels()
            }
            return nil
        case .redo where module == .library:
            if libraryPanels.redoSteps.last?.changes.contains(where: \.isStacks) == true {
                restackAfterPanels()
            }
            return nil
        default:
            guard let change = CullingChange(action), shifted || autoAdvance, let stacked = libraryViews.stacks?.list,
                  sizedBrush == nil || ![.decreaseRating, .increaseRating].contains(action),
                  !(action == .flagReject && module == .develop && activeTool == .crop)
            else { return nil }
            let culled = module == .library ? selectedRows
                : (opening ?? selection).flatMap(library.index(of:)).map { [$0] } ?? []
            let ids = library.photoIDs
            guard cull(change, advance: false) else { return false }
            advance(past: culled.compactMap { ids.indices.contains($0) ? ids[$0] : nil }, in: stacked)
        }
        return true
    }

    /// Whether `performStackShortcut` would do something now; nil for the actions it leaves alone.
    internal func canPerformStackShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .toggleStack: canToggleStack
        case .openAllStacks: libraryViews.stacks?.list?.stacksShown.closed ?? 0 > 0
        case .closeAllStacks: libraryViews.stacks?.list?.stacksShown.open ?? 0 > 0
        case .stackPhotos: canStackSelection
        case .unstackPhotos: canUnstackSelection
        case .moveToStackTop: canMoveToTopOfStack
        case .previousPhoto, .nextPhoto:
            if libraryViews.groups?.list == nil, let stacked = libraryViews.stacks?.list {
                cell(after: action == .nextPhoto ? 1 : -1, in: stacked) != nil
            } else {
                nil
            }
        case .deselectOtherPhotos:
            if let stacked = libraryViews.stacks?.list {
                photoSelection.count > (selection.flatMap(library.photoID(of:))
                    .map { stacked.photos(of: stacked.cell(for: $0) ?? $0).count } ?? 1)
            } else {
                nil
            }
        default: nil
        }
    }

    // MARK: - Moving from cell to cell

    /// The cell `offset` (1 or -1) from the active photo's.
    private func cell(after offset: Int, in stacked: StackedList) -> Int64? {
        guard let id = (opening ?? selection).flatMap(library.photoID(of:)), let cell = stacked.cell(for: id),
              let index = stacked.index(of: cell), stacked.indices.contains(index + offset)
        else { return nil }
        return stacked[index + offset]
    }

    /// ← and → while ungrouped: the cell after or before the active photo's, alone.
    private func step(by offset: Int, in stacked: StackedList) -> Bool {
        guard let next = cell(after: offset, in: stacked), let url = library.url(ofPhoto: next) else { return false }
        select(url)
        coverClosedStacks()
        return true
    }

    /// Culling's advance: the cell after the last of those standing for `photos`, alone.
    private func advance(past photos: [Int64], in stacked: StackedList) {
        let last = photos.compactMap { stacked.cell(for: $0).flatMap(stacked.index(of:)) }.max()
        guard let last, stacked.indices.contains(last + 1), let url = library.url(ofPhoto: stacked[last + 1]) else {
            return
        }
        select(url)
        coverClosedStacks()
    }

    // MARK: - Making a change

    /// The IDs here of the photos selected, or the active photo's when none is.
    private var selectedOwnIDs: [Int64] {
        let ids = library.photoIDs
        return selectedRows.compactMap { ids.indices.contains($0) ? ids[$0] : nil }
    }

    /// The photos selected, and the raw or JPEG beside each in a pair, as their URLs and their IDs in the index, for
    /// those the index has.
    private var selectedForStacks: (urls: [URL], ids: [Int64]) {
        stackPhotos(selectedOwnIDs)
    }

    /// `photos`, by their IDs here, with the others of their pairs, as their URLs and their IDs in the index.
    private func stackPhotos(_ photos: [Int64]) -> (urls: [URL], ids: [Int64]) {
        let stacks = libraryViews.stacks?.list?.stacks ?? Stacks()
        let known = gridStacks.indexIDs
        var seen = Set<Int64>()
        var found: (urls: [URL], ids: [Int64]) = ([], [])
        for photo in photos {
            for member in stacks.pair(containing: photo)?.photos ?? [photo] where seen.insert(member).inserted {
                guard let id = known[member], let url = library.url(ofPhoto: member) else { continue }
                found.urls.append(url)
                found.ids.append(id)
            }
        }
        return found
    }

    /// Makes `change` as one of the panels' changes with Undo, then shows the stacks as the library has them.
    private func makeStackChange(_ change: StackChange, title: String, photos: (urls: [URL], ids: [Int64])) -> Bool {
        guard !photos.ids.isEmpty, libraryPanels.make(
            [.stacks(change)],
            title: title,
            onSelection: false,
            photos: photos,
        )
        else { return false }
        restackAfterPanels()
        return true
    }

    /// Shows the stacks again once the panels' changes asked for are made.
    private func restackAfterPanels() {
        let (panels, stacks) = (libraryPanels, gridStacks)
        Task {
            await panels.written()
            stacks.restack(forgetting: true)
        }
    }
}
