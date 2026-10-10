import Foundation

/// A moment among photos given by their capture times and names (LIB-41), as a card's are while
/// they're browsed before copying.
public struct CardMoment: Sendable, Hashable {
    /// The places of its photos among those given, in capture order: ties by name in the Finder's
    /// order, then by place.
    public let places: [Int]
    /// Its name in words, as a list's moments have theirs.
    public let name: String
    /// When its first and last photos were taken, by the camera's clock read as UTC; nil for the
    /// photos without a capture time.
    public let span: ClosedRange<Date>?
}

public extension MomentFinder {
    /// The moments among photos taken at `captured` and named `names`, one of each for every photo,
    /// found as a list's are, the photos without a capture time last as one more. The same photos give
    /// the same moments in whatever order they're given, and a card's photos the moments the library
    /// finds for them once they're imported, but for the stacks it finds then and never splits.
    static func moments(
        captured: [Date?], names: [String], setting: MomentSetting = MomentSetting(),
    ) -> [CardMoment] {
        precondition(captured.count == names.count, "every photo has a name")
        let times = captured.map { $0.map { ColumnEncoding.captured($0.timeIntervalSince1970) } ?? .min }
        func byName(_ places: some Sequence<Int>) -> [Int] {
            let keyed: [(place: Int, key: [UInt8])] = places.map { ($0, FinderOrder.key(names[$0])) }
            return keyed.sorted { lhs, rhs in
                guard lhs.key != rhs.key else { return lhs.place < rhs.place }
                return lhs.key.lexicographicallyPrecedes(rhs.key)
            }.map(\.place)
        }
        var dated = times.indices.filter { times[$0] != .min }
        dated.sort { (times[$0], $0) < (times[$1], $1) }
        var start = 0
        while start < dated.count {
            var end = start + 1
            while end < dated.count, times[dated[end]] == times[dated[start]] {
                end += 1
            }
            if end - start > 1 {
                dated.replaceSubrange(start ..< end, with: byName(dated[start ..< end]))
            }
            start = end
        }
        let ordered = ContiguousArray(dated.map { times[$0] })
        let starts = ordered.withUnsafeBufferPointer { Self.starts($0, setting: setting) }
        func date(_ milliseconds: Int64) -> Date {
            Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        var moments: [CardMoment] = []
        var first = 0
        for end in starts.map(Int.init) + [dated.count] where end > first {
            let (earliest, latest) = (ordered[first], ordered[end - 1])
            moments.append(CardMoment(
                places: Array(dated[first ..< end]), name: GroupNames.span(earliest, latest),
                span: date(earliest) ... date(latest),
            ))
            first = end
        }
        let undated = byName(times.indices.filter { times[$0] == .min })
        if !undated.isEmpty {
            moments.append(CardMoment(places: undated, name: LibraryGrouping.undated, span: nil))
        }
        return moments
    }
}

public extension ImportPhoto {
    /// `photos` in moments (LIB-41), found as the library finds its own, from their capture times as
    /// browsing has them (`captured`: their heads', or their files' dates until the heads are read)
    /// and their first files' names. Each moment's places are among `photos`.
    static func moments(of photos: [ImportPhoto], setting: MomentSetting = MomentSetting()) -> [CardMoment] {
        MomentFinder.moments(
            captured: photos.map { Optional($0.captured) }, names: photos.map(\.primary.name), setting: setting,
        )
    }
}
