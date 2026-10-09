import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// What Move Edits and Metadata… (LIB-11, DEC-43) says of a root and the move it runs: where the root keeps its
/// edits and metadata and where they'd go, how many photos have them (from the index, then from the disk), whether
/// they can go there, and the move's progress and outcome. The sheet opens before the index has answered, with where
/// the library's locator says the root keeps them, and doesn't wait for it: the index's numbers follow.
@MainActor
final class MoveEditsModel {
    enum Phase: Equatable {
        /// The index is asked how many photos have edits or metadata, then the sidecars are found on the disk: Move
        /// waits for them.
        case checking
        case ready
        /// The open photo's edit, and the saves asked for before Move, are being written.
        case saving
        case moving(FileProgress)
        /// Over, with something to say, which the sheet keeps on screen.
        case done(String)
        case failed(String)
    }

    /// The root's row in the index, where it keeps its sidecars and how many of its photos have one.
    typealias Survey = (id: Int64, placement: RootRecord.Sidecars, photos: Int)

    let root: WorkingFolder
    /// The root's row in the index, once it has answered.
    private(set) var rootID: Int64?
    /// Where the root keeps its sidecars now: as the locator has it until the index answers.
    private(set) var placement: RootRecord.Sidecars
    /// Its photos with edits or metadata, as the index has them; nil until it has answered.
    private(set) var indexed: Int?
    /// From the command to the read's end, off the main thread, and to the sheet having the numbers, for the
    /// regression suite.
    var read: Duration?
    var surveyed: Duration?
    /// The move a quit interrupted, as the library's journal holds it, which the sheet finishes, rather than one to
    /// ask for.
    let unfinished: SidecarMoveJournal?
    /// The sidecars in the place they'd leave, once found.
    private(set) var plan: SidecarMovePlan?
    /// Why they can't go where they'd go, in words.
    private(set) var refusal: String?
    private(set) var phase: Phase
    let control = SidecarMoveControl()
    var onChange: (() -> Void)?
    /// The index's answer as the read leaves it, off the main thread, for the sheet to take before it first appears.
    private let answer = Answer()
    private var sidecars: LibrarySidecars?
    private var isLookingThrough = false

    private final class Answer: Sendable {
        let survey = Mutex<(Survey?, read: Duration)?>(nil)
    }

    init(
        root: WorkingFolder, rootID: Int64?, placement: RootRecord.Sidecars, indexed: Int,
        unfinished: SidecarMoveJournal? = nil,
    ) {
        self.root = root
        self.rootID = rootID
        self.placement = placement
        self.indexed = indexed
        self.unfinished = unfinished
        if unfinished != nil {
            phase = .moving(FileProgress(done: 0, total: 0, isRollingBack: unfinished?.puttingBack == true))
        } else if rootID == nil {
            phase = .failed(Self.unread(root))
        } else {
            phase = .checking
        }
    }

    /// A sheet for `root` before the index has answered, where `locator` says it keeps its sidecars;
    /// `survey(_:since:)` asks the index, then the disk.
    init(root: WorkingFolder, locator: SidecarLocator, sidecars: LibrarySidecars) {
        self.root = root
        let path = LibraryService.path(root.url)
        placement = locator.roots.first { $0.path == path }?.onThisMac == true ? .onThisMac : .besidePhotos
        self.sidecars = sidecars
        unfinished = nil
        phase = .checking
    }

    private static func unread(_ root: WorkingFolder) -> String {
        "The library hasn't read “\(root.name)” yet, so its edits and metadata can't be moved yet"
    }

    /// Where the move takes them: the other place, or where the unfinished move was taking them.
    var destination: RootRecord.Sidecars {
        unfinished?.plan.destination ?? (placement == .besidePhotos ? .onThisMac : .besidePhotos)
    }

    var source: RootRecord.Sidecars {
        destination == .onThisMac ? .besidePhotos : .onThisMac
    }

