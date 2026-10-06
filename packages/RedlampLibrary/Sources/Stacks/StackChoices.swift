import Foundation

/// What the user decided about stacks (LIB-28): photos stacked by hand from any folders, photos
/// taken out of stacks, and the photo shown for a stack. Each photo's choice is what its sidecar is
/// to keep as `metadata.stack`; until the sidecar format has that field, the index's settings keep
/// them (`init(_:)` and `save(_:in:)`).
///
/// A raw and its JPEG are one photo: each choice is made for both, and a pair whose photos disagree
/// takes the choice of its first photo with one, the raw first.
public struct StackChoices: Sendable, Hashable {
    /// One photo's choice, as its sidecar's `metadata.stack` is to hold it: `{"id": "…", "top": true}`.
    public struct Choice: Sendable, Hashable, Codable {
        /// The manual stack it's in: photos with one ID are one stack wherever they are, and a photo
        /// whose ID no other photo has stands alone. Either way it's in no burst.
        public var id: UUID?
        /// It's shown for its stack: the manual stack `id` names, or else the burst it's in.
        public var top: Bool

        public init(id: UUID? = nil, top: Bool = false) {
            self.id = id
            self.top = top
        }

        private enum CodingKeys: String, CodingKey {
            case id, top
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id)
            top = try container.decodeIfPresent(Bool.self, forKey: .top) ?? false
        }

        /// Leaves out `top` when it's false, as the sidecar leaves out defaults.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(id, forKey: .id)
            if top {
                try container.encode(true, forKey: .top)
            }
        }
    }

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
    /// The settings key of photo `photo`'s choice: `library.stack.<photo>`.
    internal static let keyPrefix = "library.stack."

    /// The choices `reader`'s index keeps.
    init(_ reader: some IndexQueries) throws {
        let statement = try reader.database.cached("SELECT key, value FROM settings WHERE key >= ? AND key < ?")
        try statement.bind(Self.keyPrefix, at: 1)
        try statement.bind(String(Self.keyPrefix.dropLast()) + "/", at: 2)
        let decoder = JSONDecoder()
        var choices: [Int64: Choice] = [:]
        try statement.forEachRow { row in
            guard let key = row.string(at: 0), let photo = Int64(key.dropFirst(Self.keyPrefix.count)),
                  let value = row.string(at: 1), let choice = try? decoder.decode(Choice.self, from: Data(value.utf8))
            else { return }
            choices[photo] = choice
        }
        self.init(choices)
    }

    /// Keeps `photos`' choices in `writer`'s index, dropping those of photos without one.
    func save(_ photos: some Sequence<Int64>, in writer: LibraryIndex.Writer) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for photo in photos {
            let value = try choices[photo].map { try String(decoding: encoder.encode($0), as: UTF8.self) }
            try writer.setSetting(value, for: Self.keyPrefix + String(photo))
        }
    }
}
