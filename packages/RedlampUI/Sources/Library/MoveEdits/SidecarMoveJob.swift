import Foundation
import RedlampLibrary

/// Move Edits and Metadata… (LIB-11, DEC-43): a root's `.redlamp` sidecars moved between beside its photos and Redlamp
/// on this Mac through the library's `LibrarySidecars.move`, which copies each one, checks the copy byte for byte and
/// only then removes the original, never replacing a sidecar that's there, a part of a few hundred at a time, the whole
/// move in its journal until it's over.
///
/// - **In the library's changes' turn** (`LibraryCore.change`): no batch, Undo or XMP sync writes a sidecar meanwhile,
///   which would write it in the place the move is leaving.
/// - **Cancel** stops the move after the part under way, and the library puts back every sidecar in the place they
///   were going, so the root is left with all of them where it keeps them.
/// - **The placement** is the destination's from before the first part, so the library's reads and saves, and the app's
///   through its locator (`placed`), find each sidecar wherever it is meanwhile. Put back, or with nothing moved, it's
///   set back.
/// - **After a quit**, the library's journal holds the move, which the next launch finishes (`finish`).
enum SidecarMoveJob {
    /// What a move did, and how it ended.
    struct Result: Sendable {
        /// The sidecars it set out to move.
        var total = 0
        var outcome = SidecarMoveOutcome()
        /// Photos with a sidecar in each place, which stop a move before it starts.
        var conflicts: [SidecarMovePlan.Conflict] = []
        /// Why it stopped, in words.
        var error: String?

        /// Cancel stopped it, and what putting back did.
        var putBack: SidecarPutBack? {
            outcome.putBack
        }

        /// Every sidecar it was to move failed, so the placement stayed as it was.
        var movedNothing: Bool {
            putBack == nil && error == nil && outcome.moved == 0 && !outcome.failed.isEmpty
        }
    }

    /// Moves `root`'s sidecars to `destination` in the library's changes' turn, `first` (a photo's path below the root)
    /// before the others. `placed` hears each change of placement, for the app's locator.
    static func run(
        root: Int64, to destination: RootRecord.Sidecars, first: String? = nil, core: LibraryCore,
        control: SidecarMoveControl, placed: @escaping @Sendable () async -> Void,
        progress: @escaping @Sendable (FileProgress) -> Void,
    ) async -> Result {
        let sidecars = core.sidecars
        return await core.change {
            var result = Result()
            do {
                var plan = try await sidecars.planMove(ofRoot: root, to: destination)
                guard plan.conflicts.isEmpty else {
                    result.conflicts = plan.conflicts
                    return result
                }
                if let first, let index = plan.items.firstIndex(where: { $0.photo == first }) {
                    plan.items.insert(plan.items.remove(at: index), at: 0)
                }
                result.total = plan.items.count
                result.outcome = try await sidecars.move(plan, control: control, placed: placed, progress: progress)
            } catch {
                result.error = describe(error)
            }
            return result
        }
    }

    /// Finishes the move the library's journal holds, which a quit interrupted, as `run` does: forwards, or putting
    /// back what moved when Cancel had turned it round. Nil when there's none.
    static func finish(
        core: LibraryCore, control: SidecarMoveControl, placed: @escaping @Sendable () async -> Void,
        progress: @escaping @Sendable (FileProgress) -> Void,
    ) async -> Result? {
        let sidecars = core.sidecars
        return await core.change { () -> Result? in
            do {
                guard let journal = try await sidecars.unfinishedMove() else { return nil }
                var result = Result(total: journal.plan.items.count)
                guard var outcome = try await sidecars.resumeMove(control: control, placed: placed, progress: progress)
                else { return nil }
                if journal.puttingBack, let back = outcome.putBack {
                    // Putting back was the move it finished.
                    outcome = SidecarMoveOutcome()
                    outcome.moved = back.moved
                    outcome.failed = back.failed
                }
                result.outcome = outcome
                return result
            } catch {
                var failed = Result()
                failed.error = describe(error)
                return failed
            }
        }
    }

    // MARK: - Words

    /// What went wrong, in words: an error's own description rather than its domain and code.
    static func describe(_ error: any Error) -> String {
        if case let LibrarySidecarsError.conflicts(conflicts) = error {
            return "\(conflicts.count) photos have edits and metadata in both places"
        }
        if case LibrarySidecarsError.noSuchRoot = error {
            return "the folder isn't in the library any more"
        }
        let cocoa = error as NSError
        guard error is LocalizedError || [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(cocoa.domain) else {
            return reason(String(describing: error))
        }
        return reason(cocoa.localizedDescription)
    }

    /// A reason the library gave as text, as a sentence's end: the description an error carries, without its domain,
    /// code and user info, and without a full stop.
    static func reason(_ text: String) -> String {
        var reason = text
        if let quoted = text.range(of: #"Code=-?\d+ "(.*?)"( UserInfo=|$)"#, options: .regularExpression) {
            let inner = text[quoted].drop { $0 != "\"" }.dropFirst()
            reason = String(inner.prefix { $0 != "\"" })
        }
        reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while reason.hasSuffix(".") {
            reason.removeLast()
        }
        guard let first = reason.first, !reason.dropFirst().prefix(1).allSatisfy(\.isUppercase) else { return reason }
        return first.lowercased() + reason.dropFirst()
    }

    // MARK: - Writing beside the photos

    /// Why Redlamp can't write in `folder`, a root its sidecars would move into, in words; nil when it can
    /// (`LibrarySidecars.writeAccess`). With `probing`, a network volume's share is tried with a file made and removed.
    static func whyNotWritable(_ folder: URL, probing: Bool) -> String? {
        let name = folder.lastPathComponent
        return switch LibrarySidecars.writeAccess(in: folder, probing: probing) {
        case .writable: nil
        case .missing: "“\(name)” isn't there: its disk may not be connected"
        case .readOnly: "“\(name)” is on a disk that's read-only"
        case .notPermitted: "Redlamp doesn't have permission to write in “\(name)”"
        case .refused: "The server doesn't let Redlamp write in “\(name)”"
        }
    }
}
