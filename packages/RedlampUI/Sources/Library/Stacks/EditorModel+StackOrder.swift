import Foundation
import RedlampLibrary

/// Lightroom Classic's last stacking commands in the Library (LIB-28): Remove from Stack, Split Stack, and ⇧[ and ⇧]
/// moving the active photo up and down its open stack, or a drag in the grid moving photos to another's place in it.
/// Each works on an open burst or stack made by hand, a raw and its JPEG going together, as one change with Undo among
/// the panels' (`LibraryPanels`), the stacks it leaves open shown open once the library has it. ⌘G, ⇧⌘G and ⇧S are
/// `EditorModel+Stacks`'.
public extension EditorModel {
    /// Makes `action`, one of Stacking's changes (`EditorModel+Stacks`), as `performStackShortcut` does; nil for any
    /// other action.
    internal func performStackChange(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .stackPhotos: stackSelectedPhotos()
        case .unstackPhotos: unstackSelectedPhotos()
        case .moveToStackTop: moveToTopOfStack()
        case .removeFromStack: removeSelectedFromStacks()
        case .splitStack: splitStack()
        case .moveUpInStack: moveInStack(by: -1)
        case .moveDownInStack: moveInStack(by: 1)
        default: nil
        }
    }

    /// Whether `performStackChange` would make `action` now; nil for any other action. Those that act on open stacks
    /// read the count of stacks opened and closed, so the menus' state follows S.
    internal func canPerformStackChange(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .stackPhotos: return canStackSelection
        case .unstackPhotos: return canUnstackSelection
        case .moveToStackTop: return canMoveToTopOfStack
        case .removeFromStack, .splitStack, .moveUpInStack, .moveDownInStack:
            _ = libraryViews.stacks?.toggles
            return switch action {
            case .removeFromStack: canRemoveSelectionFromStacks
            case .splitStack: canSplitStack
            default: canMoveInStack(by: action == .moveUpInStack ? -1 : 1)
            }
        default: return nil
        }
    }

    /// Remove from Stack: the photos selected in open stacks taken out of them, each standing alone, as one change
    /// with Undo; the stacks' other photos stay stacked, and open. A raw and its JPEG go together.
    @discardableResult
    func removeSelectedFromStacks() -> Bool {
        guard canRemoveSelectionFromStacks, let stacked = libraryViews.stacks?.list else { return false }
        let leaving = selectedOwnIDs.filter { openStack(of: $0, in: stacked) != nil }
        guard hasRead(leaving, then: { [weak self] in self?.removeSelectedFromStacks() }) else { return true }
        let photos = stackPhotos(leaving)
        let frames = Set(leaving.map { stacked.stacks.pair(containing: $0)?.top ?? $0 })
        var staying: [Int64] = []
        var seen = Set<Int>()
        for photo in leaving {
            guard let group = stacked.stacks.stackIndex(containing: photo), seen.insert(group).inserted,
                  let other = openStack(of: photo, in: stacked)?.frames.first(where: { !frames.contains($0) })
            else { continue }
            staying.append(other)
        }
        return makeStackChange(
            .remove(photos.ids), title: "Remove \(LibraryPanels.count(photos.ids.count)) from Stack", photos: photos,
            opening: staying,
        )
    }

    /// Split Stack: the active photo's open stack split before it, the photos above it staying a stack and it and
    /// those below it becoming one with it on top, both open, as one change with Undo.
    @discardableResult
    func splitStack() -> Bool {
        guard canSplitStack, let own = selection.flatMap(library.photoID(of:)), let id = gridStacks.indexID(of: own),
              let stacked = libraryViews.stacks?.list, let open = openStack(of: own, in: stacked)
        else { return false }
        let members = stacked.stacks.allPhotos(of: open.stack)
        guard hasRead(members, then: { [weak self] in self?.splitStack() }) else { return true }
        return makeStackChange(
            .split(before: id), title: "Split Stack", photos: stackPhotos(members), opening: [open.frames[0], own],
        )
    }

    /// ⇧[ and ⇧]: the active photo moved one place up (`offset` -1) or down (1) its open stack, past the next photo
    /// shown, as one change with Undo; the photo first in the stack is shown for it, and the stack keeps its order.
    @discardableResult
    func moveInStack(by offset: Int) -> Bool {
        guard canMoveInStack(by: offset), let own = selection.flatMap(library.photoID(of:)),
              let id = gridStacks.indexID(of: own), let stacked = libraryViews.stacks?.list,
              let open = openStack(of: own, in: stacked)
        else { return false }
        let members = stacked.stacks.allPhotos(of: open.stack)
        guard hasRead(members, then: { [weak self] in self?.moveInStack(by: offset) }) else { return true }
        let shown = Set(open.frames.compactMap(gridStacks.indexID(of:)))
        let name = selection?.lastPathComponent ?? "a photo"
        return makeStackChange(
            .move(id, by: offset, among: shown), title: "Move \(name) \(offset < 0 ? "Up" : "Down") in Stack",
            photos: stackPhotos(members), opening: [own],
        )
    }

    /// A drag in the grid: `photos` (by their IDs here) moved to `target`'s place in the open stack holding them all,
    /// before it from below and after it from above, as one change with Undo.
    @discardableResult
    func movePhotos(_ photos: [Int64], inStackTo target: Int64) -> Bool {
        guard canMovePhotos(photos, inStackTo: target), let stacked = libraryViews.stacks?.list,
              let open = openStack(of: target, in: stacked), let id = gridStacks.indexID(of: target)
        else { return false }
        let members = stacked.stacks.allPhotos(of: open.stack)
        guard hasRead(members, then: { [weak self] in self?.movePhotos(photos, inStackTo: target) }) else {
            return true
        }
        let moving = stackPhotos(photos)
        return makeStackChange(
            .place(moving.ids, at: id), title: "Move \(LibraryPanels.count(moving.ids.count)) in Stack",
            photos: stackPhotos(members), opening: [target],
        )
    }

    // MARK: - What they can do

    /// Whether Remove from Stack would take anything out: a photo selected is in an open burst or stack made by hand.
    /// Each stack is asked about once, however many of its photos are selected.
    var canRemoveSelectionFromStacks: Bool {
        guard library.service?.isReady == true, let stacked = libraryViews.stacks?.list else { return false }
        var asked = Set<Int>()
        return selectedOwnIDs.contains { id in
            guard let group = stacked.stacks.stackIndex(containing: id), asked.insert(group).inserted else {
                return false
            }
            return openStack(of: id, in: stacked) != nil
        }
    }

    /// Whether Split Stack would split anything: the active photo is in an open burst or stack made by hand, below
    /// its first photo shown.
    var canSplitStack: Bool {
        canMoveInStack(by: -1)
    }

    /// Whether ⇧[ (`offset` -1) or ⇧] (1) would move the active photo: it's in an open burst or stack made by hand,
    /// with a photo shown above it, or below it.
    func canMoveInStack(by offset: Int) -> Bool {
        guard library.service?.isReady == true, let stacked = libraryViews.stacks?.list,
              let id = selection.flatMap(library.photoID(of:)), let open = openStack(of: id, in: stacked),
              let place = open.frames.firstIndex(of: stacked.stacks.pair(containing: id)?.top ?? id)
        else { return false }
        return open.frames.indices.contains(place + offset)
    }

    /// Whether `photos` (by their IDs here) dragged onto `target` would move in their stack: all of them and it are
    /// in one open burst or stack made by hand, and it isn't among them.
    func canMovePhotos(_ photos: [Int64], inStackTo target: Int64) -> Bool {
        guard library.service?.isReady == true, !photos.isEmpty, let stacked = libraryViews.stacks?.list,
              let group = stacked.stacks.stackIndex(containing: target), openStack(of: target, in: stacked) != nil
        else { return false }
        let into = stacked.stacks.pair(containing: target)?.top ?? target
        return photos.allSatisfy { photo in
            stacked.stacks
                .stackIndex(containing: photo) == group && (stacked.stacks.pair(containing: photo)?.top ?? photo) !=
                into
        }
    }

    /// How many photos the open burst or stack made by hand holding photo `id` (by its ID here) has, a raw and its JPEG
    /// counting two; nil when it's closed, or the list doesn't show it as one.
    func openStackSize(of id: Int64) -> Int? {
        guard let stacked = libraryViews.stacks?.list, let open = openStack(of: id, in: stacked) else { return nil }
        return stacked.stacks.allPhotos(of: open.stack).count
    }

    /// The open burst or stack made by hand holding photo `id` (by its ID here), and the frames of it the list shows,
    /// each by its top photo, in the stack's order; nil when it's closed, or the list doesn't show it as one.
    func openStack(of id: Int64, in stacked: StackedList) -> (stack: Stack, frames: [Int64])? {
        guard let outer = stacked.shownStacks(of: id).first, outer.kind != .pair, outer.isOpen,
              let stack = stacked.stacks.stack(containing: id)
        else { return nil }
        let list = stacked.list
        let frames = stack.photos.filter { top in
            (stacked.stacks.pair(containing: top)?.photos ?? [top]).contains(where: list.contains)
        }
        return (stack, frames)
    }
}
