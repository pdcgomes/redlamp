import Foundation
import RedlampDocument

public extension LibraryHealth {
    /// The batch that carries out `findings`' proposals: the photos it proposes and isn't listing
    /// apart, and those of `chosen` it lists apart or proposes to keep, which the user chose; never
    /// anything it doesn't list. Duplicates are confirmed by reading every copy of their groups whole
    /// first, as LIB-39's removal is, which always leaves a copy. Planning moves nothing.
    func plan(_ findings: HealthFindings, choosing chosen: Set<Int64> = []) async throws -> HealthPlan {
        let picked = findings.findings.filter { finding in
            switch finding.proposal {
            case .trash, .rename: finding.apart == nil || chosen.contains(finding.photo)
            case .keep: chosen.contains(finding.photo)
            case nil: false
            }
        }
        let pickedPhotos = Set(picked.map(\.photo))
        let leftOut = findings.findings.filter { $0.proposal != .keep && !pickedPhotos.contains($0.photo) }
        switch findings.check {
        case .duplicates:
            return try await duplicatesPlan(findings, picked: picked, leftOut: leftOut)
        case .pairs, .damaged:
            let found = try await expected(picked)
            var batch = try await operations.planTrash(picked.map { PhotoFiles(id: $0.photo) })
            let count = batch.steps.count
            batch.title = switch findings.check {
            case .pairs: "Move \(count) half\(count == 1 ? "" : "s") of raw and JPEG pairs to the Trash"
            default: "Move \(count) damaged file\(count == 1 ? "" : "s") to the Trash"
            }
            return HealthPlan(
                check: findings.check, batch: batch, findings: picked, leftOut: leftOut, expected: found,
                chosen: chosen,
            )
        case .extensions:
            let found = try await expected(picked)
            let moves = picked.compactMap { finding -> PhotoMove? in
                guard let photo = found[finding.photo], let name = finding.proposal?.renamed else { return nil }
                let folder = FilePlanner.split(photo.path).folder
                return PhotoMove(id: finding.photo, from: photo.path, to: folder + "/" + name)
            }
            let steps = try await operations.moveSteps(moves)
            let count = moves.count
            let batch = FileBatch(
                kind: .rename,
                title: "Rename \(count) photo\(count == 1 ? "" : "s") to \(count == 1 ? "its format's extension" : "their formats' extensions")",
                steps: FileOperations.recordingOriginalNames(steps, moves: moves),
            )
            return HealthPlan(
                check: .extensions, batch: batch, findings: picked, leftOut: leftOut, expected: found, chosen: chosen,
            )
        }
    }

    /// What stops `plan` before it moves anything, as the library is now: each photo it acts on
    /// where it was found, with the size and date it had, its finding still there, and not rated,
    /// flagged or labelled since unless the user chose it; and for a pair's half, the half kept beside
    /// it still there. Empty when it can run.
    func check(_ plan: HealthPlan) async throws -> [String] {
        if let duplicates = plan.duplicates {
            let finder = try await finder()
            return try await finder.check(duplicates, plan.batch, operations: operations, hashing: false)
                .map(\.description)
        }
        let now = try await findings(plan.check)
        let ids = plan.findings.map(\.photo) + plan.findings.compactMap { finding -> Int64? in
            guard case let .pair(kept)? = finding.group else { return nil }
            return kept
        }
        let rows = try await index.read { reader in
            try Dictionary(reader.photosWithPaths(ids).map { ($0.photo.id, $0) }) { first, _ in first }
        }
        var differences: [String] = []
        for finding in plan.findings {
            guard let expected = plan.expected[finding.photo] else { continue }
            guard let (photo, folder) = rows[finding.photo], folder + "/" + photo.name == expected.path,
                  photo.size == expected.size, LibraryIndexer.Run.same(photo.modified, expected.modified)
            else {
                differences.append("\(expected.path) has changed since the check")
                continue
            }
            if now.finding(for: finding.photo) == nil {
                differences.append("\(expected.path) is no longer found by the check")
            } else if HealthChecker.isDecided(photo), !plan.chosen.contains(finding.photo), finding.apart == nil {
                differences.append("\(expected.path) has been rated, flagged or labelled since the check")
            }
            if case let .pair(kept)? = finding.group, rows[kept] == nil {
                differences.append("\(expected.path)'s other half isn't in the library any more")
            }
        }
        return differences
    }

