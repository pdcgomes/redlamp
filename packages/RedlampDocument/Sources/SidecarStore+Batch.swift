import Foundation
import Synchronization

/// What a batch makes of one photo's sidecar, decided from the sidecar as the batch reads it.
public enum SidecarChange: Sendable {
    /// Nothing to change: nothing is written.
    case keep
    /// Saved as `SidecarStore.save(_:for:)` saves it.
    case save(Sidecar)
    /// Saved, or removed when nothing would be left worth keeping, as `saveOrRemove(_:for:)` does.
    case saveOrRemove(Sidecar)
}

/// What a batch did with one photo's sidecar.
public struct SidecarBatchResult: Sendable {
    public enum Outcome: Sendable {
        /// Saved as the change asked: written, removed with nothing left in it worth keeping, or
        /// found holding it already.
        case saved
        /// The change kept it: nothing was written.
        case kept
        /// Left as it is: it's protected (`SidecarStoreError`), or it couldn't be written.
        case failed(any Error)
    }

    /// The photo's place in the batch.
    public let index: Int
    public let image: URL
    /// The sidecar the change was made from, as `load(for:)` reads it: nil when there's none or it
    /// can't be read.
    public let sidecar: Sidecar?
    public let change: SidecarChange
    public let outcome: Outcome
}

/// Many photos' sidecars changed at once (LIB-15, LIB-21, LIB-26), each by the rules its own save
/// keeps: it's read and written under coordination, its change is made from what's on disk then, so
/// another writer's changes are kept; a sidecar the change leaves as it is isn't written, one this
/// build can't read or couldn't write back without loss is left alone, and one with conflicting
/// copies is merged with them first, as `load(for:)` merges them. Each is written as its single save
/// would write it, byte for byte.
///
/// Sidecars are coordinated a group at a time, in one round trip to the file coordinator; each is
/// read once, for its change and the checks; several groups are written at once; and each edit is put
/// in place by a rename from beside its package.
public extension SidecarStore {
    /// Groups written at once: enough to keep the disk busy, few enough not to wait on each other.
    static let batchWidth = 8
    /// Sidecars coordinated together, and held while each is written; fewer when a batch has too few
    /// for `width` groups.
    static let batchGroup = 64

    /// Changes the sidecars of `images`, `make` deciding each one's change from the sidecar as it is
    /// then (nil: there's none, or it can't be read), `width` groups at a time. `done` hears of each
    /// as it's done, from any thread; once `stopped` says so, no more are started, and the batch
    /// returns when those under way are done. A failure is that sidecar's alone: the rest go on.
    ///
    /// `make` and `done` run while the batch coordinates the sidecars around theirs, so they must not
    /// read or write them through a store.
    func change(
        _ images: [URL], width: Int = batchWidth, until stopped: @Sendable () -> Bool = { false },
        _ make: @Sendable (_ index: Int, _ sidecar: Sidecar?) -> SidecarChange,
        done: @Sendable (SidecarBatchResult) -> Void,
    ) {
        let group = min(Self.batchGroup, (images.count + max(width, 1) - 1) / max(width, 1))
        change(images, width: width, group: group, edits: .renaming, until: stopped, make, done: done)
    }
}

extension SidecarStore {
    /// The batch, `group` sidecars coordinated together and `edits` putting each edit in its file.
    func change(
        _ images: [URL], width: Int, group size: Int, edits: EditWriter,
        until stopped: @Sendable () -> Bool, _ make: @Sendable (Int, Sidecar?) -> SidecarChange,
        done: @Sendable (SidecarBatchResult) -> Void,
    ) {
        let groups = stride(from: 0, to: images.count, by: max(size, 1)).map {
            $0 ..< min($0 + max(size, 1), images.count)
        }
        let next = Atomic(0)
        DispatchQueue.concurrentPerform(iterations: min(max(width, 1), groups.count)) { _ in
            while !stopped() {
                let group = next.add(1, ordering: .relaxed).oldValue
                guard group < groups.count else { return }
                changeTogether(
                    groups[group].map { (index: $0, image: images[$0]) }, edits: edits, until: stopped, make,
                    done: done,
                )
            }
        }
    }

    /// A photo of a batch, and where its sidecar is read and written.
    private struct Place {
        let index: Int
        let image: URL
        let read: URL
        let write: URL
    }

    /// Changes a group's sidecars under one coordination. Those with conflicting copies are changed
    /// after it, each as a single save changes it, since merging the copies takes coordinated writes
    /// of its own; so are all of them when the coordination fails.
    private func changeTogether(
        _ group: [(index: Int, image: URL)], edits: EditWriter,
        until stopped: @Sendable () -> Bool, _ make: @Sendable (Int, Sidecar?) -> SidecarChange,
        done: @Sendable (SidecarBatchResult) -> Void,
    ) {
        let places = group.map { photo in
            Place(
                index: photo.index,
                image: photo.image,
                read: locator.readURL(for: photo.image),
                write: url(for: photo.image),
            )
        }
        let intents = places.flatMap { place -> [NSFileAccessIntent] in
            let replacing: NSFileCoordinator.WritingOptions = Self.isPackage(place.write) ? [] : .forReplacing
            return [
                .readingIntent(with: place.read, options: []),
                .writingIntent(with: place.write, options: replacing),
            ]
        }
        var alone: [Place] = []
        let refused = Self.coordinating(intents) {
            for (number, place) in places.enumerated() {
                guard !stopped() else { return }
                let (read, write) = (intents[2 * number].url, intents[2 * number + 1].url)
                guard let result = changeCoordinated(place, read: read, write: write, edits: edits, make) else {
                    alone.append(place)
                    continue
                }
                done(result)
            }
        }
        if refused != nil {
            alone = places
        }
        for place in alone where !stopped() {
            done(changeAlone(place, make))
        }
    }

