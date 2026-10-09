import Foundation
import RedlampDocument

/// What the user decided about stacks (LIB-28): photos stacked by hand from any folders, photos
/// taken out of stacks, the photo shown for a stack, and the order of a stack's photos. Each photo's
/// choice is its sidecar's `metadata.stack`, which the index keeps in its `stack`, `stack_top` and
/// `stack_position` columns as the photo is indexed (`init(_:)` reads them, `save(_:in:)` writes them),
/// so a rebuilt index has them all.
///
/// A raw and its JPEG are one photo: each choice is made for both, and a pair whose photos disagree
/// takes the choice of its first photo with one, the raw first.
public struct StackChoices: Sendable, Hashable {
    /// One photo's choice, as its sidecar's `metadata.stack` holds it: `{"id": "…", "top": true}`. A
    /// photo with an `id` is in the manual stack of that ID, wherever its other photos are, and one whose
    /// ID no other photo has stands alone; either way it's in no burst. `top` shows it for its stack:
    /// the manual stack `id` names, or else the burst it's in. `position` is its place in the manual
    /// stack once the stack's photos have been put in an order.
    public typealias Choice = PhotoStack

    /// By photo ID.
    public private(set) var choices: [Int64: Choice]

    public init(_ choices: [Int64: Choice] = [:]) {
        self.choices = choices
    }

    public subscript(photo: Int64) -> Choice? {
        choices[photo]
    }

    public var isEmpty: Bool {
        choices.isEmpty
    }

    /// Stacks `photos` by hand, with their pairs' others, taking them out of any stack they were in;
    /// `top`, which joins them, is shown for the stack, else the one taken first. Returns the photos
    /// whose choice changed.
    @discardableResult
    public mutating func stack(_ photos: some Sequence<Int64>, top: Int64? = nil, in stacks: Stacks) -> [Int64] {
        let id = UUID()
        let shown = Set(top.map(stacks.frame(of:)) ?? [])
        var changed: [Int64] = []
        var seen = Set<Int64>()
        for photo in Array(photos) + (top.map { [$0] } ?? []) {
            for member in stacks.frame(of: photo) where seen.insert(member).inserted {
                choices[member] = Choice(id: id, top: shown.contains(member))
                changed.append(member)
            }
        }
        return changed
    }

    /// Takes apart the bursts and manual stacks holding `photos` or their pairs, as Lightroom Classic's
    /// Unstack does: every photo of them stands alone, in no burst, as each of `photos` in none does. A
    /// raw and its JPEG stay one photo. Returns the photos whose choice changed.
    @discardableResult
    public mutating func unstack(_ photos: some Sequence<Int64>, in stacks: Stacks) -> [Int64] {
        var frames: [Int64] = []
        var groups = Set<Int>()
        for photo in photos {
            guard let group = stacks.groupIndex(of: photo) else {
                frames.append(photo)
                continue
            }
            if groups.insert(group).inserted {
                frames += stacks.members(of: group)
            }
        }
        return remove(frames, in: stacks)
    }

    /// Takes `photos` and their pairs' others out of their stacks, as Lightroom Classic's Remove from
    /// Stack does: each stands alone, in no burst, and a stack left with one photo is no longer one.
    /// Returns the photos whose choice changed.
    @discardableResult
    public mutating func remove(_ photos: some Sequence<Int64>, in stacks: Stacks) -> [Int64] {
        var changed: [Int64] = []
        var seen = Set<Int64>()
        for photo in photos {
            let frame = stacks.frame(of: photo)
            guard seen.insert(frame[0]).inserted else { continue }
            let id = UUID()
            for member in frame {
                choices[member] = Choice(id: id)
                changed.append(member)
            }
        }
        return changed
    }

    /// Shows `photo` for the burst or manual stack holding it; a pair always shows its raw. The others
    /// keep their places. Returns the photos whose choice changed.
    @discardableResult
    public mutating func setTop(_ photo: Int64, in stacks: Stacks) -> [Int64] {
        guard let group = stacks.groupIndex(of: photo) else { return [] }
        let shown = Set(stacks.frame(of: photo))
        var changed: [Int64] = []
        for frame in stacks.members(of: group) {
            for member in stacks.frame(of: frame) {
                let top = shown.contains(member)
                guard choices[member]?.top != top, choices[member] != nil || top else { continue }
                var choice = choices[member] ?? Choice()
                choice.top = top
                choices[member] = choice.id == nil && !top ? nil : choice
                changed.append(member)
            }
        }
        return changed
    }

    /// Splits the burst or manual stack holding `photo` before it, as Lightroom Classic's Split Stack does:
    /// the photos above it stay a stack, and it and those below it become a stack made by hand of their
    /// own, in their order, with it on top. A part left with one photo stands alone, and a burst's photos
    /// above it become a stack made by hand. Returns the photos whose choice changed.
    @discardableResult
    public mutating func split(before photo: Int64, in stacks: Stacks) -> [Int64] {
        guard let group = stacks.groupIndex(of: photo) else { return [] }
        let frames = Array(stacks.members(of: group))
        guard let index = frames.firstIndex(of: stacks.frame(of: photo)[0]), index > 0 else { return [] }
        var changed: [Int64] = []
        if stacks.kinds[group] == .burst {
            changed += separate(Array(frames[..<index]), in: stacks)
        }
        changed += separate(Array(frames[index...]), in: stacks)
        return changed
    }

