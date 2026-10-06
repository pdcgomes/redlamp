import Foundation

/// A source's photos in order (LIB-10): their IDs in the sort's order, as the column store had them
/// when the list was made. A view's cells fetch their rows from the column store when they appear;
/// the list holds IDs only, 8 bytes a photo, with each one's place in it (4 bytes for every ID
/// between its lowest and its highest) and a bit per ID for the selections made in it.
public struct PhotoList: Sendable, RandomAccessCollection {
    public let source: PhotoSource
    public let sort: QuerySort
    /// The photos' IDs, in the sort's order.
    public let ids: ContiguousArray<Int64>
    /// The place of each ID from `lowest` up; -1 for none.
    private let places: ContiguousArray<Int32>
    private let lowest: Int64
    /// The photos in it, a bit per ID.
    let members: RowBits

    /// `source`'s photos as `ids`, in order: a list made from the index, or one a view makes of photos it
    /// lists itself (a folder the library hasn't indexed), whose IDs are its own. They must be unique and
    /// at least 0, and they're best dense: the list and its selections take a bit for every ID up to
    /// the highest, and 4 bytes for every ID between the lowest and the highest.
    public init(source: PhotoSource, sort: QuerySort = QuerySort(), ids: ContiguousArray<Int64>) {
        self.source = source
        self.sort = sort
        self.ids = ids
        var lowest = Int64.max
        var highest = Int64.min
        for id in ids {
            lowest = Swift.min(lowest, id)
            highest = Swift.max(highest, id)
        }
        guard !ids.isEmpty else {
            self.lowest = 0
            places = []
            members = RowBits(rows: 0)
            return
        }
        var places = ContiguousArray<Int32>(repeating: -1, count: Int(highest - lowest) + 1)
        var members = RowBits(rows: Int(highest) + 1)
        places.withUnsafeMutableBufferPointer { places in
            for (place, id) in ids.enumerated() {
                places[Int(id - lowest)] = Int32(place)
                members.insert(Int(id))
            }
        }
        self.lowest = lowest
        self.places = places
        self.members = members
    }

    public var startIndex: Int {
        0
    }

    public var endIndex: Int {
        ids.count
    }

    public subscript(position: Int) -> Int64 {
        ids[position]
    }

    /// Where photo `id` is in the list.
    public func index(of id: Int64) -> Int? {
        let offset = id &- lowest
        guard offset >= 0, offset < Int64(places.count) else { return nil }
        let place = places[Int(offset)]
        return place < 0 ? nil : Int(place)
    }

    public func contains(_ id: Int64) -> Bool {
        id >= 0 && Int(id) < members.wordCount << 6 && members.contains(Int(id))
    }
}

extension PhotoList: Equatable {
    public static func == (lhs: PhotoList, rhs: PhotoList) -> Bool {
        lhs.source == rhs.source && lhs.sort == rhs.sort && lhs.ids == rhs.ids
    }
}

public extension QueryEngine {
    /// `source`'s photos in `sort`'s order, from the column store as it is now (once a load or
    /// change in progress is done), loading it first if it hasn't been. Unlike `search`, it cancels
    /// nothing, so lists can be made while the filter bar searches.
    func list(_ source: PhotoSource, sort: QuerySort = QuerySort()) async throws -> PhotoList {
        var snapshot = await loadedSnapshot()
        if snapshot == nil {
            try await load()
            snapshot = self.snapshot()
        }
        guard let (store, vocabulary, generation) = snapshot else {
            return PhotoList(source: source, sort: sort, ids: [])
        }
        let rows = try await rows(of: source, in: store, vocabulary: vocabulary, generation: generation)
        return PhotoList(source: source, sort: sort, ids: store.ids(of: rows, sortedBy: sort))
    }
}

extension ColumnStore {
    /// The IDs of `rows`, in `sort`'s order.
    func ids(of rows: RowBits, sortedBy sort: QuerySort) -> ContiguousArray<Int64> {
        let order = order(sort.key)
        var ids = ContiguousArray<Int64>()
        ids.reserveCapacity(rows.count)
        _ = collect(rows, in: order, ascending: sort.ascending, from: 0, limit: .max, places: order.count, into: &ids)
        return ids
    }
}
