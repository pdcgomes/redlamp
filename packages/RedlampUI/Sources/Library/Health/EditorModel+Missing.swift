import AppKit
import Foundation
import RedlampLibrary

/// Library Health's Missing check in the editor (DEC-59): the photos whose files went from their folders outside
/// Redlamp, which no other list shows, drawn from the store's thumbnails, each saying where it was and when it went.
///
/// - **Locate…** asks for a photo's file in an Open panel on the editor window, in the library's folders, and relinks
/// the
///   photo to a file with its content, keeping its row and everything decided about it; it offers to relink too the
///   other missing photos of its folder found beside the file, under their names and with their content.
/// - **Remove from Library** takes the photo, or the selection it's in, out of the library; nothing on disk changes.
///
/// Each is one batch of the file operations' journal, checked again just before it runs, and one change in Library's
/// order for Undo (`EditorModel+HealthUndo`). The photos' files aren't there, so from the check Develop, culling and
/// everything else that would write to them is off, leaving Library's views, moving about, Locate…, Remove and Undo.
public extension EditorModel {
    /// Locate…: the file of `photo`, or of the active photo, chosen in an Open panel, then the photo relinked to it as
    /// one batch, with the others of its folder found beside it when the user says so. False when it can't start.
    @discardableResult
    func locateMissingPhoto(_ photo: URL? = nil) -> Bool {
        guard canLocateMissingPhoto, let target = photo ?? selection, let core = library.service?.core,
              let id = librarySources.indexID(ofShown: target), let findings = healthProposals.findings,
              case let .missing(folder, _)? = findings.finding(for: id)?.reason
        else { return false }
        let health = healthProposals.library(core)
        let name = target.lastPathComponent
        if let answer = LocatePanel.answer {
            Task { await locate(id, named: name, at: answer, in: findings, health: health) }
            return true
        }
        guard let window = EditorWindowController.frontWindow, window.attachedSheet == nil else { return false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Locate"
        panel.message = "Choose the file of “\(name)” in the library's folders."
        panel.directoryURL = Self.nearestFolder(to: URL(fileURLWithPath: folder, isDirectory: true))
        let delegate = LocatePanel(roots: library.roots.map(\.url))
        panel.delegate = delegate
        isModalDialogOpen = true
        panel.beginSheetModal(for: window) { [self] response in
            MainActor.assumeIsolated {
                withExtendedLifetime(delegate) {}
                isModalDialogOpen = false
                guard response == .OK, let url = panel.url else { return }
                Task { await locate(id, named: name, at: url, in: findings, health: health) }
            }
        }
        return true
    }

    /// Remove from Library: the missing photos of `photo`, or of the selection it's in, taken out of the library as one
    /// batch, nothing on disk changing, which Library's Undo puts back. False when there's nothing to remove.
    @discardableResult
    func removeMissingPhotos(_ photo: URL? = nil) -> Bool {
        guard canRemoveMissingPhotos, let core = library.service?.core, let findings = healthProposals.findings else {
            return false
        }
        let ids: [Int64] = if let photo, photo != selection, let id = librarySources.indexID(ofShown: photo),
                              !photoSelection.contains(id) {
            [id]
        } else {
            selectedIDs
        }
        let health = healthProposals.library(core)
        healthSteps.enqueue { [weak self] in
            guard let self else { return }
            let result = await core.change { () -> Result<FileOutcome, any Error> in
                do {
                    return try await .success(health.run(health.planRemoval(ids, in: findings)))
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case let .success(outcome):
                let step = HealthStep(.remove(outcome.photoIDs), title: outcome.title)
                step.batch = outcome.batch
                pushHealthStep(step)
                library.countFolders()
                activity.record(.action, outcome.title)
            case let .failure(error):
                activity.record(.error, "Remove from Library wasn't done: \(HealthWords.failure(error))")
            }
        }
        return true
    }
}

extension EditorModel {
    /// Whether the grid shows the Missing check, whose photos' files aren't there.
    var showsMissingPhotos: Bool {
        module == .library && librarySources.shown == .health(.missing)
    }

    var canLocateMissingPhoto: Bool {
        !isModalDialogOpen && showsMissingPhotos && selection != nil && library.service?.isReady == true
            && healthProposals.offer?.hasFindings == true
    }

    var canRemoveMissingPhotos: Bool {
        canLocateMissingPhoto
    }

    /// Relinks the missing photo `id` to the file at `url` once Locate… finds it's the photo, with the others found
    /// beside it when the user says so; otherwise says why it wasn't.
    private func locate(
        _ id: Int64, named name: String, at url: URL, in findings: HealthFindings, health: LibraryHealth,
    ) async {
        let location: MissingLocation
        do {
            location = try await health.locate(id, at: url)
        } catch {
            return locateFailed(name, LibraryService.describe(error) + ".")
        }
        guard let photo = location.photo else {
            let problem = location.problem ?? .differs
            return locateFailed(name, HealthWords.notRelinked(because: problem, file: url.lastPathComponent))
        }
        var relinks = [photo]
        if !location.others.isEmpty, await relinksOthers(location.others, beside: url, in: findings) {
            relinks += location.others
        }
        relink(relinks, in: findings, health: health)
    }

    /// Relinks `relinks` as one batch in the library's changes' turn, then has their folders listed again, so each
    /// photo is read from its file; on Undo once it has run.
    private func relink(_ relinks: [PhotoRelink], in findings: HealthFindings, health: LibraryHealth) {
        guard let core = library.service?.core else { return }
        healthSteps.enqueue { [weak self] in
            guard let self else { return }
            let result = await core.change { () -> Result<FileOutcome, any Error> in
                do {
                    return try await .success(health.run(health.planRelink(relinks, in: findings)))
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case let .success(outcome):
                let step = HealthStep(.relink(relinks), title: outcome.title)
                step.batch = outcome.batch
                pushHealthStep(step)
                library.countFolders()
                library.service?.look(at: Self.folders(of: relinks))
                activity.record(.action, outcome.title)
            case let .failure(error):
                activity.record(.error, "Locate wasn't done: \(HealthWords.failure(error))")
            }
        }
    }

    /// Asks whether to relink `others` too, the missing photos found beside the file at `url`.
    private func relinksOthers(_ others: [PhotoRelink], beside url: URL, in findings: HealthFindings) async -> Bool {
        if let answer = LocatePanel.relinksOthers {
            return answer
        }
        guard let window = EditorWindowController.frontWindow else { return false }
        let names = others.map { ($0.path as NSString).lastPathComponent }
        let from = others.first.flatMap { findings.finding(for: $0.id) }.flatMap { finding -> String? in
            guard case let .missing(folder, _) = finding.reason else { return nil }
            return (folder as NSString).lastPathComponent
        } ?? ""
        let alert = NSAlert()
        alert.messageText = HealthWords.relinkOthers(others.count)
        alert.informativeText = HealthWords.foundBeside(
            names, from: from, in: url.deletingLastPathComponent().lastPathComponent,
        )
        alert.addButton(withTitle: "Relink All").setAccessibilityIdentifier("missing.relinkAll")
        alert.addButton(withTitle: "Only This One").setAccessibilityIdentifier("missing.relinkOne")
        isModalDialogOpen = true
        defer { isModalDialogOpen = false }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    private func locateFailed(_ name: String, _ message: String) {
        activity.record(.error, "\(HealthWords.notRelinked(name)): \(message)")
        guard LocatePanel.answer == nil, let window = EditorWindowController.frontWindow else { return }
        let alert = NSAlert()
        alert.messageText = HealthWords.notRelinked(name)
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in }
    }

    /// The folders of the files `relinks` found their photos as.
    static func folders(of relinks: [PhotoRelink]) -> [URL] {
        Array(Set(relinks.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }))
    }

    /// `folder`, or the nearest folder above it that's there.
    private static func nearestFolder(to folder: URL) -> URL {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return url
    }

    /// What the Missing check leaves on while it's shown: Library's views, moving about, the panels, Locate…, Remove,
    /// Undo and Redo, and what reaches no photo.
    static let actionsInMissingPhotos: Set<ShortcutAction> = actionsInRecentlyTrashed
        .subtracting([.showInFinder, .showRecentlyTrashed, .putBack, .putBackBatch])
        .union([.locateMissingPhoto, .removeMissingPhotos, .undo, .redo, .toggleFilterBar, .toggleFilters])

    /// Locate… and Remove, and in the Missing check every action it leaves off; nil for every other.
    func performMissingShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .locateMissingPhoto: return locateMissingPhoto()
        case .removeMissingPhotos: return removeMissingPhotos()
        default:
            guard showsMissingPhotos, !Self.actionsInMissingPhotos.contains(action) else { return nil }
            return false
        }
    }

