import Foundation
import RedlampDocument

/// What the user decided about stacks (LIB-28): photos stacked by hand from any folders, photos
/// taken out of stacks, and the photo shown for a stack. Each photo's choice is its sidecar's
/// `metadata.stack`, which the index keeps in its `stack` and `stack_top` columns as the photo is
/// indexed (`init(_:)` reads them, `save(_:in:)` writes them), so a rebuilt index has them all.
///
/// A raw and its JPEG are one photo: each choice is made for both, and a pair whose photos disagree
/// takes the choice of its first photo with one, the raw first.
public struct StackChoices: Sendable, Hashable {
    /// One photo's choice, as its sidecar's `metadata.stack` holds it: `{"id": "…", "top": true}`. A
    /// photo with an `id` is in the manual stack of that ID, wherever its other photos are, and one whose
    /// ID no other photo has stands alone; either way it's in no burst. `top` shows it for its stack:
    /// the manual stack `id` names, or else the burst it's in.
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

    /// Takes `photos` and their pairs' others out of their stacks: each stands alone, in no burst,
    /// and a stack left with one photo is no longer one. Returns the photos whose choice changed.
    @discardableResult
    public mutating func unstack(_ photos: some Sequence<Int64>, in stacks: Stacks) -> [Int64] {
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

    /// Shows `photo` for the burst or manual stack holding it; a pair always shows its raw. Returns
    /// the photos whose choice changed.
    @discardableResult
    public mutating func setTop(_ photo: Int64, in stacks: Stacks) -> [Int64] {
        guard let group = stacks.groupIndex(of: photo) else { return [] }
        let shown = Set(stacks.frame(of: photo))
        var changed: [Int64] = []
        for frame in stacks.members(of: group) {
            for member in stacks.frame(of: frame) {
                let choice = choices[member]
                let top = shown.contains(member)
                guard choice?.top != top, choice != nil || top else { continue }
                let id = choice?.id
                choices[member] = id == nil && !top ? nil : Choice(id: id, top: top)
                changed.append(member)
            }
        }
        return changed
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
}

public extension StackChoices {
    /// The choices `reader`'s index keeps.
    init(_ reader: some IndexQueries) throws {
        var choices: [Int64: Choice] = [:]
        try reader.database.cached("SELECT id, stack, stack_top FROM photos WHERE stack IS NOT NULL OR stack_top != 0")
            .forEachRow { row in
                if let choice = PhotoRecord.storedStack(id: row.string(at: 1), top: row.bool(at: 2)) {
                    choices[row.int64(at: 0)] = choice
                }
            }
        self.init(choices)
    }

    /// Keeps `photos`' choices in `writer`'s index, clearing those of photos without one.
    func save(_ photos: some Sequence<Int64>, in writer: LibraryIndex.Writer) throws {
        let statement = try writer.database.cached("UPDATE photos SET stack = ?, stack_top = ? WHERE id = ?")
        for photo in photos {
            try statement.bind(choices[photo]?.id?.uuidString, at: 1)
            try statement.bind(choices[photo]?.top ?? false, at: 2)
            try statement.bind(photo, at: 3)
            try statement.run()
        }
    }
}
