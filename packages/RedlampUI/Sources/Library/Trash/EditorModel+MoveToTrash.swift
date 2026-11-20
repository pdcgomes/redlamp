import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary

/// Move to Trash (LIB-46), as Lightroom Classic's Remove Photo and the Finder's Move to Trash: the photo being edited,
/// or the photos selected, from a photo's context menu in the grid and the filmstrip, the Photo menu, the palette, ⌘⌫
/// and ⌫, in Library and Develop, each with its raw or JPEG pair, its sidecars and other apps' `.xmp`, as one of the
/// library's journaled batches (LIB-26). Nothing is deleted (DEC-45): Recently Trashed lists the photos and Put Back
/// puts them back, and Library's ⌘Z takes the batch back, the photos selected as they were. No photo leaves Redlamp
/// while its file stays, since the folders are the library (DEC-42).
///
/// - **The keys:** ⌫ is Remove from Collection's in a collection and in Marked, and Delete Selected Mask or Spot's in
///   Develop's Masking and Healing tools, a mask or spot selected or not; ⌘⌫ is Put Back's in Recently Trashed, where
///   Move to Trash is off. Elsewhere both are Move to Trash's (`ShortcutAction.givesKeys`, `claimsKey`). Held, neither
///   repeats: each press is one batch.
/// - **The photo after:** the photos leave the grid and the filmstrip at once, before the batch runs, and the photo
///   after the active one that stays becomes active, else the one before it; in Develop it opens there. With none
///   left, no photo is open (`EditorModel+Files`).
/// - **Said:** the notice over the photos says what went, as it says what Undo takes back, and the activity log
///   records it; an alert says why when nothing went.
/// - **Kept in Apple Photos:** those photos don't go; an alert says why and offers Remove from Library (LIB-62,
///   `EditorModel+KeptInPhotos`), the other photos going to the Trash.
public extension EditorModel {
    /// Moves the photos Move to Trash takes for `photo` to the Trash: the selection when `photo` is in it or isn't
    /// given, and `photo` alone when it isn't. In Develop with a version open, that version alone, unless `photo` is
    /// another file. False when Move to Trash can't run now.
    @discardableResult
    func moveToTrash(_ photo: PhotoAddress? = nil) -> Bool {
        guard canMoveToTrash, let core = library.service?.core else { return false }
        let editing = module == .develop ? openPhoto.flatMap { open in
            open.version != nil && (photo == nil || photo?.url == open.url) ? open : nil
        } : nil
        let alone = editing ?? photo.flatMap { photo in
            let selected = library.photoID(of: photo).map(photoSelection.contains) == true
                || photoSelection.isEmpty && photo == selection.map { PhotoAddress(url: $0) }
            return selected ? nil : photo
        }
        Task { [self] in
            let ids: [Int64] = if let alone {
                await LibraryService.indexIDs(of: [alone], in: core.index)[alone].map { [$0] } ?? []
            } else {
                await selectedIndexIDs()
            }
            let kept = await keptInApplePhotos(ids)
            let others = kept.isEmpty ? ids : ids.filter { !kept.contains($0) }
            if !others.isEmpty, let error = await trash(others) {
                trashFailed(error)
            }
            if !kept.isEmpty {
                await refuseTrash(keptInApplePhotos: kept)
            }
        }
        return true
    }

    /// Whether Move to Trash can run: a photo is active, the library is open, Recently Trashed isn't shown, and
    /// nothing holds the editor.
    var canMoveToTrash: Bool {
        selection != nil && library.service?.isReady == true && !library.showsRecentlyTrashed && !isModalDialogOpen
    }

    /// Whether `action` takes a key Move to Trash gives it now (`ShortcutAction.givesKeys`): Remove from Collection's ⌫
    /// where it would take photos out, in a collection or in Marked; Delete Selected Mask or Spot's in Develop's
    /// Masking
    /// and Healing tools, whether or not one is selected, so a press after the last mask leaves the photo; and Put
    /// Back's ⌘⌫ in Recently Trashed. The Masking tool's panels take the Develop panels' keys in that tool, whether or
    /// not they can run, so a key for a panel that isn't shown doesn't open a Develop panel instead. Every other
    /// action takes its keys where it can run.
    func claimsKey(_ action: ShortcutAction) -> Bool {
        switch action {
        case .deleteMask: module == .develop && (activeTool == .masking || activeTool == .heal)
        case .putBack: library.showsRecentlyTrashed
        case .maskPanelMasks, .maskPanelMask, .maskPanelAdjustments: module == .develop && activeTool == .masking
        default: canPerform(action)
        }
    }
}