    /// Moves `photo`'s frame `offset` places down the burst or manual stack holding it, up when it's
    /// negative, as far as the stack goes, counting only the frames `among` holds when it's given (those
    /// a view shows, by their photos): Lightroom Classic's Move Up and Move Down in Stack. See
    /// `place(_:at:in:)`. Returns the photos whose choice changed.
    @discardableResult
    public mutating func move(
        _ photo: Int64, by offset: Int, among shown: Set<Int64>? = nil, in stacks: Stacks,
    ) -> [Int64] {
        guard offset != 0, let group = stacks.groupIndex(of: photo) else { return [] }
        let moving = stacks.frame(of: photo)[0]
        let frames = stacks.members(of: group).filter { frame in
            frame == moving || shown.map { shown in stacks.frame(of: frame).contains(where: shown.contains) } ?? true
        }
        guard let index = frames.firstIndex(of: moving) else { return [] }
        let target = min(max(index + offset, 0), frames.count - 1)
        guard target != index else { return [] }
        return place([moving], at: frames[target], in: stacks)
    }

    /// Moves the frames of `photos` to `target`'s place in the burst or manual stack holding them and it,
    /// in their own order: before `target` when the first of them is below it, after it when above. The
    /// stack keeps the order in each of its photos' places, its first on top, and a burst becomes a stack
    /// made by hand. Nothing changes when a photo is in another stack, or `target` is among them. Returns
    /// the photos whose choice changed.
    @discardableResult
    public mutating func place(_ photos: some Sequence<Int64>, at target: Int64, in stacks: Stacks) -> [Int64] {
        guard let group = stacks.groupIndex(of: target) else { return [] }
        let frames = Array(stacks.members(of: group))
        let moving = Set(photos.map { stacks.frame(of: $0)[0] })
        let into = stacks.frame(of: target)[0]
        guard !moving.isEmpty, !moving.contains(into), moving.allSatisfy(frames.contains),
              let first = frames.firstIndex(where: moving.contains), let at = frames.firstIndex(of: into)
        else { return [] }
        var order = frames.filter { !moving.contains($0) }
        let block = frames.filter(moving.contains)
        order.insert(contentsOf: block, at: (order.firstIndex(of: into) ?? 0) + (first > at ? 0 : 1))
        guard order != frames else { return [] }
        return arrange(order, as: stacks.ids[Int32(group)] ?? UUID(), in: stacks)
    }

    /// Forgets what was decided for `photos` and their pairs' others, which are stacked again as
    /// they're found. Returns the photos whose choice changed.
    @discardableResult
    public mutating func reset(_ photos: some Sequence<Int64>, in stacks: Stacks) -> [Int64] {
        var changed: [Int64] = []
        for photo in photos {
            for member in stacks.frame(of: photo) where choices.removeValue(forKey: member) != nil {
                changed.append(member)
            }
        }
        return changed
    }

    // MARK: - Helpers

    /// `frames` made a stack by hand of their own, the first on top, each keeping its place; one frame
    /// alone stands alone.
    private mutating func separate(_ frames: [Int64], in stacks: Stacks) -> [Int64] {
        guard frames.count > 1 else { return remove(frames, in: stacks) }
        let id = UUID()
        var changed: [Int64] = []
        for (index, frame) in frames.enumerated() {
            for member in stacks.frame(of: frame) {
                let position = choices[member]?.id == nil ? nil : choices[member]?.position
                let choice = Choice(id: id, top: index == 0, position: position)
                guard choices[member] != choice else { continue }
                choices[member] = choice
                changed.append(member)
            }
        }
        return changed
    }

    /// The manual stack `id` of `frames` in their order, each photo's place written, the first on top;
    /// what newer builds added to a photo's choice is kept.
    private mutating func arrange(_ frames: [Int64], as id: UUID, in stacks: Stacks) -> [Int64] {
        var changed: [Int64] = []
        for (position, frame) in frames.enumerated() {
            for member in stacks.frame(of: frame) {
                var choice = choices[member] ?? Choice()
                choice.id = id
                choice.top = position == 0
                choice.position = position
                guard choices[member] != choice else { continue }
                choices[member] = choice
                changed.append(member)
            }
        }
        return changed
    }
}

public extension StackChoices {
    /// The choices `reader`'s index keeps, but those of the photos of roots marked removed.
    init(_ reader: some IndexQueries) throws {
        var choices: [Int64: Choice] = [:]
        try reader.database.cached("""
        SELECT id, stack, stack_top, stack_position FROM photos
          WHERE (stack IS NOT NULL OR stack_top != 0) AND \(reader.inLibrary())
        """).forEachRow { row in
            if let choice = PhotoRecord.storedStack(
                id: row.string(at: 1), top: row.bool(at: 2), position: row.optionalInt(at: 3),
            ) {
                choices[row.int64(at: 0)] = choice
            }
        }
        self.init(choices)
    }

    /// Keeps `photos`' choices in `writer`'s index, clearing those of photos without one.
    func save(_ photos: some Sequence<Int64>, in writer: LibraryIndex.Writer) throws {
        let statement = try writer.database.cached(
            "UPDATE photos SET stack = ?, stack_top = ?, stack_position = ? WHERE id = ?",
        )
        for photo in photos {
            try statement.bind(choices[photo]?.id?.uuidString, at: 1)
            try statement.bind(choices[photo]?.top ?? false, at: 2)
            try statement.bind(choices[photo]?.id == nil ? nil : choices[photo]?.position, at: 3)
            try statement.bind(photo, at: 4)
            try statement.run()
        }
    }
}
