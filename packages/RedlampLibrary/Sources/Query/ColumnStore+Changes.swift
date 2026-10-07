import Foundation

public extension ColumnStore {
    /// Photos added or changed, with their rows as the index now has them, and photos removed.
    struct Changes: Sendable, Hashable {
        public var upserted: [Row]
        public var removed: [Int64]

        public init(upserted: [Row] = [], removed: [Int64] = []) {
            self.upserted = upserted
            self.removed = removed
        }

        public var isEmpty: Bool {
            upserted.isEmpty && removed.isEmpty
        }
    }

    /// Applies `changes`: removals first, then each upserted photo's row, written in place for a
    /// photo the store holds and added for one it doesn't, then each order put right. Each column and
    /// order is written only where its values change, so the pages a change doesn't touch are never
    /// copied.
    ///
    /// The store keeps no names, so `name` tells it the name of a photo it holds, to place the
    /// changed photos in the name order: it's asked about a few photos for each one, never about
    /// those in `changes`. A photo it has no name for sorts as an empty name.
    mutating func apply(_ changes: Changes, name: (Int64) throws -> String?) rethrows {
        var placing: [Int: String] = [:]
        var leaving = RowBits(rows: rowCount)
        for id in changes.removed {
            guard let index = row(of: id) else { continue }
            leaving.insert(index)
            kill(index)
        }
        for row in changes.upserted where row.hot.id >= 0 {
            if let index = self.row(of: row.hot.id) {
                set(row, at: index)
                leaving.grow(to: rowCount)
                leaving.insert(index)
                placing[index] = row.hot.name
            } else {
                append(row)
                placing[rowCount - 1] = row.hot.name
            }
        }
        guard !placing.isEmpty || !leaving.isEmpty else { return }
        leaving.grow(to: rowCount)
        var remaining: [QuerySort.Key: ContiguousArray<Int32>] = [:]
        for key in QuerySort.Key.allCases where keepsOrder(key) {
            remaining[key] = order(key).withUnsafeBufferPointer { order in
                leaving
                    .isEmpty ? ContiguousArray(order) :
                    ContiguousArray(order.lazy.filter { !leaving.contains(Int($0)) })
            }
        }

        let rows = placing.keys.sorted()
        var keys: [Int: [UInt8]] = [:]
        func key(ofRow row: Int) throws -> [UInt8] {
            if let key = keys[row] {
                return key
            }
            let key = try FinderOrder.key(placing[row] ?? name(ids[row]) ?? "")
            keys[row] = key
            return key
        }
        func namePrecedes(_ lhs: Int, _ rhs: Int) throws -> Bool {
            let (left, right) = try (key(ofRow: lhs), key(ofRow: rhs))
            return left == right ? ids[lhs] < ids[rhs] : left.lexicographicallyPrecedes(right)
        }
        let names = remaining[.name] ?? []
        var placed: [(place: Int, row: Int)] = []
        for row in rows {
            try placed.append((Self.place(of: row, in: names, precedes: namePrecedes), row))
        }
        try placed.sort { try $0.place == $1.place ? namePrecedes($0.row, $1.row) : $0.place < $1.place }
        updateOrder(.name, to: Self.inserting(placed, into: names))
        renumberNames()

        for sortKey in [QuerySort.Key.captured, .rating, .edited, .modified, .size] {
            guard let order = remaining[sortKey] else { continue }
            var placed = rows.map { row in
                (place: Self.place(of: row, in: order) { precedes($0, $1, by: sortKey) }, row: row)
            }
            placed.sort { $0.place == $1.place ? precedes($0.row, $1.row, by: sortKey) : $0.place < $1.place }
            updateOrder(sortKey, to: Self.inserting(placed, into: order))
        }
        if rowCount - count > max(1024, count / 4) {
            compact()
        }
    }

    /// Makes `key`'s order `rows`, writing only the pages where it changes.
    private mutating func updateOrder(_ key: QuerySort.Key, to rows: ContiguousArray<Int32>) {
        var order = order(key)
        rows.withUnsafeBufferPointer { order.update(from: $0) }
        setOrder(order, for: key)
    }
}

extension ColumnStore {
    /// How many of `order`'s rows come before `row`.
    static func place(of row: Int, in order: ContiguousArray<Int32>, precedes: (Int, Int) throws -> Bool) rethrows
        -> Int {
        var low = 0
        var high = order.count
        while low < high {
            let middle = (low + high) / 2
            if try precedes(Int(order[middle]), row) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// `order` with each of `placed`'s rows at its place, given in order.
    static func inserting(_ placed: [(place: Int, row: Int)], into order: ContiguousArray<Int32>)
        -> ContiguousArray<Int32> {
        var result = ContiguousArray<Int32>()
        result.reserveCapacity(order.count + placed.count)
        var copied = 0
        for (place, row) in placed {
            result.append(contentsOf: order[copied ..< place])
            copied = place
            result.append(Int32(row))
        }
        result.append(contentsOf: order[copied...])
        return result
    }
}
