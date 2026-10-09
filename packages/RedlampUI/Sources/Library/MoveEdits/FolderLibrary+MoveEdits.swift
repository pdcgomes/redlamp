import Foundation
import RedlampLibrary

/// A move of a root's edits and metadata a quit interrupted (LIB-11), found as the library opens.
extension FolderLibrary {
    /// Calls `handler` with the move of a root's edits and metadata a quit interrupted, once the library is open, if
    /// the library's journal holds one.
    func followUnfinishedSidecarMove(_ handler: @escaping @MainActor (SidecarMoveJournal) -> Void) {
        unfinishedSidecarMove = handler
        findUnfinishedSidecarMove()
    }

    /// Once the library is open and someone follows: the move the library's journal holds, once a launch.
    func findUnfinishedSidecarMove() {
        guard !lookedForSidecarMove, let handler = unfinishedSidecarMove, service?.isReady == true,
              let sidecars = service?.core?.sidecars
        else { return }
        lookedForSidecarMove = true
        Task {
            if let journal = try? await sidecars.unfinishedMove() {
                handler(journal)
            }
        }
    }
}