    /// Whether `performMissingShortcut` would do something now; nil for the actions it leaves alone.
    func canPerformMissingShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .locateMissingPhoto: canLocateMissingPhoto
        case .removeMissingPhotos: canRemoveMissingPhotos
        default: showsMissingPhotos && !Self.actionsInMissingPhotos.contains(action) ? false : nil
        }
    }
}

/// What the Open panel lets Locate… choose: any folder to go through, and a file in the library's folders.
@MainActor
final class LocatePanel: NSObject, NSOpenSavePanelDelegate {
    /// The file the regression suite chooses, as the panel, which it can't drive, would.
    static var answer: URL?
    /// Whether the regression suite relinks the others found beside the file, as the alert's buttons would say.
    static var relinksOthers: Bool?

    private let roots: [URL]

    init(roots: [URL]) {
        self.roots = roots
    }

    func panel(_: Any, validate url: URL) throws {
        guard MoveFolderPanel.isInLibrary(url, roots: roots) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) isn't in the library's folders",
                NSLocalizedRecoverySuggestionErrorKey: "Choose a file in Folders, or add its folder there first.",
            ])
        }
    }
}

@_spi(Harness) public extension EditorModel {
    /// The file Locate… takes as chosen, and whether it relinks the others found beside it, for the regression suite.
    static func answerLocate(with file: URL?, relinkingOthers: Bool? = nil) {
        LocatePanel.answer = file
        LocatePanel.relinksOthers = relinkingOthers
    }
}
