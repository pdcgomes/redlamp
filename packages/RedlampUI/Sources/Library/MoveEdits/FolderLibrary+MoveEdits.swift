import Foundation

/// A move of a root's edits and metadata a quit interrupted (LIB-11), found as the library opens.
extension FolderLibrary {
    /// Calls `handler` with the move of a root's edits and metadata a quit interrupted, once the library is open, if
    /// the defaults keep one.
    func followUnfinishedSidecarMove(_ handler: @escaping @MainActor (SidecarMoveRecord) -> Void) {
        unfinishedSidecarMove = handler
        findUnfinishedSidecarMove()
    }

    /// Once the library is open and someone follows: the move the defaults keep, once a launch.
    func findUnfinishedSidecarMove() {
        guard !lookedForSidecarMove, let handler = unfinishedSidecarMove, service?.isReady == true else { return }
        lookedForSidecarMove = true
        if let record = SidecarMoveRecord.saved(in: defaults) {
            handler(record)
        }
    }
}