    /// The place's change, made under the batch's coordination with its edit read once; nil, nothing
    /// changed, when it has conflicting copies to merge first.
    private func changeCoordinated(
        _ place: Place, read: URL, write: URL, edits: EditWriter,
        _ make: @Sendable (Int, Sidecar?) -> SidecarChange,
    ) -> SidecarBatchResult? {
        let edit = Result { try Self.editData(inSidecar: write) }
        let sidecar = if read.path == write.path {
            (try? edit.get()).flatMap { Self.decode($0, inSidecar: write) }
        } else {
            Self.decode(sidecar: read)
        }
        if sidecar != nil, !conflicts.versions(write).isEmpty {
            return nil
        }
        let change = make(place.index, sidecar)
        let outcome: SidecarBatchResult.Outcome = switch change {
        case .keep:
            .kept
        case let .save(changed):
            Self.outcome {
                try makeFolder(for: write, of: place.image)
                let existing = try Self.existing(edit.get(), at: write)
                try Self.write(changed, to: write, over: existing, isPackage: Self.isPackage(write), edits: edits)
            }
        case let .saveOrRemove(changed):
            Self.outcome {
                let existing = try Self.existing(edit.get(), at: write)
                guard Self.leavesNothing(changed, over: existing, at: write) else {
                    try makeFolder(for: write, of: place.image)
                    return try Self.write(
                        changed, to: write, over: existing, isPackage: Self.isPackage(write), edits: edits,
                    )
                }
                if FileManager.default.fileExists(atPath: write.path) {
                    try Self.remove(write)
                }
            }
        }
        return SidecarBatchResult(
            index: place.index,
            image: place.image,
            sidecar: sidecar,
            change: change,
            outcome: outcome,
        )
    }

    /// The place's change made as a single save makes it: the sidecar loaded, which merges its
    /// conflicting copies, changed, and saved.
    private func changeAlone(_ place: Place, _ make: @Sendable (Int, Sidecar?) -> SidecarChange) -> SidecarBatchResult {
        let sidecar = load(for: place.image)
        let change = make(place.index, sidecar)
        let outcome: SidecarBatchResult.Outcome = switch change {
        case .keep: .kept
        case let .save(changed): Self.outcome { try save(changed, for: place.image) }
        case let .saveOrRemove(changed): Self.outcome { try saveOrRemove(changed, for: place.image) }
        }
        return SidecarBatchResult(
            index: place.index,
            image: place.image,
            sidecar: sidecar,
            change: change,
            outcome: outcome,
        )
    }

    private static func outcome(_ save: () throws -> Void) -> SidecarBatchResult.Outcome {
        do {
            try save()
            return .saved
        } catch {
            return .failed(error)
        }
    }

    /// Runs `body` on this thread with coordinated access to every one of `intents`, granted at once
    /// and held until `body` returns; returns why access was refused, `body` not run.
    static func coordinating(_ intents: [NSFileAccessIntent], _ body: () -> Void) -> (any Error)? {
        let access = HeldAccess()
        NSFileCoordinator(filePresenter: nil).coordinate(with: intents, queue: OperationQueue()) { error in
            access.hold(error)
        }
        if let refused = access.waitForGrant() {
            return refused
        }
        body()
        access.release()
        return nil
    }

    /// Puts `data` in a package's edit `file` atomically, as `Data.write(options: .atomic)` does,
    /// without the folder Foundation makes and removes for each atomic write: written to a hidden file
    /// beside the package, named as an interrupted save's leftovers are (`hiddenSibling(of:)`), so the
    /// same clean-up removes it, then renamed over the edit.
    static func writeByRenaming(_ data: Data, to file: URL) throws {
        let temporary = hiddenSibling(of: file.deletingLastPathComponent())
        try create(data, at: temporary)
        guard rename(temporary.path, file.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(temporary.path)
            throw error
        }
    }

    /// Writes `data` to a new file at `file`; on failure, none is left there.
    static func create(_ data: Data, at file: URL) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: POSIXError?
        data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count, failure == nil {
                let count = Darwin.write(descriptor, bytes.baseAddress! + written, bytes.count - written)
                if count >= 0 {
                    written += count
                } else if errno != EINTR {
                    failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        if close(descriptor) != 0, failure == nil {
            failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let failure {
            unlink(file.path)
            throw failure
        }
    }
}

extension EditWriter {
    /// As a batch writes it: a hidden file beside the package renamed over the edit, and in a package
    /// being built, the edit written as it is.
    static let renaming = EditWriter(replace: SidecarStore.writeByRenaming, create: SidecarStore.create)
}

/// Coordinated access, granted on the coordinator's queue and held there while another thread uses it.
private final class HeldAccess: Sendable {
    private let refusal = Mutex<(any Error)?>(nil)
    private let granted = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// In the accessor: says access is granted, or why not, and holds it until it's released.
    func hold(_ error: (any Error)?) {
        refusal.withLock { $0 = error }
        granted.signal()
        if error == nil {
            released.wait()
        }
    }

    func waitForGrant() -> (any Error)? {
        granted.wait()
        return refusal.withLock { $0 }
    }

    func release() {
        released.signal()
    }
}
