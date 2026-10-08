import Foundation
import RedlampLibrary

/// The Collections section's changes (LIB-23): sets and collections made, renamed, moved into a set and deleted,
/// the selection's photos put in a collection and taken out of the one shown, and the target collection chosen.
/// Each is one of the library's batches, on Library's Undo with the panels' and culling's changes, made off the
/// main thread; the list is counted again once it's made.
public extension LibrarySources {
    /// The place `name` names inside `set`, or at the top of the list; nil when the name is left empty.
    func place(named name: String, inside set: CollectionPath?) -> CollectionPath? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return set.map { $0.appending(name) } ?? CollectionPath(names: [name])
    }

    /// Why `name` can't name a place inside `set`, in words; nil when it can. `renaming` is the place being
    /// renamed, which may keep its name.
    func problem(naming name: String, inside set: CollectionPath?, renaming: CollectionPath? = nil) -> String? {
        guard let path = place(named: name, inside: set) else { return "Give it a name." }
        guard path != renaming, collections[path] != nil else { return nil }
        return "“\(path.displayName)” is in the collection list already."
    }

    /// Makes a set, or a collection inside `set`; `adding` the selection's photos to a collection, and making it
    /// the target with `target`. One change with Undo; false when it can't be made.
    @discardableResult
    func create(
        _ kind: CollectionKind, named name: String, inside set: CollectionPath? = nil, adding: Bool = false,
        target: Bool = false,
    ) -> Bool {
        guard let model, problem(naming: name, inside: set) == nil, let path = place(named: name, inside: set) else {
            return false
        }
        var changes: [PanelChange] = [.collections(.create(path, kind))]
        if target, kind == .collection {
            changes.append(.collections(.target(path)))
        }
        let title = "New \(kind == .set ? "collection set" : "collection") “\(path.displayName)”"
        guard adding, kind == .collection, !model.selectedPhotos.isEmpty else { return make(changes, title: title) }
        let photos = model.selectedPhotos
        Task { [weak self] in
            guard let self else { return }
            let ids = await indexIDs(of: photos)
            make(ids.isEmpty ? changes : changes + [.collections(.add(ids, to: path))], title: title, onSelection: true)
        }
        return true
    }

    /// Renames the set or collection at `path` within its set, everything inside it following; the source shown
    /// within it is shown again under its new name.
    @discardableResult
    func rename(_ path: CollectionPath, to name: String) -> Bool {
        guard problem(naming: name, inside: path.parent, renaming: path) == nil,
              let renamed = place(named: name, inside: path.parent), renamed != path
        else { return false }
        return move(path, to: renamed, title: "Rename “\(path.displayName)” to “\(renamed.name)”")
    }

    /// Moves the place at `path` into `set`, or to the top of the list.
    @discardableResult
    func move(_ path: CollectionPath, into set: CollectionPath?) -> Bool {
        guard set != path.parent, !(set?.isWithin(path) ?? false), let moved = place(named: path.name, inside: set),
              collections[moved] == nil
        else { return false }
        return move(path, to: moved, title: "Move “\(path.displayName)” to “\(set?.displayName ?? "Collections")”")
    }

    private func move(_ path: CollectionPath, to moved: CollectionPath, title: String) -> Bool {
        let shown = if case let .collection(within)? = shown,
                       within.isWithin(path) {
            within
        } else {
            CollectionPath?.none
        }
        return make([.collections(.rename(path, to: moved))], title: title) { [weak self] in
            if let shown {
                self?.show(.collection(shown.replacingPrefix(path, with: moved)))
            }
        }
    }

    /// Takes the place at `path` and everything inside it out of the list and off every photo; All Photographs
    /// takes the place of the source shown within it.
    @discardableResult
    func delete(_ path: CollectionPath) -> Bool {
        let shownWithin = if case let .collection(within)? = shown {
            within.isWithin(path)
        } else {
            false
        }
        return make([.collections(.delete([path]))], title: "Delete “\(path.displayName)”") { [weak self] in
            if shownWithin {
                self?.show(.allPhotographs)
            }
        }
    }

    /// Makes the collection at `path` the target, which Add to Target Collection puts photos in; nil makes it the
    /// quick collection, Marked.
    @discardableResult
    func setTarget(_ path: CollectionPath?) -> Bool {
        guard path != target else { return false }
        return make(
            [.collections(.target(path))],
            title: path.map { "Make “\($0.displayName)” the target" } ?? "Make Marked the target",
        )
    }

    /// Whether the selection's photos can go in a collection now: there's a collection, and photos selected that
    /// aren't in the Trash.
    var canAdd: Bool {
        guard let model, model.library.service?.isReady == true, model.selection != nil else { return false }
        return !model.library.showsRecentlyTrashed
    }

    /// Puts the selection's photos in the collection at `path`.
    @discardableResult
    func add(to path: CollectionPath) -> Bool {
        guard canAdd, let model, collections[path]?.kind == .collection else { return false }
        let photos = model.selectedPhotos
        Task { [weak self] in
            guard let self else { return }
            let ids = await indexIDs(of: photos)
            guard !ids.isEmpty else { return }
            make(
                [.collections(.add(ids, to: path))], title: "Add \(Self.count(ids.count)) to “\(path.displayName)”",
                onSelection: true,
            )
        }
        return true
    }

    /// Puts the selection's photos in the target collection, or marks them while Marked is the target.
    @discardableResult
    func addToTarget() -> Bool {
        guard canAdd, let model else { return false }
        guard let target else { return model.cull(.mark(true)) }
        return add(to: target)
    }

    /// The collection shown that photos can be taken out of: not a set or a smart collection.
    var collectionShown: CollectionPath? {
        guard case let .collection(path)? = shown, collections[path]?.kind == .collection else { return nil }
        return path
    }

    /// Whether Remove from Collection would take photos out of the collection shown.
    var canRemove: Bool {
        collectionShown != nil && model?.selection != nil
    }

    /// Takes the selection's photos out of the collection shown.
    @discardableResult
    func removeFromShown() -> Bool {
        guard let model, let path = collectionShown else { return false }
        let photos = model.selectedPhotos
        Task { [weak self] in
            guard let self else { return }
            let ids = await indexIDs(of: photos)
            guard !ids.isEmpty else { return }
            make(
                [.collections(.remove(ids, from: path))],
                title: "Remove \(Self.count(ids.count)) from “\(path.displayName)”", onSelection: true,
            )
        }
        return true
    }

    /// The places photos can be put in: every collection, by its name in the list.
    var collectionsTakingPhotos: [CollectionPath] {
        _ = rows
        return collections.values.filter { $0.kind == .collection }.map(\.path)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

extension LibrarySources {
    /// Makes `changes` as one step of Library's Undo, then counts again and runs `then`.
    @discardableResult
    func make(
        _ changes: [PanelChange], title: String, onSelection: Bool = false,
        then: (@MainActor () -> Void)? = nil,
    ) -> Bool {
        guard let model else { return false }
        let panels = model.libraryPanels
        guard panels.make(changes, title: title, onSelection: onSelection) else { return false }
        Task { [weak self] in
            await panels.written()
            self?.recount()
            then?()
        }
        return true
    }

    /// `12 photos`, `a photo`.
    static func count(_ photos: Int) -> String {
        LibraryPanels.count(photos)
    }
}
