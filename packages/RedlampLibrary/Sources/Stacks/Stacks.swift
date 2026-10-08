import Foundation

/// A library's stacks (LIB-28), as `StackFinder` finds them, and each photo's: pairs first, then
/// bursts and manual stacks, then focus suggestions. A photo is in one pair at most, and it (or its
/// pair) in one burst or manual stack at most; suggestions overlap them.
public struct Stacks: Sendable, RandomAccessCollection {
    /// Every stack's photos, one stack after another: stack `index`'s from `starts[index]` up to
    /// `starts[index + 1]`.
    let members: ContiguousArray<Int64>
    let starts: ContiguousArray<Int32>
    let kinds: ContiguousArray<Stack.Kind>
    /// Manual stacks' IDs, by stack.
    let ids: [Int32: UUID]
    let pairs: Range<Int>
    /// Bursts and manual stacks.
    let groups: Range<Int>
    let suggestions: Range<Int>
    /// For each photo ID up to the largest: its pair, -1 for none.
    let pairOf: ContiguousArray<Int32>
    /// For each photo ID: the burst or manual stack holding it or its pair, -1 for none.
    let groupOf: ContiguousArray<Int32>
    /// For each photo ID: the first focus suggestion holding it, -1 for none.
    let suggestionOf: ContiguousArray<Int32>

    public init() {
        self.init(members: [], starts: [0], kinds: [], ids: [:], pairs: 0, groups: 0, photos: 0)
    }

    /// Stacks `members` and `starts` hold, the first `pairs` of them pairs and the next `groups`
    /// bursts and manual stacks, for photos with IDs below `photos`.
    init(
        members: ContiguousArray<Int64>, starts: ContiguousArray<Int32>, kinds: ContiguousArray<Stack.Kind>,
        ids: [Int32: UUID], pairs: Int, groups: Int, photos: Int,
    ) {
        let (pairs, groups, suggestions) = (0 ..< pairs, pairs ..< pairs + groups, pairs + groups ..< kinds.count)
        var pairOf = ContiguousArray<Int32>(repeating: -1, count: photos)
        var groupOf = ContiguousArray<Int32>(repeating: -1, count: photos)
        var suggestionOf = ContiguousArray<Int32>(repeating: -1, count: suggestions.isEmpty ? 0 : photos)
        members.withUnsafeBufferPointer { members in
            for stack in pairs {
                for photo in members[Int(starts[stack]) ..< Int(starts[stack + 1])] {
                    pairOf[Int(photo)] = Int32(stack)
                }
            }
            for stack in groups {
                for top in members[Int(starts[stack]) ..< Int(starts[stack + 1])] {
                    let pair = pairOf[Int(top)]
                    guard pair >= 0 else {
                        groupOf[Int(top)] = Int32(stack)
                        continue
                    }
                    for photo in members[Int(starts[Int(pair)]) ..< Int(starts[Int(pair) + 1])] {
                        groupOf[Int(photo)] = Int32(stack)
                    }
                }
            }
            for stack in suggestions {
                for photo in members[Int(starts[stack]) ..< Int(starts[stack + 1])] where suggestionOf[Int(photo)] < 0 {
                    suggestionOf[Int(photo)] = Int32(stack)
                }
            }
        }
        self.members = members
        self.starts = starts
        self.kinds = kinds
        self.ids = ids
        self.pairs = pairs
        self.groups = groups
        self.suggestions = suggestions
        self.pairOf = pairOf
        self.groupOf = groupOf
        self.suggestionOf = suggestionOf
    }

    public var startIndex: Int {
        0
    }

    public var endIndex: Int {
        kinds.count
    }

    public subscript(position: Int) -> Stack {
        Stack(kind: kinds[position], photos: Array(members(of: position)), id: ids[Int32(position)])
    }

    /// How many stacks of `kind` there are.
    public func count(of kind: Stack.Kind) -> Int {
        switch kind {
        case .pair: pairs.count
        case .burst, .manual: groups.count { kinds[$0] == kind }
        case .focus: suggestions.count
        }
    }

    /// The pair `photo` is in.
    public func pair(containing photo: Int64) -> Stack? {
        pairIndex(of: photo).map { self[$0] }
    }

    /// The burst or manual stack holding `photo`, or its pair.
    public func stack(containing photo: Int64) -> Stack? {
        groupIndex(of: photo).map { self[$0] }
    }

    /// The index of the burst or manual stack holding `photo` or its pair, without making the stack: for checks
    /// over many photos.
    public func stackIndex(containing photo: Int64) -> Int? {
        groupIndex(of: photo)
    }

