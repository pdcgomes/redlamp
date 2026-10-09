import Foundation
import RedlampDocument

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

/// The photos `is:unpicked-moment` finds moments among, and the setting it finds them with (LIB-41).
struct MomentScope: Sendable, Hashable {
    var source: PhotoSource
    var setting: MomentSetting

    /// The library's photos at the default setting: for the query a source is made of, such as a smart
    /// collection's, which no view's setting changes.
    static let library = MomentScope(source: .allPhotographs, setting: MomentSetting())
}

extension ColumnStore {
    /// The rows of `rows` in moments without a pick, as `MomentCoverage` has them for a list of their
    /// photos grouped without stacks: moments as `setting` finds them among the rows with a capture time,
    /// and those without one a moment of their own. A stack made by hand of photos taken at different
    /// times stays whole in the grid's moment of the photo standing for it, and is split here.
    func unpickedMoments(of rows: RowBits, setting: MomentSetting) -> RowBits {
        let total = rows.count
        var dated = ContiguousArray<Int32>()
        var times = ContiguousArray<Int64>()
        var undated = ContiguousArray<Int32>()
        dated.reserveCapacity(total)
        times.reserveCapacity(total)
        captured.withUnsafeBufferPointer { captured in
            if total >= count / 8 {
                byCaptured.withUnsafeBufferPointer { order in
                    for row in order where rows.contains(Int(row)) {
                        let time = captured[Int(row)]
                        if time == .min {
                            undated.append(row)
                        } else {
                            dated.append(row)
                            times.append(time)
                        }
                    }
                }
            } else {
                rows.forEach { row in
                    if captured[row] == .min {
                        undated.append(Int32(row))
                    } else {
                        dated.append(Int32(row))
                    }
                    return true
                }
                dated.sort { captured[Int($0)] < captured[Int($1)] }
                times.append(contentsOf: dated.lazy.map { captured[Int($0)] })
            }
        }
        let starts = times.withUnsafeBufferPointer { MomentFinder.starts($0, setting: setting) }
        var found = RowBits(rows: rowCount)
        let pick = UInt16(PhotoRecord.code(for: .pick))
        packed.withUnsafeBufferPointer { packed in
            func keep(_ moment: ArraySlice<Int32>) {
                guard !moment.isEmpty, !moment.contains(where: { Packed.flag(packed[Int($0)]) == pick }) else { return }
                for row in moment {
                    found.insert(Int(row))
                }
            }
            var first = 0
            for start in starts {
                keep(dated[first ..< Int(start)])
                first = Int(start)
            }
            keep(dated[first...])
            keep(undated[...])
        }
        return found
    }
}
