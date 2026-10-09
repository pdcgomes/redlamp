import Foundation
import RedlampLibrary

/// Library Health in the editor (LIB-40): a check's proposals drawn in the grid (`HealthProposals`, `HealthMark`),
/// accepted as one batch the sheet confirms (`HealthSheet`), to the Trash only or, for wrong extensions, as renames,
/// and findings kept anyway, each from the grid's menu, the Library and Photo menus and the palette, and each one
/// change Library's ⌘Z takes back (`EditorModel+HealthUndo`).
///
/// - **Accept Health Proposals…** acts on the check's proposals, never on a photo the check lists apart unless it's
///   selected and the sheet's box is ticked. The batch is checked again just before it runs, in the library's changes'
///   turn, and goes through the file operations' journal, so Recently Trashed's Put Back brings its photos back after
///   Undo has gone.
/// - **Keep Anyway** takes the selection's findings out of the check shown, kept in `Definitions/Health.json` by what
///   each photo holds, so the check doesn't list them again until the photo changes; a duplicate's keeps its group,
///   until another copy appears.
/// - **List Again in Library Health,** in Kept Anyway's list, takes back what kept the selection's photos.
public extension EditorModel {
    /// The Library Health check shown, while its findings are in.
    internal var shownHealthCheck: HealthCheck.Kind? {
        guard module == .library, case let .health(kind)? = librarySources.shown,
              healthProposals.offer?.check == kind
        else { return nil }
        return kind
    }

    /// Accept Health Proposals…: the sheet that confirms the batch carrying out the check's proposals.
    @discardableResult
    func acceptHealthProposals() -> Bool {
        guard canAcceptHealthProposals, let findings = healthProposals.findings,
              let core = library.service?.core
        else { return false }
        let requested = ContinuousClock.now
        let apart = Set(findings.findings.lazy.filter { $0.apart != nil }.map(\.photo))
        let selected = apart.isEmpty ? [] : selectedPhotos.compactMap(librarySources.indexID(ofShown:))
        let sheet = HealthSheetModel(
            findings: findings, selectedApart: selected.filter(apart.contains),
            health: healthProposals.library(core), requested: requested,
        )
        return HealthSheetController.present(sheet, editor: self, requested: requested) != nil
    }

    /// Whether Accept Health Proposals… has a batch to confirm: the check shown proposes something, or lists apart
    /// something the user may choose.
    internal var canAcceptHealthProposals: Bool {
        !isModalDialogOpen && shownHealthCheck != nil && library.service?.isReady == true
            && healthProposals.offer?.canAccept == true
    }