    var conflicts: [SidecarMovePlan.Conflict] {
        plan?.conflicts ?? []
    }

    var canMove: Bool {
        phase == .ready && plan != nil && refusal == nil && conflicts.isEmpty
    }

    var isMoving: Bool {
        switch phase {
        case .saving, .moving: true
        default: false
        }
    }

    var isOver: Bool {
        switch phase {
        case .done, .failed: true
        default: false
        }
    }

    // MARK: - Finding them

    /// The root of the index at `root`'s path, where it keeps its sidecars and how many of its photos have one: a read
    /// of the index, for the sheet's numbers. Nil when the index doesn't have it.
    nonisolated static func survey(_ root: URL, in index: LibraryIndex) async -> Survey? {
        let path = LibraryService.path(root)
        return try? await index.read { reader -> Survey? in
            MoveEditsTrace.note("read began on a reader")
            defer { MoveEditsTrace.note("read over") }
            guard let record = try reader.root(path: path) else { return nil }
            return try (record.id, record.sidecars, reader.photoCount(withSidecarsInRoot: record.id))
        } ?? nil
    }

    /// Asks the index how many of the root's photos have edits or metadata, off the main thread, then looks through
    /// the disk. The answer reaches the sheet as it first appears (`takeAnswer(since:)`) when it's in by then, or as
    /// soon as the main thread is free after.
    func survey(_ index: LibraryIndex, since requested: ContinuousClock.Instant) {
        let (folder, answer) = (root.url, answer)
        // Started here, not from a task on the main actor, which waits for the main thread to lay out the sheet.
        let reading = Task.detached(priority: .userInitiated) {
            let survey = await Self.survey(folder, in: index)
            answer.survey.withLock { $0 = (survey, ContinuousClock.now - requested) }
        }
        Task {
            await reading.value
            takeAnswer(since: requested)
        }
    }

    /// Shows the index's answer once it's in, and then looks through the disk.
    func takeAnswer(since requested: ContinuousClock.Instant) {
        guard indexed == nil, phase == .checking, let found = answer.survey.withLock({ $0 }) else { return }
        MoveEditsTrace.note("the sheet has the numbers")
        read = found.read
        surveyed = .now - requested
        guard let survey = found.0 else {
            phase = .failed(Self.unread(root))
            onChange?()
            return
        }
        rootID = survey.id
        placement = survey.placement
        indexed = survey.photos
        onChange?()
        if let sidecars {
            Task { await check(sidecars) }
        }
    }

    /// Finds the sidecars on the disk, and, for a move into the folder, whether Redlamp can write there.
    func check(_ sidecars: LibrarySidecars) async {
        guard let rootID, phase == .checking, !isLookingThrough else { return }
        isLookingThrough = true
        let (destination, folder) = (destination, root.url)
        let found = await Task.detached(priority: .userInitiated) { () -> (
            Result<SidecarMovePlan, any Error>,
            String?
        ) in
            let refusal = destination == .besidePhotos
                ? SidecarMoveJob.whyNotWritable(folder, probing: false) : nil
            do {
                return try await (.success(sidecars.planMove(ofRoot: rootID, to: destination)), refusal)
            } catch {
                return (.failure(error), refusal)
            }
        }.value
        guard phase == .checking else { return }
        refusal = found.1
        switch found.0 {
        case let .success(plan):
            self.plan = plan
            phase = .ready
        case let .failure(error):
            phase = .failed("Redlamp couldn't look through “\(root.name)”: \(SidecarMoveJob.describe(error))")
        }
        onChange?()
    }

    // MARK: - Moving them

    func setPhase(_ phase: Phase) {
        self.phase = phase
        onChange?()
    }

    func refuse(_ reason: String) {
        refusal = reason
        phase = .ready
        onChange?()
    }

    /// Photos that turned up with a sidecar in each place since the sheet looked: the move didn't start.
    func refuseConflicts(_ conflicts: [SidecarMovePlan.Conflict]) {
        plan?.conflicts = conflicts
        phase = .ready
        onChange?()
    }

