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
    /// `date:`; a moment's capture times to the second (`date:2025-06-14T14:03:12..2025-06-14T14:47:05`),
    /// and with its camera's term for a moment's photos from one camera; an orientation's
    /// `orientation:`; and a folder's, camera's or lens's term as a facet's value gives it
    /// (`FacetValue.filter`), the other values among the list's it would also find left out. None
    /// for a group a stack joined photos of another value to, or took its photos from, nor for the
    /// photos without a capture time, a folder, a camera or a lens.
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
    /// The terms a folder's, camera's or lens's filter is made of, the other values the list has left out.
    let filters: GroupFilters?

    /// What a group shows, and what its name and filter are made of: they're made as they're asked for, as making
    /// one takes longer than grouping its photos, and a grid shows a screenful of thousands of moments.
    struct Detail: Sendable, Hashable {
        var value: GroupValue
        var picks: Int
        /// Milliseconds, as the column store keeps capture times.
        var span: ClosedRange<Int64>?
        /// A stack joined photos of another value to the group, or took its photos from it: no filter finds them.
        var crossed = false
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
            value: detail.value, name: name(of: detail), photos: photos(ofGroup: position), picks: detail.picks,
            filter: filter(of: detail), span: detail.span.map { span in
                Date(timeIntervalSince1970: Double(span.lowerBound) / 1000)
                    ... Date(timeIntervalSince1970: Double(span.upperBound) / 1000)
            },
        )
    }

    /// The group holding photo `id`; nil for a photo the list doesn't have.
    public func index(of id: Int64) -> Int? {
        list.index(of: id).map { Int(groupOfPlace[$0]) }
    }

    /// Group `index`'s photos alone, as `self[index].photos`, for a pass over every group: a group made whole
    /// makes its name, filter and span too, a millisecond for 2,000 groups.
    public func photos(ofGroup index: Int) -> ArraySlice<Int64> {
        photos[Int(starts[index]) ..< Int(starts[index + 1])]
    }

    /// Group `index`'s value alone, as `self[index].value`.
    public func value(ofGroup index: Int) -> GroupValue {
        details[index].value
    }

    /// Group `index`'s name alone, as `self[index].name`.
    public func name(ofGroup index: Int) -> String {
        name(of: details[index])
    }

    /// How many photos group `index` has, as `self[index].count`.
    public func count(ofGroup index: Int) -> Int {
        Int(starts[index + 1] - starts[index])
    }

    /// Group `index`'s picks alone, as `self[index].picks`.
    public func picks(ofGroup index: Int) -> Int {
        details[index].picks
    }

    /// Whether group `index`'s name is group `other`'s of `groups`, the names made only where what they're made of
    /// differs.
    public func name(ofGroup index: Int, matches other: Int, in groups: PhotoGroups) -> Bool {
        let (mine, theirs) = (details[index], groups.details[other])
        guard key == groups.key, mine.value == theirs.value, mine.span == theirs.span else {
            return name(of: mine) == groups.name(of: theirs)
        }
        return true
    }

    /// These groups over `list`, which holds the same photos in the same places under a view's own IDs,
    /// as the app numbers the photos it lists so a selection outlives a filter: each photo keeps its
    /// group, and the groups their names, picks and filters.
    public func relabelled(as list: PhotoList) -> PhotoGroups {
        precondition(list.count == self.list.count, "the lists hold the same photos")
        var relabelled = ContiguousArray<Int64>(repeating: 0, count: photos.count)
        relabelled.withUnsafeMutableBufferPointer { relabelled in
            for (index, id) in photos.enumerated() {
                if let place = self.list.index(of: id) {
                    relabelled[index] = list.ids[place]
                }
            }
        }
        return PhotoGroups(
            key: key, setting: setting, list: list, photos: relabelled, starts: starts, details: details,
            groupOfPlace: groupOfPlace, filters: filters,
        )
    }

    /// A group's name, from what it shares and when its photos were taken.
    func name(of detail: Detail) -> String {
        switch detail.value {
        case .all: "All photos"
        case .moment(nil), .day(nil): LibraryGrouping.undated
        case .moment: LibraryGrouping.name(of: detail.span)
        case let .day(day?): GroupNames.day(day)
        case let .folder(name): name ?? "No folder"
        case let .camera(name): name ?? "No camera"
        case let .lens(name): name ?? "No lens"
        case let .orientation(orientation): orientation?.rawValue.capitalized ?? "No orientation"
        case let .momentCamera(moment, camera):
            (moment == nil ? LibraryGrouping.undated : LibraryGrouping.name(of: detail.span)) + " — "
                + (camera ?? "No camera")
        }
    }

    /// The query finding exactly a group's photos among the list's, as `PhotoGroup.filter` describes it.
    func filter(of detail: Detail) -> LibraryQuery? {
        guard !detail.crossed else { return nil }
        switch detail.value {
        case .all, .moment(nil), .day(nil), .folder(nil), .camera(nil), .lens(nil), .momentCamera(nil, _):
            return nil
        case .moment:
            return detail.span.flatMap(LibraryGrouping.filter(spanning:))
        case let .day(day?):
            return .filter(LibraryQuery.Filter(.date, .equal, [.date(day)]))
        case let .folder(name?), let .camera(name?), let .lens(name?):
            return filters?.filter(for: name)
        case let .orientation(orientation):
            return .filter(LibraryQuery.Filter(.orientation, .equal, [.orientation(orientation)]))
        case let .momentCamera(_, camera):
            guard let camera, let times = detail.span.flatMap(LibraryGrouping.filter(spanning:)),
                  let byCamera = filters?.filter(for: camera)
            else { return nil }
            return .joined([times, byCamera], or: false)
        }
    }
}