    /// Keep Anyway: the findings of `photo`, or of the selection it's in, taken out of the check shown until the photo
    /// changes, as one change with Undo, taking its turn now.
    @discardableResult
    func keepAnyway(_ photo: URL? = nil) -> Bool {
        guard canKeepAnyway, let findings = healthProposals.findings, let core = library.service?.core else {
            return false
        }
        let urls = photosActedOn(from: photo)
        let health = healthProposals.library(core)
        let step = HealthStep(.keptAnyway([]), title: "Keep Anyway")
        pushHealthStep(step)
        healthSteps.enqueue { [weak self] in
            guard let self else { return }
            let ids = await librarySources.indexIDs(of: urls)
            let wanted = Set(ids)
            let chosen = findings.findings.filter { wanted.contains($0.photo) }
            let result = await core.change { () -> Result<[KeptAnyway], any Error> in
                do {
                    return try await .success(health.keepAnyway(ids, in: findings))
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case let .success(entries) where !entries.isEmpty:
                let groups = Set(chosen.compactMap(\.group)).count
                step.kind = .keptAnyway(entries)
                step.title = HealthWords.keptAnyway(findings.check.kind, photos: chosen.count, groups: groups)
                activity.record(.action, step.title)
            case .success:
                dropHealthStep(step)
            case let .failure(error):
                dropHealthStep(step)
                activity.record(.error, "Keep Anyway wasn't done: \(LibraryService.describe(error))")
            }
        }
        return true
    }

    internal var canKeepAnyway: Bool {
        !isModalDialogOpen && shownHealthCheck != nil && selection != nil && healthProposals.offer?.hasFindings == true
    }

    /// List Again in Library Health: what keeps `photo`, or the selection it's in, taken back from Kept Anyway, so the
    /// checks list them again; one change with Undo, taking its turn now.
    @discardableResult
    func listAgain(_ photo: URL? = nil) -> Bool {
        guard canListAgain, let core = library.service?.core else { return false }
        let urls = photosActedOn(from: photo)
        let health = healthProposals.library(core)
        let step = HealthStep(.listedAgain([]), title: "List Again")
        pushHealthStep(step)
        healthSteps.enqueue { [weak self] in
            guard let self else { return }
            let ids = await Set(librarySources.indexIDs(of: urls))
            let result = await core.change { () -> Result<[KeptAnyway], any Error> in
                do {
                    let kept = try await health.keptAnyway().filter { !ids.isDisjoint(with: $0.photos) }.map(\.kept)
                    try await health.takeBack(kept)
                    return .success(kept)
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case let .success(entries) where !entries.isEmpty:
                step.kind = .listedAgain(entries)
                step.title = HealthWords.listedAgain(photos: ids.count)
                activity.record(.action, step.title)
            case .success:
                dropHealthStep(step)
            case let .failure(error):
                dropHealthStep(step)
                activity.record(.error, "List Again wasn't done: \(LibraryService.describe(error))")
            }
        }
        return true
    }

    internal var canListAgain: Bool {
        !isModalDialogOpen && module == .library && librarySources.shown == .keptAnyway && selection != nil
    }
}

extension EditorModel {
    /// Runs the batch `sheet` planned, its photos' saves first, in the library's changes' turn, with its progress in
    /// the sheet; on Undo once it has run. False, the sheet saying why, when it didn't.
    func acceptHealthPlan(_ sheet: HealthSheetModel) async -> Bool {
        guard let plan = sheet.plan, let core = library.service?.core else { return false }
        let health = healthProposals.library(core)
        sheet.running(done: 0, total: plan.batch.steps.count)
        let urls = plan.photos.compactMap(plan.path(of:)).map { URL(fileURLWithPath: $0) }
        if let selection, urls.contains(selection) {
            saveNow()
        }
        await waitForHealthSaves(of: urls)
        let relay = FileProgressRelay { [weak sheet] progress in
            sheet?.running(done: progress.done, total: progress.total)
        }
        let result = await core.change { () -> Result<FileOutcome, any Error> in
            do {
                return try await .success(health.run(plan) { relay.send($0) })
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case let .success(outcome):
            let step = HealthStep(
                .batch(check: plan.check, photos: plan.photos, chosen: sheet.chosen), title: outcome.title,
            )
            step.batch = outcome.batch
            pushHealthStep(step)
            library.countFolders()
            activity.record(.action, outcome.title)
            return true
        case let .failure(error):
            let message = HealthWords.failure(error)
            sheet.failed(message)
            activity.record(.error, "\(plan.batch.title) wasn't done: \(message)")
            return false
        }
    }

    /// The photos an action from `photo`'s menu reaches: the selection when `photo` is in it or not given, `photo`
    /// alone when it isn't.
    private func photosActedOn(from photo: URL?) -> [URL] {
        if let photo, photo != selection, library.photoID(of: photo).map(photoSelection.contains) != true {
            return [photo]
        }
        return selectedPhotos
    }

    /// Returns once the saves asked for any of `photos` before the call are on disk, so what goes to the Trash goes as
    /// they leave it.
    func waitForHealthSaves(of photos: [URL]) async {
        let saves = saves
        for photo in await Task.detached(priority: .userInitiated, operation: { saves.pending(photos) }).value {
            await saves.wait(for: photo)
        }
    }
}
