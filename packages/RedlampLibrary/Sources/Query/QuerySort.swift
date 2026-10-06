import Foundation

/// The order a search's photos come in. Sorting is separate from the query.
public struct QuerySort: Sendable, Hashable {
    public enum Key: String, Sendable, Hashable, CaseIterable {
        /// When it was taken, then its ID; photos without a capture time first.
        case captured
        /// Its name, in the Finder's order, then its ID.
        case name
        /// Its rating, then when it was taken.
        case rating
        /// When its edit was last saved, then when it was taken; photos without an edit first.
        case edited
        /// When its file was last modified, then when it was taken.
        case modified
        /// Its file's size, then when it was taken.
        case size
    }

    public var key: Key
    public var ascending: Bool

    public init(_ key: Key = .captured, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}
