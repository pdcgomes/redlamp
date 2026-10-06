import Foundation
import RedlampDocument

extension HealthChecker {
    /// The groups the index's recorded hashes confirm, as LIB-39's review proposes them: the copy to
    /// keep and why, and the others to the Trash, those rated, flagged or labelled listed apart.
    func duplicates() async throws -> HealthFindings {
        let finder = DuplicateFinder(index: index)
        let candidates = try await finder.candidates()
        let confirmation = try await finder.confirm(candidates, readingFiles: false)
        let review = try await finder.review(confirmation)
        return try await Self.findings(of: review, rows: index.read { reader in
            try reader.photosWithPaths(review.groups.flatMap { $0.copies.map(\.photo) }).map(\.photo)
        }, unconfirmed: confirmation.unconfirmed.count { $0.status == .unconfirmed(.notRead) })
    }

    /// `review`'s groups as findings, `rows` their copies' rows.
    static func findings(
        of review: DuplicateReview, rows: [PhotoRecord], unconfirmed: Int,
    ) -> HealthFindings {
        let rows = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        var findings: [HealthFinding] = []
        for group in review.groups {
            let keeper = group.kept?.url.path ?? ""
            for copy in group.copies {
                let isKeeper = copy.photo == group.keeper.photo
                let decided = rows[copy.photo].map { Self.isDecided($0) } ?? copy.isEditedOrRated
                findings.append(HealthFinding(
                    photo: copy.photo, check: .duplicates,
                    reason: isKeeper ? .keeper(group.keeper) : .duplicate(of: keeper),
                    proposal: isKeeper ? .keep : .trash, apart: !isKeeper && decided ? .decided : nil,
                    group: .duplicates(sha256: group.sha256),
                ))
            }
        }
        return HealthFindings(check: .duplicates, findings: findings, unconfirmed: unconfirmed)
    }
}
