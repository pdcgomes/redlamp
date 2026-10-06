import Foundation

/// The photos that can be in a raw and JPEG pair, by folder and name without its extension, and
/// what the pairs check found among them under each rule (LIB-40, LIB-28). The query engine keeps it
/// with its column store and brings it up to date from the store's changes, so after a change only
/// the pairs whose photos changed are judged again.
struct HealthPairs: Sendable {
    /// A photo as the index has it.
    struct Photo: Sendable, Hashable {
        var id: Int64
        var folder: Int64
        var name: String
        var kind: UInt8
    }

    /// A folder and a name without its extension, compared as APFS compares names, as naming pairs
    /// them (`NamingJob`).
    struct Key: Sendable, Hashable, Comparable {
        var folder: Int64
        var base: String

        static func < (lhs: Key, rhs: Key) -> Bool {
            lhs.folder != rhs.folder ? lhs.folder < rhs.folder : lhs.base < rhs.base
        }
    }

    /// What the check found under a rule: each group's findings one after another, in `groups`' order.
    private struct Found: Sendable {
        var findings: [HealthFinding] = []
        /// Each group's findings, and its findings kept anyway, in `groups`' order.
        var counts: [Int32] = []
        var kept: [Int32] = []
        var keptAnyway = 0
        /// The groups whose photos changed since they were judged.
        var stale: Set<Key> = []
        /// What was kept anyway when they were judged.
        var keeping: [KeptAnyway]

        /// Makes room for a group that holds a pair now, to be judged.
        mutating func insertGroup(at place: Int) {
            counts.insert(0, at: place)
            kept.insert(0, at: place)
        }

        mutating func removeGroup(at place: Int) {
            let start = counts[..<place].reduce(0) { $0 + Int($1) }
            findings.removeSubrange(start ..< start + Int(counts[place]))
            keptAnyway -= Int(kept[place])
            counts.remove(at: place)
            kept.remove(at: place)
        }
    }

    /// The names of the photos that can be in a pair, by ID.
    private(set) var names = StackNames()
    /// Their folders by ID; -1 for a photo that can't be in a pair.
    private var folders = ContiguousArray<Int64>()
    private var members: [Key: [Int64]] = [:]
    /// The keys with two photos or more, in order, and their photos.
    private(set) var groups: [Key] = []
    private var grouped: [[Int64]] = []
    private var found: [PairRule: Found] = [:]

    /// Groups changed at once beyond which a rule's findings are worked out again whole.
    static let patched = 256

    init(_ photos: [Photo]) {
        let largest = Int(photos.lazy.map(\.id).max() ?? 0)
        names.reserveCapacity(largest + 1)
        folders.reserveCapacity(largest + 1)
        members.reserveCapacity(photos.count)
        for photo in photos {
            add(photo)
        }
        group()
    }

    private mutating func group() {
        let sorted = members.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        groups = sorted.map(\.key)
        grouped = sorted.map(\.value)
    }

    /// Brings photos `ids` up to date with `photos`, how the index has them now; those of `ids` not
    /// in `photos` are gone.
    mutating func update(_ ids: some Sequence<Int64>, to photos: [Photo]) {
        var changed = Set<Key>()
        for id in ids {
            if let key = key(of: id) {
                changed.insert(key)
                remove(id, from: key)
            }
        }
        for photo in photos {
            if let key = key(of: photo.id) {
                changed.insert(key)
                remove(photo.id, from: key)
            }
            if let key = add(photo) {
                changed.insert(key)
            }
        }
        guard !changed.isEmpty else { return }
        if changed.count > Self.patched {
            group()
            found.removeAll()
            return
        }
        for key in changed {
            let place = Self.place(of: key, in: groups)
            let listed = place < groups.count && groups[place] == key
            let pairs = members[key, default: []].count > 1
            for rule in Array(found.keys) {
                found[rule]?.stale.insert(key)
                if listed, !pairs {
                    found[rule]?.removeGroup(at: place)
                } else if !listed, pairs {
                    found[rule]?.insertGroup(at: place)
                }
            }
            if listed, !pairs {
                groups.remove(at: place)
                grouped.remove(at: place)
            } else if !listed, pairs {
                groups.insert(key, at: place)
                grouped.insert(members[key, default: []], at: place)
            } else if listed {
                grouped[place] = members[key, default: []]
            }
        }
    }

    /// The groups to judge under `rule` before its findings are up to date, with `keeping` kept
    /// anyway, and their photos in no order: those that changed, or all of them.
    func stale(_ rule: PairRule, keeping: [KeptAnyway]) -> (keys: [Key], members: [[Int64]]) {
        guard let found = found[rule], found.keeping == keeping else { return (groups, grouped) }
        let keys = found.stale.sorted()
        return (keys, keys.map { members[$0] ?? [] })
    }

