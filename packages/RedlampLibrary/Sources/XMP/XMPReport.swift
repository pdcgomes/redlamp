import Foundation
import RedlampDocument

/// One photo in a sync of other apps' XMP (`LibraryXMP.sync`).
public struct XMPPhotoSync: Sendable, Hashable {
    /// Its row; nil for a photo the index doesn't have yet, which shares an `.xmp` with one it has.
    public var photo: Int64?
    public var path: String
    /// The `.xmp` it shares with the photos of its name (`IMG_1234.xmp`); nil when there's none.
    public var sidecar: String?
    /// The photos sharing that name, by file name.
    public var sharedWith: [String]
    /// darktable's own `.xmp` (`IMG_1234.ARW.xmp`), read but never written.
    public var darktable: String?
    /// Other apps' fields: each from the `.xmp`, then darktable's, then the photo's own XMP and IPTC.
    public var other: XMPFields
    /// Its `.redlamp`'s fields before the sync; nil without a readable one.
    public var redlamp: XMPFields?
    /// Its fields after the sync: the `.redlamp`'s once merged, else other apps'.
    public var merged: XMPFields
    /// Fields its `.redlamp` took from other apps.
    public var taken: [XMPField]
    /// Fields both changed, where the `.redlamp`'s later value stayed.
    public var kept: [XMPField]
    /// Fields written to the `.xmp`, or that would be in a dry run.
    public var written: [XMPField] = []
    /// Fields the `.redlamp` decides that the `.xmp` doesn't hold, since writing is off.
    public var unwritten: [XMPField]
    /// Nothing it's merged from changed since the last sync.
    public var unchanged: Bool
    /// Why its `.redlamp` or `.xmp` wasn't written.
    public var problem: String?
}

/// What `redlamp library xmp` prints: each photo with other apps' XMP or a `.redlamp`, what the two
/// hold, what was merged and written, and a summary.
public struct XMPReport: Sendable {
    public let photos: [XMPPhotoSync]
    /// How many photos were asked about.
    public let considered: Int
    public let writing: Bool
    public let dryRun: Bool
    public let elapsed: Duration

    /// The `.xmp` files written, or that would be.
    public var xmpWritten: [String] {
        Array(Set(photos.filter { !$0.written.isEmpty }.map { $0.sidecar ?? Self.newSidecar(for: $0) })).sorted()
    }

    /// Photos that took other apps' changes into their `.redlamp`.
    public var merged: [XMPPhotoSync] {
        photos.filter { !$0.taken.isEmpty && $0.problem == nil }
    }

    public var lines: [String] {
        var lines = photos.map(line)
        let other = photos.count { $0.sidecar != nil || $0.darktable != nil }
        let sidecars = photos.count { $0.redlamp != nil }
        let unchanged = photos.count(where: \.unchanged)
        lines.append(
            "\(Self.count(considered, "photo")): \(other) with other apps' .xmp, \(sidecars) with a .redlamp"
                + (unchanged > 0 ? ", \(unchanged) unchanged since they were last merged" : ""),
        )
        let merged = merged
        if merged.isEmpty {
            lines.append("No .redlamp \(dryRun ? "would take" : "took") other apps' changes")
        } else {
            let fields = XMPField.allCases.compactMap { field -> String? in
                let count = merged.count { $0.taken.contains(field) }
                return count > 0 ? "\(field.rawValue) \(count)" : nil
            }
            lines.append(
                "\(Self.count(merged.count, ".redlamp sidecar")) \(dryRun ? "would take" : "took") other apps' "
                    + "changes: \(fields.joined(separator: ", "))",
            )
        }
        let kept = photos.count { !$0.kept.isEmpty }
        if kept > 0 {
            lines.append("\(Self.count(kept, "photo")) kept the .redlamp's later value where both had changed")
        }
        let written = xmpWritten
        if writing {
            let new = photos.filter { !$0.written.isEmpty && $0.sidecar == nil }.map(Self.newSidecar)
            lines.append(
                written.isEmpty ? "No .xmp needed writing"
                    : "\(Self.count(written.count, ".xmp file")) \(dryRun ? "would be written" : "written"): "
                    + "\(Set(new).count) new, \(written.count - Set(new).count) rewritten keeping other apps' fields",
            )
        } else {
            let owed = photos.count { !$0.unwritten.isEmpty }
            lines.append(
                "Writing .xmp is off" + (owed > 0 ? ": \(Self.count(owed, "photo")) with values their .xmp doesn't "
                    + "hold (--write writes them)" : ""),
            )
        }
        let problems = photos.filter { $0.problem != nil }
        if !problems.isEmpty {
            lines.append("\(Self.count(problems.count, "photo")) not written: see above")
        }
        if dryRun {
            lines.append("A dry run: nothing was written.")
        }
        return lines
    }

