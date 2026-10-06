import Foundation

/// The moments of a list without a pick (LIB-41): how many there are, of how many, and their photos,
/// so a list can show only those and a moment shot once isn't lost in the cull. The photos without
/// a capture time count as one more moment.
public struct MomentCoverage: Sendable, Hashable {
    /// The list's moments.
    public let moments: Int
    /// The moments without a pick, by their places among the list's moments.
    public let unpicked: [Int]
    /// Their photos, in the list's order.
    public let photos: ContiguousArray<Int64>

    /// The coverage of `moments`, a list's moments as `LibraryGrouping` finds them; grouped by another
    /// key, the groups without a pick.
    public init(_ moments: PhotoGroups) {
        let unpicked = moments.indices.filter { moments.details[$0].picks == 0 }
        var without = [Bool](repeating: false, count: moments.count)
        for moment in unpicked {
            without[moment] = true
        }
        var photos = ContiguousArray<Int64>()
        for (place, id) in moments.list.ids.enumerated() where without[Int(moments.groupOfPlace[place])] {
            photos.append(id)
        }
        self.moments = moments.count
        self.unpicked = unpicked
        self.photos = photos
    }
}

public extension LibraryGrouping {
    /// The moments of `list` without a pick, its moments as `setting` finds them.
    func coverage(of list: PhotoList, setting: MomentSetting = MomentSetting()) -> MomentCoverage {
        MomentCoverage(moments(of: list, setting: setting))
    }
}
