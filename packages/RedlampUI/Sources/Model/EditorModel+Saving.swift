import Foundation
import RedlampDocument

/// Why a photo's edits aren't on disk, shown until a save goes through.
public struct SaveError: Equatable, Sendable {
    public let url: URL
    public let message: String
    /// Saving again may work (permission granted, the disk back); it won't for an edit that
    /// must be left as it is.
    public let canRetry: Bool
}

/// A photo's writes that failed, and why the last one did.
struct FailedSave {
    var writes: [SaveQueue.Write]
    var error: SaveError
}

/// What saving before quitting came to.
public enum QuitSaving: Equatable, Sendable {
    case saved
    /// The disk didn't answer in time.
    case timedOut
    /// These photos' edits can't be saved.
    case unsaved([URL])
}

/// What became of each save: the filmstrip shows what is on disk, and a save that fails says so
/// and is tried again.
extension EditorModel {
    /// The status line for a photo whose edits aren't saved as usual.
    public var notice: String? {
        switch readOnlyReason {
        case .writtenByNewerVersion: "Edited in a newer version of Redlamp  ·  Changes won't be saved"
        case .unreadable: "This photo's edit file can't be read  ·  Changes won't be saved"
        case .lossy: "This edit has settings this version doesn't know  ·  Changes won't be saved"
        case nil: hasUnmergedEdits ? "Edits from another Mac couldn't be merged here  ·  They're kept as they are" : nil
        }
    }

    /// Saves what hasn't been, every photo's failed writes included, then blocks until every
    /// save has landed, or for `limit`: quitting mustn't hang on a disk that doesn't answer.
    ///
    /// It blocks rather than awaits: `terminate` can be called from inside a main-queue block,
    /// where nothing else on the main actor runs until it returns.
    public func saveBeforeQuitting(within limit: Duration = .seconds(2)) -> QuitSaving {
        for url in failedSaves.keys {
            retry(url)
        }
        saveNow()
        guard saves.flush(waitingAtMost: limit) else { return .timedOut }
        let unsaved = saves.failedPhotos
        return unsaved.isEmpty ? .saved : .unsaved(unsaved.sorted { $0.path < $1.path })
    }

    /// Saves again every photo's failed writes that may now go through.
    public func retrySave() {
        saveRetry.task?.cancel()
        for (url, failure) in failedSaves where failure.error.canRetry {
            retry(url)
        }
    }

    /// The open photo is saved as it is now, its failed edits shown in it; another's failed
    /// writes are made again, over the base its saves were tracking.
    private func retry(_ url: URL) {
        if url == selection, info != nil {
            guard !isReadOnly else { return }
            failedSaves[url] = nil
            saveNow()
        } else if let failure = failedSaves.removeValue(forKey: url) {
            failure.writes.forEach { saves.enqueue($0, for: url) }
        }
    }

    /// A write's result. A failed one is kept to be made again; otherwise only a photo's last
    /// save counts: one waiting when it finished supersedes it.
    func saved(_ url: URL, _ write: SaveQueue.Write, _ outcome: SaveQueue.Outcome, superseded: Bool) {
        if case let .failed(error) = outcome {
            failed(url, write, error)
            return
        }
        if case .sidecar = write {
            // It holds every edit made to the photo before it.
            failedSaves[url] = nil
        }
        guard !superseded else { return }
        succeeded(url)
        switch outcome {
        case .saved:
            if case let .sidecar(sidecar) = write {
                show(sidecar, for: url)
            }
        case let .replaced(base):
            show(base.sidecar, for: url)
            adopt(base, for: url)
        case .failed:
            break
        }
    }

    private func succeeded(_ url: URL) {
        guard saveError?.url == url, failedSaves[url] == nil else { return }
        if let next = failedSaves.values.first {
            saveError = next.error
            return
        }
        saveError = nil
        saveRetry.task?.cancel()
        saveRetry = (nil, .seconds(1))
    }

    private func show(_ sidecar: Sidecar?, for url: URL) {
        library.update(url) { item in
            item.hasEdits = sidecar.map { !$0.recipe.isPristine } ?? false
            item.metadata = sidecar?.metadata ?? PhotoMetadata()
        }
    }

    private func failed(_ url: URL, _ write: SaveQueue.Write, _ error: any Error) {
        showOnDisk(url)
        let protection = Self.protection(of: error)
        if protection != nil, case .metadata = write {
            // A rating made as a protected photo opened: it opens read-only and says why.
            return
        }
        if let protection, url == selection {
            readOnlyReason = protection
        }
        let name = url.deletingPathExtension().lastPathComponent
        let reason = protection.map(Self.reason) ?? Self.reason(error)
        let saveError = SaveError(
            url: url,
            message: "Edits to \(name) can't be saved: \(reason)",
            canRetry: protection == nil,
        )
        self.saveError = saveError
        var writes = failedSaves[url]?.writes ?? []
        if case .sidecar = write {
            writes = [write]
        } else {
            writes.append(write)
        }
        failedSaves[url] = FailedSave(writes: writes, error: saveError)
        if protection == nil {
            retryLater()
        }
    }

    /// The filmstrip item as its sidecar is now.
    private func showOnDisk(_ url: URL) {
        Task { [saves, library] in
            let store = saves.store
            let summary = await saves.read { store.summary(for: url) ?? SidecarSummary() }
            guard !saves.isPending(url) else { return }
            library.update(url) { item in
                item.hasEdits = summary.hasEdits
                item.metadata = summary.metadata
            }
        }
    }

    /// Tries again after a wait that doubles each time, up to 30 s, so a failing disk isn't flooded.
    private func retryLater() {
        saveRetry.task?.cancel()
        let delay = saveRetry.delay
        saveRetry = (Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.retrySave()
        }, min(delay * 2, .seconds(30)))
    }

    private static func protection(of error: any Error) -> SidecarProtection? {
        switch error as? SidecarStoreError {
        case .writtenByNewerVersion: .writtenByNewerVersion
        case .unreadable: .unreadable
        case .lossy: .lossy
        case nil: nil
        }
    }

    /// Found on disk when saving, so after the photo opened.
    private static func reason(_ protection: SidecarProtection) -> String {
        switch protection {
        case .writtenByNewerVersion: "a newer version of Redlamp changed it since it opened"
        case .unreadable: "its edit file changed and can't be read"
        case .lossy: "it now has settings this version doesn't know"
        }
    }

    private static func reason(_ error: any Error) -> String {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = [error, underlying].compactMap(\.self).first { $0.domain == NSPOSIXErrorDomain }
        return posix.flatMap { reason(posix: Int32($0.code)) }
            ?? (error.domain == NSCocoaErrorDomain ? reason(cocoa: error.code) : nil)
            ?? error.localizedDescription
    }

    private static func reason(posix code: Int32) -> String? {
        switch code {
        case EACCES, EPERM: "permission denied"
        case EROFS: "the disk is read-only"
        case ENOSPC, EDQUOT, EFBIG: "the disk is full"
        case ENOENT, ENOTDIR: "its folder can't be found"
        default: nil
        }
    }

    private static func reason(cocoa code: Int) -> String? {
        switch code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: "permission denied"
        case NSFileWriteVolumeReadOnlyError: "the disk is read-only"
        case NSFileWriteOutOfSpaceError: "the disk is full"
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: "its folder can't be found"
        default: nil
        }
    }
}
