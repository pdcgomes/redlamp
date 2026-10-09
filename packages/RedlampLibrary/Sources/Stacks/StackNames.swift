import Foundation

/// Photos' names by ID, which pairs are found from: the index's, or made up for the benchmarks.
public struct StackNames: Sendable {
    /// By ID; empty for none.
    private var names: ContiguousArray<String> = []

    public init() {}

    /// Every photo's name in `reader`'s index, but those of roots marked removed.
    public init(_ reader: some IndexQueries) throws {
        var names = StackNames()
        let photos = try reader.database.cached("SELECT id, name FROM photos WHERE \(reader.inLibrary()) ORDER BY id")
        try photos.forEachRow { row in
            names[row.int64(at: 0)] = row.string(at: 1) ?? ""
        }
        self = names
    }

    public subscript(photo: Int64) -> String {
        get {
            photo >= 0 && photo < names.count ? names[Int(photo)] : ""
        }
        set {
            guard photo >= 0 else { return }
            if photo >= names.count {
                names.append(contentsOf: repeatElement("", count: Int(photo) + 1 - names.count))
            }
            names[Int(photo)] = newValue
        }
    }

    public mutating func reserveCapacity(_ photos: Int) {
        names.reserveCapacity(photos)
    }

    /// Whether it has a place for every photo up to `largest`, the largest ID: names read before photos with
    /// larger IDs were indexed don't.
    public func reaches(_ largest: Int64) -> Bool {
        largest < Int64(names.count)
    }

    /// Runs `body` with the names by ID.
    func withUnsafeBufferPointer<T>(_ body: (UnsafeBufferPointer<String>) -> T) -> T {
        names.withUnsafeBufferPointer(body)
    }
}
