import Darwin
import Foundation
import RedlampLibrary
import Synchronization

/// Move Edits and Metadata… (LIB-11, DEC-43): a root's `.redlamp` sidecars moved between beside its photos and Redlamp
/// on
/// this Mac through the library's `LibrarySidecars.move`, which copies each one, checks the copy byte for byte and only
/// then removes the original, never replacing a sidecar that's there.
///
/// - **In parts** of a few hundred, so Cancel stops the move between two of them. Putting back is a move the other way
///   of every sidecar in the place they were going, so the root is left with all of them where it keeps them.
/// - **In the library's changes' turn** (`LibraryCore.change`), all its parts: no batch, Undo or XMP sync writes a
///   sidecar meanwhile, which would write it in the place the move is leaving.
/// - **The placement** is the destination's from before the first part, so the library's reads and saves, and the app's
///   through its locator, find each sidecar wherever it is meanwhile. Put back, or with nothing moved, it's set back.
/// - **After a quit**, the library finishes the part its journal holds as it opens; the move itself is in the defaults
///   (`SidecarMoveRecord`) until it's over, and its rest is planned again from the disk and moved (`finish`).
enum SidecarMoveJob {
    /// Sidecars moved at a time: Cancel waits for one part at most.
    static let part = 256

    /// What a move did, and how it ended.
    struct Result: Sendable {
        /// The sidecars it set out to move.
        var total = 0
        var outcome = SidecarMoveOutcome()
        /// Cancel stopped it, and what putting back did.
        var putBack: SidecarMoveOutcome?
        /// Photos with a sidecar in each place, which stop a move before it starts.
        var conflicts: [SidecarMovePlan.Conflict] = []
        /// Why it stopped, in words.
        var error: String?

        /// Every sidecar it was to move failed, so it set the placement back.
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
        await core.change {
            await move(
                root: root, to: destination, first: first, sidecars: core.sidecars, control: control, placed: placed,
                progress: progress,
            )
        }
    }

    /// Finishes the move `record` keeps, which a quit interrupted, as `run` does: the part the library's journal holds
    /// first, which the library finishes as it opens (or here, should that have failed), then the rest. Nil when its
    /// root isn't in the library any more.
    static func finish(
        _ record: SidecarMoveRecord, core: LibraryCore, control: SidecarMoveControl,
        placed: @escaping @Sendable () async -> Void, progress: @escaping @Sendable (FileProgress) -> Void,
    ) async -> Result? {
        let sidecars = core.sidecars
        let journal = sidecars.moveJournal
        for _ in 0 ..< 600 where FileManager.default.fileExists(atPath: journal.path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let path = record.root
        guard let root = try? await core.index.read({ try $0.root(path: path) }) ?? nil else { return nil }
        return await core.change {
            if FileManager.default.fileExists(atPath: journal.path) {
                do {
                    _ = try await sidecars.resumeMove()
                } catch {
                    var failed = Result()
                    failed.error = describe(error)
                    return failed
                }
            }
            return await move(
                root: root.id, to: record.destination, first: nil, sidecars: sidecars, control: control, placed: placed,
                progress: progress,
            )
        }
    }

    private static func move(
        root: Int64, to destination: RootRecord.Sidecars, first: String?, sidecars: LibrarySidecars,
        control: SidecarMoveControl, placed: @Sendable () async -> Void,
        progress: @escaping @Sendable (FileProgress) -> Void,
    ) async -> Result {
        var result = Result()
        let source: RootRecord.Sidecars = destination == .onThisMac ? .besidePhotos : .onThisMac
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
            try await sidecars.setPlacement(destination, forRoot: root)
            await placed()
            let total = plan.items.count
            let (outcome, stopped) = try await moveInParts(plan, sidecars, control: control) { done in
                progress(FileProgress(done: done, total: total))
            }
            result.outcome = outcome
            if stopped {
                var back = try await sidecars.planMove(ofRoot: root, to: source)
                back.conflicts = []
                try await sidecars.setPlacement(source, forRoot: root)
                let returning = back.items.count
                result.putBack = try await moveInParts(back, sidecars, control: nil) { done in
                    progress(FileProgress(done: done, total: returning, isRollingBack: true))
                }.outcome
                await placed()
            } else if result.movedNothing {
                try await sidecars.setPlacement(source, forRoot: root)
                await placed()
            }
        } catch {
            result.error = describe(error)
        }
        return result
    }

