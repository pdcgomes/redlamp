import Foundation
import RedlampLibrary

/// What Library Health's sheet and menus say of a check's batch (LIB-40), in plain words: what it does and to how
/// many photos, what stays, and how to take it back.
enum HealthWords {
    /// "Move 14 copies to the Trash?", "Rename 2 photos to their formats' extensions?"
    static func question(_ check: HealthCheck, count: Int, kinds: Set<PhotoRecord.Kind> = []) -> String {
        if case .extensions = check {
            return count == 1 ? "Rename 1 photo to its format's extension?"
                : "Rename \(number(count)) photos to their formats' extensions?"
        }
        return "Move \(number(count)) \(things(check, count: count, kinds: kinds)) to the Trash?"
    }

    /// The menu's item for the batch: "Move 14 Copies to the Trash…", "Rename 2 Photos…".
    static func menuTitle(_ check: HealthCheck, count: Int, kinds: Set<PhotoRecord.Kind> = []) -> String {
        if case .extensions = check {
            return "Rename \(number(count)) Photo\(count == 1 ? "" : "s")…"
        }
        let things = things(check, count: count, kinds: kinds).split(separator: " ")
            .map { $0 == "of" || $0 == "and" ? String($0) : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return "Move \(number(count)) \(things) to the Trash…"
    }

    /// The batch's button.
    static func action(_ check: HealthCheck) -> String {
        if case .extensions = check {
            return "Rename"
        }
        return "Move to Trash"
    }

    /// "14 copies in 9 groups, 182 MB", "3 files, 4 KB".
    static func count(_ check: HealthCheck, count: Int, groups: Int, bytes: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        switch check {
        case .duplicates:
            return "\(number(count)) cop\(count == 1 ? "y" : "ies") in \(number(groups)) group\(groups == 1 ? "" : "s"), "
                + size
        case .damaged:
            return "\(number(count)) file\(count == 1 ? "" : "s"), \(size)"
        case .pairs, .missing, .extensions:
            return "\(number(count)) photo\(count == 1 ? "" : "s"), \(size)"
        }
    }

    /// What the batch does, and what stays.
    static func what(_ check: HealthCheck) -> String {
        switch check {
        case .duplicates:
            "Each is byte for byte the same as a copy that stays, so every photo keeps one copy. Every copy, the one "
                + "kept included, is read whole again just before anything moves, and a copy's sidecar and .xmp go "
                + "with it."
        case .pairs(.keepJPEG):
            "Each is the raw beside a JPEG or HEIC that stays, as the rule for raw and JPEG pairs is to keep the "
                + "JPEG. A raw's sidecar and .xmp go with it, an .xmp the pair shares included."
        case .pairs:
            "Each is the JPEG or HEIC beside a raw that stays, as the rule for raw and JPEG pairs is to keep the "
                + "raw. Its sidecar and .xmp go with it; an .xmp the pair shares stays with the raw."
        case .damaged:
            "They can't be read, are empty, aren't images or end before their data does. Nothing is repaired, and "
                + "each file's sidecar and .xmp go with it."
        case .missing:
            "Their files went from their folders outside Redlamp. Locate… finds each again, and Remove from Library "
                + "takes it out."
        case .extensions:
            "Each gets the extension of the format it holds, as IMG_1.JPG holding HEIC becomes IMG_1.HEIC, its "
                + "sidecar, .xmp and pair following."
        }
    }

    /// How to take the batch back.
    static func undo(_ check: HealthCheck) -> String {
        if case .extensions = check {
            return "Undo (⌘Z) gives them their names back."
        }
        return "Nothing is deleted: Undo (⌘Z) brings them back, and so does Put Back in Recently Trashed while "
            + "they're in the Trash."
    }

    /// What the batch leaves where it is: the findings listed apart that aren't chosen, and those it proposes
    /// nothing for. Empty when it leaves nothing.
    static func leftOut(_ findings: HealthFindings, choosing chosen: Set<Int64> = []) -> String {
        var decided = 0
        var own = 0
        var nothing = 0
        for finding in findings.findings where !chosen.contains(finding.photo) {
            switch (finding.apart, finding.proposal) {
            case (.decided?, _): decided += 1
            case (.own?, _): own += 1
            case (nil, nil): nothing += 1
            default: break
            }
        }
        var parts: [String] = []
        if decided > 0 {
            parts.append("\(number(decided)) \(decided == 1 ? "is" : "are") rated, flagged or labelled, and a "
                + "proposal never acts on a photo you've decided on")
        }
        if own > 0 {
            parts.append("\(number(own)) \(own == 1 ? "has" : "have") an edit, keywords, a title, caption, rating, "
                + "flag or label the other half doesn't")
        }
        if nothing > 0 {
            if case .extensions = findings.check {
                parts.append("\(number(nothing)) can't take \(nothing == 1 ? "its" : "their") format's name, as "
                    + "it's taken in \(nothing == 1 ? "its" : "their") folder")
            } else {
                parts.append("\(number(nothing)) can't be read for want of permission, which isn't damage")
            }
        }
        guard !parts.isEmpty else { return "" }
        let total = decided + own + nothing
        let listed = parts.count > 1 ? parts.dropLast().joined(separator: "; ") + "; and " + (parts.last ?? "")
            : parts[0]
        return "\(number(total)) \(total == 1 ? "stays" : "stay") where \(total == 1 ? "it is" : "they are"): "
            + listed + "."
    }

    /// The choice of the photos selected that the check lists apart: "Also move the 2 selected photos listed apart".
    static func choice(_ check: HealthCheck, count: Int) -> String {
        let verb = if case .extensions = check {
            "rename"
        } else {
            "move"
        }
        return "Also \(verb) the \(count == 1 ? "selected photo" : "\(number(count)) selected photos") listed apart"
    }

    /// The batch's progress: its check first, then "Moving 1,204 of 10,000…".
    static func progress(_ check: HealthCheck, done: Int, total: Int) -> String {
        guard done > 0 else {
            if case .duplicates = check {
                return "Reading every copy whole again before anything moves…"
            }
            return "Checking the photos again before anything moves…"
        }
        let verb = if case .extensions = check {
            "Renaming"
        } else {
            "Moving"
        }
        return "\(verb) \(number(done)) of \(number(total))…"
    }

    /// What's being checked before the sheet can say what the batch does.
    static func planning(_ check: HealthCheck) -> String {
        if case .duplicates = check {
            return "Reading the copies whole to confirm them…"
        }
        return "Checking the photos…"
    }

    /// Keep Anyway's change, as Undo and the activity log name it: "Keep 2 Groups of Copies Anyway".
    static func keptAnyway(_ check: HealthCheck.Kind, photos: Int, groups: Int) -> String {
        if check == .duplicates {
            return "Keep \(number(groups)) Group\(groups == 1 ? "" : "s") of Copies Anyway"
        }
        return "Keep \(number(photos)) Photo\(photos == 1 ? "" : "s") Anyway"
    }

    /// List Again's change: "List 3 Photos Again".
    static func listedAgain(photos: Int) -> String {
        "List \(number(photos)) Photo\(photos == 1 ? "" : "s") Again"
    }

    /// Locate…'s offer of the others: "Relink the 3 other missing photos found beside it?"
    static func relinkOthers(_ count: Int) -> String {
        count == 1 ? "Relink the other missing photo found beside it?"
            : "Relink the \(number(count)) other missing photos found beside it?"
    }

    /// Why: "IMG_0002.ARW and 2 others, missing from Shoot, are in Found under their names, with the same content."
    static func foundBeside(_ names: [String], from folder: String, in found: String) -> String {
        let first = names.first ?? ""
        let named = names.count == 1 ? first : "\(first) and \(number(names.count - 1)) other\(names.count == 2 ? "" : "s")"
        return "\(named), missing from \(folder), \(names.count == 1 ? "is" : "are") in \(found) under "
            + "\(names.count == 1 ? "its name" : "their names"), with the same content."
    }

    /// Locate…'s alert when the file chosen isn't the photo: "IMG_0001.ARW wasn't relinked".
    static func notRelinked(_ name: String) -> String {
        "“\(name)” wasn't relinked"
    }

    /// Why, from what Locate… found: "The file chosen, “A.ARW”, can't be it: it isn't the same photo: its content
    /// differs."
    static func notRelinked(because problem: MissingLocation.Problem, file: String) -> String {
        "The file chosen, “\(file)”, can't be it: \(problem)."
    }

    /// What a batch that stopped did, in a sentence.
    static func failure(_ error: any Error) -> String {
        switch error as? HealthError {
        case let .changed(paths):
            let names = paths.prefix(3).joined(separator: "; ")
            return "Nothing was moved: \(names)\(paths.count > 3 ? ", and \(number(paths.count - 3)) more" : "")."
        case .nothingToDo:
            return "Nothing was moved: the check has nothing left to act on."
        default:
            return LibraryService.describe(error) + "."
        }
    }

    /// The things the batch moves, by check: "copies", "JPEGs", "halves of raw and JPEG pairs", "damaged files".
    private static func things(_ check: HealthCheck, count: Int, kinds: Set<PhotoRecord.Kind>) -> String {
        let one = count == 1
        switch check {
        case .duplicates: return one ? "copy" : "copies"
        case .damaged: return one ? "damaged file" : "damaged files"
        case .missing, .extensions: return one ? "photo" : "photos"
        case .pairs:
            switch kinds {
            case [.jpeg]: return one ? "JPEG" : "JPEGs"
            case [.heic]: return one ? "HEIC" : "HEICs"
            case [.raw]: return one ? "raw" : "raws"
            default: return one ? "half of a raw and JPEG pair" : "halves of raw and JPEG pairs"
            }
        }
    }

    static func number(_ count: Int) -> String {
        count.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