    /// The index of the pair `photo` is in, without making the stack.
    public func pairIndex(containing photo: Int64) -> Int? {
        pairIndex(of: photo)
    }

    /// A focus suggestion holding `photo`.
    public func suggestion(containing photo: Int64) -> Stack? {
        guard photo >= 0, photo < suggestionOf.count, suggestionOf[Int(photo)] >= 0 else { return nil }
        return self[Int(suggestionOf[Int(photo)])]
    }

    /// Every photo of `stack`, with a pair's others after its raw.
    public func allPhotos(of stack: Stack) -> [Int64] {
        guard stack.kind != .pair else { return stack.photos }
        return stack.photos.flatMap(frame(of:))
    }

    /// These stacks over other IDs: each photo `id` gives one has that one, and the stacks holding none of
    /// those photos are left out. A kept stack keeps its other photos, which take IDs after `largest`, the
    /// largest `id` gives, and a kept burst or manual stack keeps its frames' pairs, so a list of the photos
    /// `id` gives shows the stacks as one of the library's own IDs does. For a view whose photos have IDs of
    /// their own; call it off the main thread.
    public func relabelled(above largest: Int64, by id: (Int64) -> Int64?) -> Stacks {
        func isShown(frame top: Int64) -> Bool {
            guard let pair = pairIndex(of: top) else { return id(top) != nil }
            return members(of: pair).contains { id($0) != nil }
        }
        var kept = [Bool](repeating: false, count: count)
        for pair in pairs {
            kept[pair] = members(of: pair).contains { id($0) != nil }
        }
        for stack in groups.lowerBound ..< kinds.count where members(of: stack).contains(where: isShown(frame:)) {
            kept[stack] = true
            for top in members(of: stack) {
                if let pair = pairIndex(of: top) {
                    kept[pair] = true
                }
            }
        }
        var given: [Int64: Int64] = [:]
        var next = largest + 1
        func relabelled(_ photo: Int64) -> Int64 {
            if let shown = id(photo) {
                return shown
            }
            if let earlier = given[photo] {
                return earlier
            }
            given[photo] = next
            next += 1
            return next - 1
        }
        var made = (
            members: ContiguousArray<Int64>(), starts: ContiguousArray<Int32>([0]),
            kinds: ContiguousArray<Stack.Kind>(), ids: [Int32: UUID](), pairs: 0, groups: 0,
        )
        for stack in 0 ..< count where kept[stack] {
            for photo in members(of: stack) {
                made.members.append(relabelled(photo))
            }
            made.starts.append(Int32(made.members.count))
            if let uuid = ids[Int32(stack)] {
                made.ids[Int32(made.kinds.count)] = uuid
            }
            made.kinds.append(kinds[stack])
            if pairs.contains(stack) {
                made.pairs += 1
            } else if groups.contains(stack) {
                made.groups += 1
            }
        }
        return Stacks(
            members: made.members, starts: made.starts, kinds: made.kinds, ids: made.ids, pairs: made.pairs,
            groups: made.groups, photos: Int((made.members.max() ?? -1) + 1),
        )
    }

    /// Bytes its arrays hold, as allocated.
    public var memoryFootprint: Int {
        func bytes<T>(_ array: ContiguousArray<T>) -> Int {
            array.capacity * MemoryLayout<T>.stride
        }
        return bytes(members) + bytes(starts) + bytes(kinds) + bytes(pairOf) + bytes(groupOf) + bytes(suggestionOf)
            + ids.capacity * 24
    }

    // MARK: - Lookups

    func members(of stack: Int) -> ArraySlice<Int64> {
        members[memberRange(of: stack)]
    }

    func memberRange(of stack: Int) -> Range<Int> {
        Int(starts[stack]) ..< Int(starts[stack + 1])
    }

    func pairIndex(of photo: Int64) -> Int? {
        guard photo >= 0, photo < pairOf.count else { return nil }
        let pair = pairOf[Int(photo)]
        return pair < 0 ? nil : Int(pair)
    }

    func groupIndex(of photo: Int64) -> Int? {
        guard photo >= 0, photo < groupOf.count else { return nil }
        let group = groupOf[Int(photo)]
        return group < 0 ? nil : Int(group)
    }

    /// The photos shown as one with `photo`: its pair's, raw first, or it alone.
    func frame(of photo: Int64) -> [Int64] {
        pairIndex(of: photo).map { Array(members(of: $0)) } ?? [photo]
    }
}
