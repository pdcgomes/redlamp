import Foundation

// What `redlamp library duplicates` prints of a review: the groups, what removing every copy but
// the proposed ones would free, the proposals and why, and the candidates that turned out
// different or couldn't be compared. It removes nothing.

public extension DuplicateReview {
    var lines: [String] {
        let copies = groups.reduce(0) { $0 + $1.copies.count }
        var lines = [
            groups.isEmpty ? "No duplicates" : "\(Self.count(groups.count, "group")) of duplicates, "
                + "\(Self.count(copies, "photo")): removing all but the proposed copies would free "
                + Self.bytes(reclaimable),
        ]
        if !checkedFiles {
            lines.append("Only hashes recorded earlier were compared: --confirm reads the files")
        }
        for group in groups {
            let kept = group.kept ?? group.copies[0]
            let captured = kept.captured.map { ", taken " + Self.date($0) } ?? ""
            lines.append("")
            lines.append(
                "\(kept.url.lastPathComponent): \(group.copies.count) copies of \(Self.bytes(group.size))\(captured)",
            )
            for copy in group.copies {
                let keep = copy.photo == group.keeper.photo
                var notes = keep ? [group.keeper.description] : []
                notes += Self.notes(copy)
                let suffix = notes.isEmpty ? "" : "  (" + notes.joined(separator: "; ") + ")"
                lines.append("  " + (keep ? "keep" : "copy") + "  " + copy.url.path + suffix)
            }
            if group.sidecarsDiffer {
                lines.append("  Their sidecars differ: a copy removed takes what its own holds")
            }
        }
        if !different.isEmpty {
            lines.append("")
            lines.append(
                "\(Self.count(different.count, "candidate")) turned out different: content key and size agree, "
                    + "full hash doesn't",
            )
            lines += different.map { "  " + $0.url.path }
        }
        if !unconfirmed.isEmpty {
            lines.append("")
            lines.append("\(Self.count(unconfirmed.count, "candidate")) couldn't be compared:")
            lines += unconfirmed.map { copy in
                "  \(copy.url.path)  (\(Self.reason(copy.status)))"
            }
        }
        lines.append("")
        lines.append("Nothing was removed.")
        return lines
    }

    var text: String {
        lines.joined(separator: "\n")
    }

    /// The review as JSON: each group with its copies, the keeper and why, and the space freed.
    func json() throws -> Data {
        struct Copy: Encodable {
            let photo: Int64
            let path: String
            let size: Int64
            let captured: Date?
            let modified: Date
            let rating: Int
            let sidecar: SidecarContents?
            let otherXMP: String?
            let sharesOtherXMP: Bool
            let status: String
            let sha256: String?
        }
        struct Keeper: Encodable {
            let photo: Int64
            let path: String
            let reason: DuplicateReview.Keeper.Reason
            let editedOrRated: Int
            let explanation: String
        }
        struct Group: Encodable {
            let sha256: String
            let size: Int64
            let reclaimable: Int64
            let keep: Keeper
            let sidecarsDiffer: Bool
            let copies: [Copy]
        }
        struct Output: Encodable {
            let tool = "redlamp library duplicates"
            let checkedFiles: Bool
            let reclaimable: Int64
            let groups: [Group]
            let different: [Copy]
            let unconfirmed: [Copy]
            let removed = 0
        }
        func copy(_ copy: DuplicateReview.Copy) -> Copy {
            Copy(
                photo: copy.photo, path: copy.url.path, size: copy.size, captured: copy.captured,
                modified: copy.modified, rating: copy.rating, sidecar: copy.sidecar, otherXMP: copy.otherXMP?.path,
                sharesOtherXMP: copy.sharesOtherXMP, status: Self.status(copy.status),
                sha256: copy.status.sha256.map(Self.hex),
            )
        }
        let output = Output(
            checkedFiles: checkedFiles, reclaimable: reclaimable,
            groups: groups.map { group in
                Group(
                    sha256: Self.hex(group.sha256), size: group.size, reclaimable: group.reclaimable,
                    keep: Keeper(
                        photo: group.keeper.photo, path: group.kept?.url.path ?? "", reason: group.keeper.reason,
                        editedOrRated: group.keeper.editedOrRated, explanation: group.keeper.description,
                    ),
                    sidecarsDiffer: group.sidecarsDiffer, copies: group.copies.map(copy),
                )
            },
            different: different.map(copy), unconfirmed: unconfirmed.map(copy),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(output)
    }

    /// `duplicate`, `different`, or the reason it's unconfirmed: `offline`, `notRead`...
    private static func status(_ status: DuplicateConfirmation.Status) -> String {
        switch status {
        case .duplicate: "duplicate"
        case .different: "different"
        case let .unconfirmed(reason): reason.rawValue
        }
    }

    private static func reason(_ status: DuplicateConfirmation.Status) -> String {
        guard case let .unconfirmed(reason) = status else { return self.status(status) }
        return switch reason {
        case .offline: "offline"
        case .missing: "missing from its folder"
        case .changed: "changed since it was indexed"
        case .unreadable: "couldn't be read"
        case .notRead: "not read: --confirm reads it"
        case .alone: "no other copy could be compared"
        }
    }

    /// What its sidecar holds, and its other app's `.xmp`.
    private static func notes(_ copy: Copy) -> [String] {
        var notes: [String] = []
        if let sidecar = copy.sidecar, !sidecar.isEmpty {
            var held: [String] = []
            if sidecar.hasEdits {
                held.append("edited")
            }
            if sidecar.rating > 0 {
                held.append(count(sidecar.rating, "star"))
            }
            if let flag = sidecar.flag {
                held.append(flag == .pick ? "picked" : "rejected")
            }
            if let label = sidecar.label {
                held.append(label.rawValue)
            }
            if !sidecar.keywords.isEmpty {
                held.append("keywords " + sidecar.keywords.joined(separator: ", "))
            }
            notes.append("sidecar: " + held.joined(separator: ", "))
        } else if copy.sidecar == nil, copy.sidecarURL != nil {
            notes.append("sidecar couldn't be read")
        } else if copy.rating > 0 {
            notes.append(count(copy.rating, "star") + " in another app")
        }
        if let xmp = copy.otherXMP {
            notes.append(xmp.lastPathComponent + (copy.sharesOtherXMP ? ", shared" : ""))
        }
        return notes
    }

    /// `1 group`, `3 groups`.
    private static func count(_ value: Int, _ noun: String) -> String {
        "\(BenchResult.grouped(value)) \(noun)\(value == 1 ? "" : "s")"
    }

    /// Megabytes of 1,000,000 bytes, as drives count them, or gigabytes from 1,000 MB.
    static func bytes(_ value: Int64) -> String {
        let megabytes = Double(value) / 1_000_000
        if megabytes >= 1000 {
            return String(format: "%.2f GB", megabytes / 1000)
        }
        return megabytes >= 1 ? String(format: "%.1f MB", megabytes) : "\(BenchResult.grouped(Int(value / 1000))) KB"
    }

    /// `2019-06-14 10:32:05`: the capture time as the camera wrote it, which the index keeps as UTC.
    private static func date(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0,
        )
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