extension EditorModel {
    /// Moves photos `ids` to the Trash with their pairs and all their versions, as one batch with Undo: shown at once,
    /// then made in its turn among Library's file steps, with its progress and Stop in the grid's toolbar. A version
    /// among them without its file is taken out of its file's sidecar in the same step, the file and its other
    /// versions staying (LIB-48). Why it didn't happen, or nil once it has.
    @discardableResult
    func trash(_ ids: [Int64]) async -> String? {
        guard let service = library.service, let core = service.core, service.isReady else {
            return "The library isn't open"
        }
        guard !ids.isEmpty else { return "The library hasn't read these photos yet" }
        let addresses = await service.addresses(of: ids)
        let files = ids.filter { addresses[$0]?.version == nil }
        let all = files.isEmpty ? [] : await (try? core.files.withPairs(files)) ?? files
        let before = await service.paths(of: all)
        let photos = all.compactMap { id -> (id: Int64, from: String, to: String?)? in
            before[id].map { (id, $0, nil) }
        }
        let going = Set(before.values)
        let versions = ids.compactMap { addresses[$0] }.filter { $0.version != nil && !going.contains($0.url.path) }
        guard !photos.isEmpty || !versions.isEmpty else { return nil }
        let step = LibraryFileStep(kind: .trash(all), photos: photos)
        push(step)
        var run = LibraryService.FileRun()
        if !photos.isEmpty {
            run = await fileSteps.make { [self] in
                await showingProgress("Moving to the Trash") { relay, stop in
                    await perform(step, undoing: false) {
                        await service.trash(all, progress: { relay.send($0) }, stop: stop)
                    }
                }
            }
            record(run, of: step)
        }
        if !versions.isEmpty {
            step.versions = await fileSteps.make { [self] in await removeVersions(of: versions) }
            let kept = fileSteps.undo.contains { $0 === step }
            if !step.versions.isEmpty, !kept {
                step.keep([])
                push(step)
            } else if step.versions.isEmpty, step.batch == nil, kept {
                fileSteps.undo.removeAll { $0 === step }
            }
            if !step.versions.isEmpty {
                activity.record(.action, Self.removing(step.versions, capitalised: true))
            }
        }
        if step.batch != nil && run.error == nil || !step.versions.isEmpty {
            undoNotice.say(Self.trashed(step, error: run.error))
        }
        if let error = run.error {
            return error
        }
        return photos.isEmpty && step.versions.isEmpty ? "The versions' sidecars can't be written now" : nil
    }

    /// What the notice says once `step`'s photos are in the Trash and its versions removed; with `error`, the photos
    /// didn't go.
    private static func trashed(_ step: LibraryFileStep, error: String? = nil) -> String {
        let moved: String? = if step.batch == nil || error != nil {
            nil
        } else if step.photos.count == 1, let photo = step.photos.first {
            "Moved \((photo.from as NSString).lastPathComponent) to the Trash"
        } else {
            "Moved \(step.photos.count) Photos to the Trash"
        }
        let removed = step.versions.isEmpty ? nil : removing(step.versions, capitalised: moved == nil)
        return [moved, removed].compactMap(\.self).joined(separator: " and ")
    }

    /// What removing `versions` did, in the words the notice uses for photos: "removed version “Copy 1” of
    /// DSCF1234.RAF", "removed 3 Versions".
    private static func removing(_ versions: [RemovedVersion], capitalised: Bool) -> String {
        let removed = capitalised ? "Removed" : "removed"
        guard versions.count == 1, let version = versions.first else {
            return "\(removed) \(versions.count) Versions"
        }
        return "\(removed) version “\(version.version.name)” of \(version.url.lastPathComponent)"
    }

    /// Why Move to Trash moved nothing, said in an alert.
    private func trashFailed(_ error: String) {
        guard let window = EditorWindowController.frontWindow else { return }
        let alert = NSAlert()
        alert.messageText = "The photos weren't moved to the Trash"
        alert.informativeText = error
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
