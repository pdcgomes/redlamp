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

    /// Saves what hasn't been, then blocks until every save has landed, or for `limit`: quitting
    /// mustn't hang on a disk that doesn't answer. False if the time ran out.
    ///
    /// It blocks rather than awaits: `terminate` can be called from inside a main-queue block,
    /// where nothing else on the main actor runs until it returns.
    public func saveBeforeQuitting(within limit: Duration = .seconds(2)) -> Bool {
        saveNow()
        return saves.flush(waitingAtMost: limit)
    }

    /// Saves again what failed: the open photo as it is now, or the last write of the one left.
    public func retrySave() {
        guard let error = saveError, error.canRetry else { return }
        saveRetry.task?.cancel()
        if error.url == selection, info != nil {
            saveNow()
        } else if let failedSave {
            saves.enqueue(failedSave, for: error.url)
        }
    }

    /// A write's result. Only a photo's last save counts: one waiting when it finished supersedes it.
    func saved(_ url: URL, _ write: SaveQueue.Write, _ outcome: SaveQueue.Outcome, superseded: Bool) {
        guard !superseded else { return }
        switch outcome {
        case .saved:
            succeeded(url)
            if case let .sidecar(sidecar) = write {
                show(sidecar, for: url)
            }
        case let .replaced(base):
            succeeded(url)
            show(base.sidecar, for: url)
            adopt(base, for: url)
        case let .failed(error):
            failed(url, write, error)
        }
    }

    private func succeeded(_ url: URL) {
        guard saveError?.url == url else { return }
        saveError = nil
        failedSave = nil
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
        saveError = SaveError(
            url: url,
            message: "Edits to \(name) can't be saved: \(reason)",
            canRetry: protection == nil,
        )
        failedSave = write
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
