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