    /// Records what judging `groups` under `rule` found, each group's findings and those kept anyway,
    /// with `keeping` kept anyway. Judging every group starts the rule's findings again.
    mutating func record(
        _ rule: PairRule, keeping: [KeptAnyway], _ judged: [(key: Key, findings: [HealthFinding], kept: Int)],
    ) {
        guard var found = found[rule], found.keeping == keeping else {
            precondition(judged.count == groups.count, "a rule's findings start again from every group, in order")
            var whole = Found(keeping: keeping)
            whole.findings.reserveCapacity(judged.count)
            whole.counts.reserveCapacity(judged.count)
            whole.kept.reserveCapacity(judged.count)
            for group in judged {
                whole.findings += group.findings
                whole.counts.append(Int32(group.findings.count))
                whole.kept.append(Int32(group.kept))
                whole.keptAnyway += group.kept
            }
            found[rule] = whole
            return
        }
        self.found[rule] = nil
        var places = judged.compactMap { group -> (
            place: Int,
            group: (key: Key, findings: [HealthFinding], kept: Int)
        )? in
            let place = Self.place(of: group.key, in: groups)
            return place < groups.count && groups[place] == group.key ? (place, group) : nil
        }
        places.sort { $0.place > $1.place }
        var starts = [Int](repeating: 0, count: found.counts.count + 1)
        for (place, count) in found.counts.enumerated() {
            starts[place + 1] = starts[place] + Int(count)
        }
        for (place, group) in places {
            found.findings.replaceSubrange(starts[place] ..< starts[place + 1], with: group.findings)
            found.keptAnyway += group.kept - Int(found.kept[place])
            found.counts[place] = Int32(group.findings.count)
            found.kept[place] = Int32(group.kept)
        }
        found.stale.subtract(judged.map(\.key))
        self.found[rule] = found
    }

    /// What `rule` found, once every stale group is recorded.
    func findings(_ rule: PairRule) -> HealthFindings {
        let found = found[rule]
        return HealthFindings(
            check: .pairs(rule), findings: found?.findings ?? [], keptAnyway: found?.keptAnyway ?? 0,
        )
    }

    // MARK: - Photos

    private func key(of id: Int64) -> Key? {
        guard id >= 0, id < folders.count, folders[Int(id)] >= 0 else { return nil }
        return Self.key(folder: folders[Int(id)], name: names[id])
    }

    private static func key(folder: Int64, name: String) -> Key? {
        let (base, ext) = NamingJob.split(name)
        return ext.isEmpty ? nil : Key(folder: folder, base: NamingJob.fold(base))
    }

    @discardableResult
    private mutating func add(_ photo: Photo) -> Key? {
        guard photo.id >= 0, photo.kind >= 1, photo.kind <= 3,
              let key = Self.key(folder: photo.folder, name: photo.name)
        else { return nil }
        if photo.id >= folders.count {
            folders.append(contentsOf: repeatElement(-1, count: Int(photo.id) + 1 - folders.count))
        }
        folders[Int(photo.id)] = photo.folder
        names[photo.id] = photo.name
        members[key, default: []].append(photo.id)
        return key
    }

    private mutating func remove(_ id: Int64, from key: Key) {
        folders[Int(id)] = -1
        names[id] = ""
        members[key]?.removeAll { $0 == id }
        if members[key]?.isEmpty == true {
            members[key] = nil
        }
    }

    /// Where `key` is in `keys`, or would be.
    private static func place(of key: Key, in keys: [Key]) -> Int {
        var (low, high) = (0, keys.count)
        while low < high {
            let middle = (low + high) / 2
            if keys[middle] < key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

extension IndexQueries {
    /// Photos `ids` that can be in a pair as the index has them now, or every such photo when nil.
    func pairPhotos(of ids: [Int64]?) throws -> [HealthPairs.Photo] {
        var photos: [HealthPairs.Photo] = []
        func add(_ row: SQLiteStatement) {
            photos.append(HealthPairs.Photo(
                id: row.int64(at: 0), folder: row.int64(at: 1), name: row.string(at: 2) ?? "",
                kind: UInt8(clamping: row.int(at: 3)),
            ))
        }
        let columns = "SELECT id, folder, name, kind FROM photos WHERE kind BETWEEN 1 AND 3"
        guard let ids else {
            try database.cached(columns).forEachRow(add)
            return photos
        }
        let statement = try database.cached(columns + " AND id = ?")
        for id in Set(ids) {
            try statement.bind(id, at: 1)
            try statement.forEachRow(add)
        }
        return photos
    }
}
