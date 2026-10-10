import Foundation
import RedlampDocument

extension HealthChecker {
    /// The halves of pairs that hold a raw and a JPEG or HEIC which `rule` drops: the JPEG and HEIC
    /// to keep the raw, the raw to keep the JPEG. A half with decisions of its own, or one the user
    /// rated, flagged or labelled, is listed apart; a pair with a half that can't be read isn't judged.
    func pairs(_ rule: PairRule, store: ColumnStore?) async throws -> HealthFindings {
        guard rule != .keepBoth, let store else { return HealthFindings(check: .pairs(rule)) }
        var pairs = try await HealthPairs(index.read { try $0.pairPhotos(of: nil) })
        return try await self.pairs(rule, store: store, following: &pairs)
    }

    /// What `rule` finds among `store`'s photos, judging only the groups of `pairs` that changed since
    /// they were last judged, and recording what they found there.
    func pairs(
        _ rule: PairRule,
        store: ColumnStore,
        following pairs: inout HealthPairs,
    ) async throws -> HealthFindings {
        guard rule != .keepBoth else { return HealthFindings(check: .pairs(rule)) }
        let definitions = definitions
        let keeping = definitions.keptAnyway.filter { $0.check == .pairs }
        let (stale, members) = pairs.stale(rule, keeping: keeping)
        guard !stale.isEmpty else { return pairs.findings(rule) }
        let drops = await Task.detached(priority: .userInitiated) {
            Self.everyCore(members.count) { Self.drops(rule, of: Self.pair(members[$0], store: store), store: store) }
        }.value
        let all = drops.flatMap(\.self)
        let texts = try await pairTexts(all, store: store)
        let keys = keeping.isEmpty ? [:] : try await contentKeys(all.map(\.dropped))
        let names = pairs.names
        let found = await Task.detached(priority: .userInitiated) {
            Self.everyCore(drops.count) { group in
                var findings: [HealthFinding] = []
                let kept = Self.findings(
                    rule, drops: drops[group], store: store, names: names, texts: texts, into: &findings,
                ) { dropped in
                    keys[dropped].map { key in
                        definitions.keeps(.pairs, contentKey: key.key, path: "", size: 0, modified: key.modified)
                    } ?? false
                }
                return (findings, kept)
            }
        }.value
        let judged = zip(stale, found).map { (key: $0, findings: $1.0, kept: $1.1) }
        pairs.record(rule, keeping: keeping, judged)
        return pairs.findings(rule)
    }

    /// `body` of each of `0 ..< count`, in order, worked out on every core a run at a time.
    static func everyCore<T: Sendable>(_ count: Int, _ body: @Sendable (Int) -> T) -> [T] {
        let run = 2048
        guard count > run else { return (0 ..< count).map(body) }
        let results = UnsafeMutableBufferPointer<T?>.allocate(capacity: count)
        results.initialize(repeating: nil)
        defer {
            results.deinitialize()
            results.deallocate()
        }
        nonisolated(unsafe) let output = results
        DispatchQueue.concurrentPerform(iterations: (count + run - 1) / run) { part in
            for index in part * run ..< min(count, (part + 1) * run) {
                output[index] = body(index)
            }
        }
        return results.map { $0! }
    }

    /// The photos of `members` that `store` holds as a raw, JPEG or HEIC, as `StackFinder` orders a
    /// pair's: by kind, then by name; none unless they're two or more.
    static func pair(_ members: [Int64], store: ColumnStore) -> [Int64] {
        var rows: [(photo: Int64, kind: UInt8, rank: Int32)] = []
        rows.reserveCapacity(members.count)
        for photo in members {
            guard let row = store.row(of: photo) else { continue }
            let kind = store.kinds[row]
            if kind >= 1, kind <= 3 {
                rows.append((photo, kind, store.nameRanks[row]))
            }
        }
        guard rows.count > 1 else { return [] }
        rows.sort { ($0.kind, $0.rank) < ($1.kind, $1.rank) }
        return rows.map(\.photo)
    }

    /// The halves `rule` drops of `stacks`' pairs that hold a raw and a JPEG or HEIC, each with the
    /// half kept beside it.
    static func drops(_ rule: PairRule, in stacks: Stacks, store: ColumnStore) -> [(dropped: Int64, kept: Int64)] {
        stacks.pairs.flatMap { drops(rule, of: Array(stacks.members(of: $0)), store: store) }
    }

    /// The halves `rule` drops of `pair`, if it holds a raw and a JPEG or HEIC, each with the half kept
    /// beside it: the JPEG, or the HEIC where there's none, to keep the JPEG. A pair with a half that can't
    /// be read, or is missing from its folder, is none.
    static func drops(_ rule: PairRule, of pair: [Int64], store: ColumnStore) -> [(dropped: Int64, kept: Int64)] {
        let leftOut = UInt8(PhotoRecord.State([.unreadable, .missing]).rawValue)
        let (raw, jpeg) = (UInt8(PhotoRecord.Kind.raw.rawValue), UInt8(PhotoRecord.Kind.jpeg.rawValue))
        let rows = pair.compactMap { photo in store.row(of: photo).map { (photo, $0) } }
        guard rows.count == pair.count, rows.allSatisfy({ store.states[$0.1] & leftOut == 0 }) else { return [] }
        let raws = rows.filter { store.kinds[$0.1] == raw }.map(\.0)
        let others = rows.filter { store.kinds[$0.1] != raw }.map(\.0)
        guard let first = raws.first, !others.isEmpty else { return [] }
        switch rule {
        case .keepRaw:
            return others.map { ($0, first) }
        case .keepJPEG:
            let kept = rows.first { store.kinds[$0.1] == jpeg }?.0 ?? others[0]
            return raws.map { ($0, kept) }
        case .keepBoth:
            return []
        }
    }

    /// `drops` as findings, `texts` holding the titles, captions and keywords of those that have any
    /// and of the halves kept beside them, and `isKept` saying which are kept anyway.
    static func findings(
        _ rule: PairRule, drops: [(dropped: Int64, kept: Int64)], store: ColumnStore, names: StackNames,
        texts: [Int64: PairTexts], isKept: (Int64) -> Bool,
    ) -> HealthFindings {
        var findings: [HealthFinding] = []
        let kept = Self.findings(rule, drops: drops, store: store, names: names, texts: texts, into: &findings, isKept)
        return HealthFindings(check: .pairs(rule), findings: findings, keptAnyway: kept)
    }

    /// Adds `drops` to `findings` as findings, returning how many were kept anyway.
    static func findings(
        _: PairRule, drops: [(dropped: Int64, kept: Int64)], store: ColumnStore, names: StackNames,
        texts: [Int64: PairTexts], into findings: inout [HealthFinding], _ isKept: (Int64) -> Bool,
    ) -> Int {
        findings.reserveCapacity(findings.count + drops.count)
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
        return kept
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
