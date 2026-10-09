import Foundation
import RedlampLibrary

/// What the grid draws on a photo of a Library Health check's list (LIB-40): the check's proposal for it, drawn
/// apart from the user's own flags and never written as one, and what the check found, in a word for the cell's
/// badge and in a sentence for its tooltip and VoiceOver.
struct HealthMark: Hashable, Sendable {
    enum Proposal: Hashable, Sendable {
        /// The check's batch moves it to the Trash.
        case trash
        /// The copy its duplicate group keeps.
        case keep
        /// The check's batch renames it.
        case rename
        /// Listed apart: the batch leaves it out unless the user chooses it.
        case leftOut
        /// The check proposes nothing for it.
        case none
    }

    let finding: HealthFinding
    let proposal: Proposal
    /// The badge's word: "To Trash", "Keep", "Left Out", "Empty", "→ .heic".
    let word: String

    /// Framed as a proposal the check's batch carries out.
    var isFramed: Bool {
        proposal == .trash || proposal == .rename
    }

    init(_ finding: HealthFinding) {
        self.finding = finding
        let damage = Self.damageWord(finding)
        if finding.apart != nil {
            (proposal, word) = (.leftOut, damage ?? "Left Out")
            return
        }
        switch finding.proposal {
        case .trash: (proposal, word) = (.trash, damage ?? "To Trash")
        case .keep: (proposal, word) = (.keep, "Keep")
        case let .rename(name): (proposal, word) = (.rename, "→ ." + (name as NSString).pathExtension)
        case nil:
            if case .wrongExtension = finding.reason {
                (proposal, word) = (.none, "Name Taken")
            } else {
                (proposal, word) = (.none, damage ?? "Found")
            }
        }
    }

    /// What the check found and what it proposes, in a sentence: "the JPEG beside IMG_1.ARW: to the Trash, and
    /// IMG_1.ARW stays".
    var sentence: String {
        let reason = finding.reason.description
        switch proposal {
        case .trash:
            guard case let .pairHalf(_, kept) = finding.reason else { return "\(reason): to the Trash" }
            return "\(reason): to the Trash, and \(kept) stays"
        case .keep:
            return reason
        case .rename:
            return "\(reason): renamed \(finding.proposal?.renamed ?? "")"
        case .leftOut:
            let why = switch finding.apart {
            case let .own(decisions)?: HealthApart.own(decisions).description.replacingOccurrences(
                    of: "has its own", with: "it has its own",
                )
            default: "it's rated, flagged or labelled"
            }
            return "\(reason): left out of the batch, as \(why)"
        case .none:
            if case .wrongExtension = finding.reason {
                return "\(reason): nothing is proposed, as its format's name is taken in its folder"
            }
            return "\(reason): nothing is proposed, as it isn't damaged"
        }
    }

    /// A damaged file's damage in a word: the badge says what's wrong with it, and its frame whether it's proposed.
    private static func damageWord(_ finding: HealthFinding) -> String? {
        guard case let .damage(damage) = finding.reason else { return nil }
        switch damage {
        case .unreadable: return damage.isForbidden ? "No Access" : "Unreadable"
        case .empty: return "Empty"
        case .unrecognised: return "Not an Image"
        case .endsEarly: return "Ends Early"
        }
    }
}