    /// Stops the move after the part it's moving, to put back what it moved; while it saves, before anything moves.
    func cancel() {
        guard isMoving, !control.isCancelled else { return }
        control.cancel()
        onChange?()
    }

    /// The move is putting back what it moved, which can't be stopped.
    var isPuttingBack: Bool {
        guard case let .moving(progress) = phase else { return false }
        return progress.isRollingBack
    }

    // MARK: - Words

    static func place(_ placement: RootRecord.Sidecars) -> String {
        placement == .besidePhotos ? "beside the photos" : "in Redlamp on this Mac"
    }

    var heading: String {
        "Move Edits and Metadata of “\(root.name)”"
    }

    /// How many photos have edits or metadata in the place they'd leave: the index's count until the disk's is in.
    var count: String {
        let place = Self.place(source)
        guard let photos = plan.map({ $0.items.count + $0.conflicts.count }) ?? indexed else {
            return "Counting the photos with edits or metadata \(place)…"
        }
        guard photos > 0 else { return "No photo has edits or metadata \(place)." }
        return "\(Self.photos(photos)) \(photos == 1 ? "has" : "have") edits or metadata \(place)."
    }

    var kept: String {
        placement == .besidePhotos
            ? "Beside the photos, in a .redlamp file next to each one"
            : "In Redlamp on this Mac, in its library"
    }

    var goingTo: String {
        destination == .besidePhotos ? "Beside the photos" : "Redlamp on this Mac"
    }

    static let how = "Each photo's edits and metadata are copied to the new place and checked against the "
        + "original, and only then is the original removed. Nothing already there is overwritten. If Redlamp "
        + "quits during the move, it finishes the move the next time it opens. Other apps' .xmp files stay beside "
        + "the photos, where those apps look for them."

    var what: String {
        destination == .onThisMac
            ? "In Redlamp on this Mac they're found again wherever the disk is connected, but other Macs and other "
            + "apps don't see them."
            : "Beside the photos they go wherever the photos go, and another Mac with the folder reads them too."
    }

    /// What the status line says: progress, a refusal, or how the move went.
    var status: String {
        switch phase {
        case .checking:
            return "Finding the edits and metadata in the folder…"
        case .saving:
            return "Saving the open photo's edit first…"
        case let .moving(progress):
            if unfinished != nil, progress.total == 0 {
                return "Finishing the move Redlamp was making when it quit…"
            }
            let doing = progress.isRollingBack ? "Putting back" : "Moving"
            return "\(doing): \(Self.count(progress.done)) of \(Self.photos(progress.total))"
        case let .done(message), let .failed(message):
            return message
        case .ready:
            if let refusal {
                return "\(refusal), so its edits and metadata stay \(Self.place(source))."
            }
            if !conflicts.isEmpty {
                let names = conflicts.prefix(3).map { ($0.photo as NSString).lastPathComponent }
                let more = conflicts.count > 3 ? " and \(conflicts.count - 3) more" : ""
                return "\(Self.photos(conflicts.count)) \(conflicts.count == 1 ? "has" : "have") edits and metadata "
                    + "in both places, so nothing can be moved: \(names.joined(separator: ", "))\(more). Redlamp "
                    + "reads the copy saved last."
            }
            if plan?.items.isEmpty == true {
                return "Moving keeps new edits and metadata \(Self.place(destination))."
            }
            return ""
        }
    }

    /// Whether the status line reports a problem.
    var statusIsProblem: Bool {
        switch phase {
        case .failed: true
        case .done: true
        case .ready: refusal != nil || !conflicts.isEmpty
        default: false
        }
    }

    static func count(_ number: Int) -> String {
        number.formatted()
    }

    /// "1 photo", "1,204 photos".
    static func photos(_ number: Int) -> String {
        "\(number.formatted()) photo\(number == 1 ? "" : "s")"
    }
}
