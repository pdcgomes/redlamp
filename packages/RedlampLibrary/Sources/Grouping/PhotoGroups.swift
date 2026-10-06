import Foundation

/// What a list's photos are grouped by (LIB-41), as the grid's Group By offers it. Moments and days
/// come in the order they were taken, the newest first when the list is sorted by capture time from
/// the newest; folders, cameras and lenses by name, in the Finder's order, as facets order their
/// values; orientations landscape, portrait, square. The photos without the field come last.
public enum GroupKey: String, Sendable, Hashable, CaseIterable, Codable {
    /// One group of every photo.
    case ungrouped = "none"
    /// Photos taken together, as `MomentFinder` finds them.
    case moment
    /// The day a photo was taken, by the camera's clock, as `date:` counts days.
    case day
    case folder
    /// The camera's model: the index doesn't tell two bodies of one model apart.
    case camera
    case lens
    case orientation
    /// Moments, and each moment's photos by camera, so two bodies whose clocks disagree come apart
    /// within a moment.
    case momentCamera = "moment-camera"
}

/// What a group's photos share; nil for the photos without it.
public enum GroupValue: Sendable, Hashable {
    /// Every photo of the list.
    case all
    /// A moment, numbered from 0 in the order the list's moments were taken.
    case moment(Int?)
    case day(QueryDate?)
    /// The folder's path.
    case folder(String?)
    case camera(String?)
    case lens(String?)
    case orientation(PhotoOrientation?)
    /// A moment's photos from one camera, the moment numbered as `moment`'s are.
    case momentCamera(Int?, camera: String?)
}

/// One of a list's groups: its photos, and what its header shows.
public struct PhotoGroup: Sendable, Hashable {
    public let value: GroupValue
    /// Its name in words: `14 June 2025, 14:03 to 14:47`, `Nikon Z 6`, `No capture time`.
    public let name: String
    /// Its photos, in the list's order.
    public let photos: ArraySlice<Int64>
    /// How many of its photos are picks.
    public let picks: Int
    /// The query finding exactly its photos among the list's, where the language has one: a day's
    /// `date:`, and a folder's, camera's or lens's term as a facet's value gives it
    /// (`FacetValue.filter`), the other values among the list's it would also find left out. None
    /// for a group a stack joined photos of another value to, or took its photos from.
    public let filter: LibraryQuery?
    /// When its first and last photos were taken, by the camera's clock read as UTC as the index keeps
    /// capture times; nil when none of them has a capture time.
    public let span: ClosedRange<Date>?

    public var count: Int {
        photos.count
    }
}

/// A list's photos in groups (LIB-41), as `LibraryGrouping` makes them: the groups in their key's
/// order, each with its photos in the list's. A stack the list has two or more photos of is never
/// split: its photos go where the photo standing for it while it's closed goes.
public struct PhotoGroups: Sendable, RandomAccessCollection {
    public let key: GroupKey
    public let setting: MomentSetting
    public let list: PhotoList
    /// Every group's photos, one group after another: the list's photos as a grid grouped by `key`
    /// shows them.
    public let photos: ContiguousArray<Int64>
    /// Group `index`'s photos are from `starts[index]` up to `starts[index + 1]`.
    let starts: ContiguousArray<Int32>
    let details: [Detail]
    /// The group of each of the list's photos, by its place in the list.
    let groupOfPlace: ContiguousArray<Int32>

    struct Detail: Sendable, Hashable {
        var value: GroupValue
        var name: String
        var picks: Int
        var filter: LibraryQuery?
        /// Milliseconds, as the column store keeps capture times.
        var span: ClosedRange<Int64>?
    }

    public var startIndex: Int {
        0
    }

    public var endIndex: Int {
        details.count
    }

    public subscript(position: Int) -> PhotoGroup {
        let detail = details[position]
        return PhotoGroup(
            value: detail.value, name: detail.name, photos: photos[Int(starts[position]) ..< Int(starts[position + 1])],
            picks: detail.picks, filter: detail.filter, span: detail.span.map { span in
                Date(timeIntervalSince1970: Double(span.lowerBound) / 1000)
                    ... Date(timeIntervalSince1970: Double(span.upperBound) / 1000)
            },
        )
    }

    /// The group holding photo `id`; nil for a photo the list doesn't have.
    public func index(of id: Int64) -> Int? {
        list.index(of: id).map { Int(groupOfPlace[$0]) }
    }
}
