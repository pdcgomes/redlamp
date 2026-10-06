import Foundation

/// Photos' names by ID, which pairs are found from: the index's, or made up for the benchmarks.
public struct StackNames: Sendable {
    /// By ID; empty for none.
    private var names: ContiguousArray<String> = []

    public init() {}

    /// Every photo's name in `reader`'s index.
    public init(_ reader: some IndexQueries) throws {
        var names = StackNames()
        try reader.database.cached("SELECT id, name FROM photos ORDER BY id").forEachRow { row in
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

    /// Runs `body` with the names by ID.
    func withUnsafeBufferPointer<T>(_ body: (UnsafeBufferPointer<String>) -> T) -> T {
        names.withUnsafeBufferPointer(body)
    }
}