    /// Moves `plan`'s sidecars a part at a time, until `control` stops it between two parts.
    private static func moveInParts(
        _ plan: SidecarMovePlan, _ sidecars: LibrarySidecars, control: SidecarMoveControl?,
        progress: @escaping @Sendable (Int) -> Void,
    ) async throws -> (outcome: SidecarMoveOutcome, stopped: Bool) {
        var outcome = SidecarMoveOutcome()
        var start = 0
        while start < plan.items.count {
            if control?.isCancelled == true {
                return (outcome, true)
            }
            var part = plan
            part.items = Array(plan.items[start ..< min(start + Self.part, plan.items.count)])
            part.conflicts = []
            let before = start
            let moved = try await sidecars.move(part) { done, _ in progress(before + done) }
            outcome.moved += moved.moved
            outcome.gone += moved.gone
            outcome.conflicts += moved.conflicts
            outcome.failed.merge(moved.failed) { first, _ in first }
            start += part.items.count
        }
        return (outcome, control?.isCancelled == true)
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

    /// Why Redlamp can't write in `folder`, a root its sidecars would move into, in words; nil when it can. A local
    /// volume says so without anything written. With `probing`, a network volume, whose share may refuse writes its
    /// permissions allow, has a hidden file made there and removed, named as an interrupted save's leftover so a share
    /// that lets it be made but not removed has it removed with them.
    static func whyNotWritable(_ folder: URL, probing: Bool) -> String? {
        let name = folder.lastPathComponent
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .volumeIsReadOnlyKey, .volumeIsLocalKey]
        guard let values = try? URL(fileURLWithPath: folder.path).resourceValues(forKeys: keys),
              values.isDirectory == true
        else { return "“\(name)” isn't there: its disk may not be connected" }
        if values.volumeIsReadOnly == true {
            return "“\(name)” is on a disk that's read-only"
        }
        if access(folder.path, W_OK) != 0 {
            return "Redlamp doesn't have permission to write in “\(name)”"
        }
        guard probing, values.volumeIsLocal != true else { return nil }
        let probe = folder.appending(path: ".redlamp-probe.redlamp.\(UUID().uuidString)").path
        let descriptor = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return "The server doesn't let Redlamp write in “\(name)”" }
        var byte: UInt8 = 0
        let wrote = write(descriptor, &byte, 1) == 1
        let closed = close(descriptor) == 0
        let removed = unlink(probe) == 0
        return wrote && closed && removed ? nil : "The server doesn't let Redlamp write in “\(name)”"
    }
}

/// A move of a root's sidecars under way, as the defaults keep it from Move until it's over, so a launch after a quit
/// finishes it (`SidecarMoveJob.finish`).
struct SidecarMoveRecord: Codable, Sendable, Equatable {
    /// The root's path, as the index keeps it.
    var root: String
    /// Where its sidecars are going: the other way once Cancel turns the move round to put them back.
    var destination: RootRecord.Sidecars
    /// Cancel turned it round.
    var puttingBack = false

    static let defaultsKey = "library.sidecarMove"

    static func saved(in defaults: UserDefaults?) -> SidecarMoveRecord? {
        guard let data = defaults?.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SidecarMoveRecord.self, from: data)
    }

    func save(in defaults: UserDefaults?) {
        defaults?.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    static func remove(from defaults: UserDefaults?) {
        defaults?.removeObject(forKey: defaultsKey)
    }
}

/// Cancel, from the main thread, for a move running elsewhere.
final class SidecarMoveControl: Sendable {
    private let cancelled = Mutex(false)

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}