    /// `<path>: .xmp 3 stars, red; .redlamp 5 stars, picked; took the label; wrote the rating`.
    private func line(_ photo: XMPPhotoSync) -> String {
        var parts: [String] = []
        if photo.unchanged {
            return "\(photo.path): unchanged since it was last merged"
        }
        if let sidecar = photo.sidecar {
            let name = (sidecar as NSString).lastPathComponent
            let shared = photo.sharedWith.isEmpty ? "" : ", shared with \(photo.sharedWith.joined(separator: ", "))"
            parts.append(".xmp \(name)\(shared): \(Self.describe(photo.other))")
        } else if photo.darktable != nil {
            parts.append("darktable's .xmp: \(Self.describe(photo.other))")
        } else if !photo.other.isEmpty {
            parts.append("its own XMP: \(Self.describe(photo.other))")
        }
        parts.append(photo.redlamp.map { ".redlamp: \(Self.describe($0))" } ?? "no .redlamp: as other apps have it")
        if !photo.taken.isEmpty {
            parts.append("\(dryRun ? "would take" : "took") \(Self.list(photo.taken))")
        }
        if !photo.kept.isEmpty {
            parts.append("kept the .redlamp's later \(Self.list(photo.kept))")
        }
        if !photo.written.isEmpty {
            parts.append("\(dryRun ? "would write" : "wrote") \(Self.list(photo.written))")
        }
        if let problem = photo.problem {
            parts.append(problem)
        }
        return "\(photo.path): " + parts.joined(separator: "; ")
    }

    /// `3 stars, picked, red, 2 keywords, a title`.
    static func describe(_ fields: XMPFields) -> String {
        var parts: [String] = []
        if let rating = fields.rating {
            parts.append(rating == 1 ? "1 star" : "\(rating) stars")
        }
        switch fields.flag {
        case .pick: parts.append("picked")
        case .reject: parts.append("rejected")
        case nil: break
        }
        if let label = fields.label {
            parts.append(label.rawValue)
        } else if let custom = fields.customLabel {
            parts.append("label “\(custom)”")
        }
        if !fields.keywords.isEmpty {
            parts.append(count(fields.keywords.count, "keyword"))
        }
        if fields.title != nil {
            parts.append("a title")
        }
        if fields.caption != nil {
            parts.append("a caption")
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }

    /// `the rating, flag and label`.
    private static func list(_ fields: [XMPField]) -> String {
        let names = fields.map(\.rawValue)
        guard names.count > 1 else { return "the " + (names.first ?? "") }
        return "the " + names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted(.number.locale(Locale(identifier: "en_US")))) \(noun)\(value == 1 ? "" : "s")"
    }

    private static func newSidecar(for photo: XMPPhotoSync) -> String {
        (photo.path as NSString).deletingPathExtension + ".xmp"
    }

    /// The report as JSON: each photo with its fields on each side, and the summary.
    public func json() throws -> Data {
        func fields(_ fields: XMPFields?) -> Any {
            guard let fields else { return NSNull() }
            var object: [String: Any] = ["keywords": fields.keywords]
            object["rating"] = fields.rating
            object["flag"] = fields.flag?.rawValue
            object["label"] = fields.label?.rawValue
            object["customLabel"] = fields.customLabel
            object["title"] = fields.title
            object["caption"] = fields.caption
            return object
        }
        let photos = photos.map { photo -> [String: Any] in
            var object: [String: Any] = [
                "path": photo.path, "sharedWith": photo.sharedWith, "other": fields(photo.other),
                "redlamp": fields(photo.redlamp), "merged": fields(photo.merged), "taken": photo.taken.map(\.rawValue),
                "kept": photo.kept.map(\.rawValue), "written": photo.written.map(\.rawValue),
                "unwritten": photo.unwritten.map(\.rawValue), "unchanged": photo.unchanged,
            ]
            object["id"] = photo.photo
            object["sidecar"] = photo.sidecar
            object["darktable"] = photo.darktable
            object["problem"] = photo.problem
            return object
        }
        let summary: [String: Any] = [
            "photos": considered, "merged": merged.count, "xmpWritten": xmpWritten,
            "problems": self.photos.count { $0.problem != nil }, "seconds": elapsed.seconds,
        ]
        return try JSONSerialization.data(
            withJSONObject: [
                "tool": "redlamp library xmp", "dryRun": dryRun, "writing": writing, "photos": photos,
                "summary": summary,
            ],
            options: [.prettyPrinted, .sortedKeys],
        )
    }
}
