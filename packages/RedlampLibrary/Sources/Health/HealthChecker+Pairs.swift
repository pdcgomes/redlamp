import Foundation
import RedlampDocument

extension HealthChecker {
    /// The halves of pairs that hold a raw and a JPEG or HEIC which `rule` drops: the JPEG and HEIC
    /// to keep the raw, the raw to keep the JPEG. A half with decisions of its own, or one the user
    /// rated, flagged or labelled, is listed apart; a pair with a half that can't be read isn't judged.
    func pairs(_ rule: PairRule, store: ColumnStore?) async throws -> HealthFindings {
        guard rule != .keepBoth, let store else { return HealthFindings(check: .pairs(rule)) }
        let (names, choices) = try await index.read { reader in try (StackNames(reader), StackChoices(reader)) }
        let drops = await Task.detached(priority: .userInitiated) {
            Self.drops(rule, in: StackFinder.find(in: store, names: names, choices: choices), store: store)
        }.value
        let texts = try await pairTexts(drops, store: store)
        return Self.findings(rule, drops: drops, store: store, names: names, texts: texts) { _ in false }
    }

    /// The halves `rule` drops of `stacks`' pairs that hold a raw and a JPEG or HEIC, each with the
    /// half kept beside it: the JPEG, or the HEIC where there's none, to keep the JPEG.
    static func drops(_ rule: PairRule, in stacks: Stacks, store: ColumnStore) -> [(dropped: Int64, kept: Int64)] {
        let unreadable = UInt8(PhotoRecord.State.unreadable.rawValue)
        let (raw, jpeg) = (UInt8(PhotoRecord.Kind.raw.rawValue), UInt8(PhotoRecord.Kind.jpeg.rawValue))
        var drops: [(dropped: Int64, kept: Int64)] = []
        for pair in stacks.pairs {
            let rows = stacks.members(of: pair).compactMap { photo in store.row(of: photo).map { (photo, $0) } }
            guard rows.count == stacks.members(of: pair).count,
                  rows.allSatisfy({ store.states[$0.1] & unreadable == 0 })
            else { continue }
            let raws = rows.filter { store.kinds[$0.1] == raw }.map(\.0)
            let others = rows.filter { store.kinds[$0.1] != raw }.map(\.0)
            guard let first = raws.first, !others.isEmpty else { continue }
            switch rule {
            case .keepRaw:
                drops += others.map { ($0, first) }
            case .keepJPEG:
                let kept = rows.first { store.kinds[$0.1] == jpeg }?.0 ?? others[0]
                drops += raws.map { ($0, kept) }
            case .keepBoth:
                break
            }
        }
        return drops
    }

    /// `drops` as findings, `texts` holding the titles, captions and keywords of those that have any
    /// and of the halves kept beside them, and `isKept` saying which are kept anyway.
    static func findings(
        _ rule: PairRule, drops: [(dropped: Int64, kept: Int64)], store: ColumnStore, names: StackNames,
        texts: [Int64: PairTexts], isKept: (Int64) -> Bool,
    ) -> HealthFindings {
        var findings: [HealthFinding] = []
        findings.reserveCapacity(drops.count)
        var kept = 0
        for (dropped, keeper) in drops {
            guard let row = store.row(of: dropped), let other = store.row(of: keeper) else { continue }
            if isKept(dropped) {
                kept += 1
                continue
            }
            let own = own(row, beside: other, store: store, texts: texts[dropped], keptTexts: texts[keeper])
            let decided = isDecided(row, store: store)
            findings.append(HealthFinding(
                photo: dropped, check: .pairs, reason: .pairHalf(
                    PhotoRecord.Kind(rawValue: Int(store.kinds[row])) ?? .other, beside: names[keeper],
                ),
                proposal: .trash, apart: own.isEmpty ? decided ? .decided : nil : .own(own),
                group: .pair(kept: keeper),
            ))
        }
        return HealthFindings(check: .pairs(rule), findings: findings, keptAnyway: kept)
    }

    /// A pair's halves' titles, captions and keywords, read only for the halves to drop that have
    /// any, and for the halves kept beside them.
    func pairTexts(
        _ drops: [(dropped: Int64, kept: Int64)], store: ColumnStore,
    ) async throws -> [Int64: PairTexts] {
        let details = Packed.details([.title, .caption, .keywords])
        let wanted = drops.filter { drop in
            store.row(of: drop.dropped).map { store.packed[$0] & details != 0 } ?? false
        }
        guard !wanted.isEmpty else { return [:] }
        let ids = Array(Set(wanted.flatMap { [$0.dropped, $0.kept] }))
        return try await index.read { reader in
            var texts: [Int64: PairTexts] = [:]
            for id in ids {
                guard let photo = try reader.photo(id: id) else { continue }
                texts[id] = try PairTexts(
                    title: photo.title, caption: photo.caption, keywords: Set(reader.keywords(forPhoto: id)),
                )
            }
            return texts
        }
    }

    struct PairTexts {
        var title: String?
        var caption: String?
        var keywords: Set<String>
    }

    /// What the half in `row` holds of its own beside the half in `other`.
    static func own(
        _ row: Int, beside other: Int, store: ColumnStore, texts: PairTexts?, keptTexts: PairTexts?,
    ) -> [HealthApart.OwnDecision] {
        let (half, kept) = (store.packed[row], store.packed[other])
        var own: [HealthApart.OwnDecision] = []
        if half & Packed.edited != 0 {
            own.append(.edit)
        }
        if let texts {
            if !texts.keywords.isSubset(of: keptTexts?.keywords ?? []) {
                own.append(.keywords)
            }
            if let title = texts.title, !title.isEmpty, title != keptTexts?.title {
                own.append(.title)
            }
            if let caption = texts.caption, !caption.isEmpty, caption != keptTexts?.caption {
                own.append(.caption)
            }
        }
        if Packed.rating(half) > 0, Packed.rating(half) != Packed.rating(kept) {
            own.append(.rating)
        }
        if Packed.flag(half) != 0, Packed.flag(half) != Packed.flag(kept) {
            own.append(.flag)
        }
        let label = (Packed.label(half), store.customLabels[row])
        if label != (0, 0), label != (Packed.label(kept), store.customLabels[other]) {
            own.append(.label)
        }
        return own
    }
}