    /// Runs `plan` once `check` finds nothing in its way, in the batch's turn among the file
    /// operations', so no other batch moves anything between them; otherwise throws
    /// `HealthError.changed`, having moved nothing. Duplicates go through LIB-39's own check, every copy
    /// and the copy kept for it read whole again. Undo (`FileOperations.undo`) takes the batch back.
    @discardableResult
    func run(
        _ plan: HealthPlan, progress: (@Sendable (FileProgress) -> Void)? = nil,
    ) async throws -> FileOutcome {
        guard !plan.batch.steps.isEmpty else { throw HealthError.nothingToDo }
        let outcome: FileOutcome = if let duplicates = plan.duplicates {
            try await finder().trash(duplicates, plan.batch, operations: operations)
        } else {
            try await operations.run(plan.batch, checkedBy: { [self] in
                let differences = try await check(plan)
                guard differences.isEmpty else { throw HealthError.changed(differences) }
            }, progress: progress)
        }
        await changed()
        return outcome
    }

    private func duplicatesPlan(
        _ findings: HealthFindings, picked: [HealthFinding], leftOut: [HealthFinding],
    ) async throws -> HealthPlan {
        let finder = try await finder()
        let photos = findings.photos
        let candidates = try await finder.candidates()
        let wanted = DuplicateCandidates(
            groups: candidates.groups.filter { $0.photos.contains { photos.contains($0) } },
            photosGrouped: candidates.photosGrouped, memoryFootprint: candidates.memoryFootprint,
        )
        let review = try await finder.review(finder.confirm(wanted))
        let copies = Set(review.groups.flatMap { $0.copies.map(\.photo) })
        let removing = picked.map(\.photo).filter(copies.contains)
        let plan = try DuplicateRemovalPlan(review, removing: removing)
        let batch = try await finder.trashBatch(for: plan, operations: operations)
        let found = try await expected(picked)
        return HealthPlan(
            check: .duplicates, batch: batch, findings: picked.filter { removing.contains($0.photo) },
            leftOut: leftOut + picked.filter { !removing.contains($0.photo) }, expected: found, chosen: [],
            duplicates: plan,
        )
    }

    /// Each finding's photo as the index has it: its path, size and date.
    private func expected(_ findings: [HealthFinding]) async throws -> [Int64: HealthPlan.Expected] {
        let ids = findings.map(\.photo)
        return try await index.read { reader in
            try Dictionary(reader.photosWithPaths(ids).map { photo, folder in
                (
                    photo.id,
                    HealthPlan.Expected(path: folder + "/" + photo.name, size: photo.size, modified: photo.modified),
                )
            }) { first, _ in first }
        }
    }
}

/// A batch Library Health would run (LIB-40), with what it acts on and what it leaves out.
public struct HealthPlan: Sendable {
    /// A photo as the check found it.
    public struct Expected: Sendable, Hashable {
        public var path: String
        public var size: Int64
        public var modified: Date
    }

    public let check: HealthCheck
    public var batch: FileBatch
    /// The findings it acts on.
    public let findings: [HealthFinding]
    /// The findings it leaves out: listed apart and not chosen, or with nothing to propose.
    public let leftOut: [HealthFinding]
    let expected: [Int64: Expected]
    let chosen: Set<Int64>
    /// For duplicates, LIB-39's removal plan, which its own check carries out.
    let duplicates: DuplicateRemovalPlan?

    init(
        check: HealthCheck, batch: FileBatch, findings: [HealthFinding], leftOut: [HealthFinding],
        expected: [Int64: Expected], chosen: Set<Int64>, duplicates: DuplicateRemovalPlan? = nil,
    ) {
        self.check = check
        self.batch = batch
        self.findings = findings
        self.leftOut = leftOut
        self.expected = expected
        self.chosen = chosen
        self.duplicates = duplicates
    }

    /// The photos it acts on.
    public var photos: [Int64] {
        findings.map(\.photo)
    }

    /// Where each photo it acts on is, by ID.
    public func path(of photo: Int64) -> String? {
        expected[photo]?.path
    }
}

/// Why Library Health couldn't do what it was asked.
public enum HealthError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The definitions were written by a newer Redlamp: they're read, never written over.
    case newerDefinitions(URL)
    case unreadableDefinitions
    /// The photos the batch would act on aren't as the check found them; nothing was done.
    case changed([String])
    /// The check has nothing to act on.
    case nothingToDo

    public var description: String {
        switch self {
        case let .newerDefinitions(url): "\(url.path) was written by a newer Redlamp: it's left as it is"
        case .unreadableDefinitions: "Library Health's definitions can't be read"
        case let .changed(paths): "\(paths.joined(separator: ", ")) changed since the check: nothing was done"
        case .nothingToDo: "nothing to do"
        }
    }
}
