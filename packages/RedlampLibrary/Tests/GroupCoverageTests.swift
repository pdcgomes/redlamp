import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The moments without a pick (LIB-41), so a list can show only those.
struct GroupCoverageTests {
    @Test func `coverage counts the moments without a pick and lists their photos in the list's order`() {
        var library = GroupLibrary()
        let undated = library.add("SCAN.TIF", at: nil)
        var sessions: [[Int64]] = []
        let starts: [Double] = [9 * 3600, 9 * 3600 + 245, 13 * 3600, 17 * 3600]
        for (session, start) in starts.enumerated() {
            var ids: [Int64] = []
            for shot in 0 ..< 10 {
                let flag: PhotoFlag? = session == 0 && shot == 4 ? .pick : nil
                let time = GroupLibrary.june14 + start + Double(shot) * 5
                ids.append(library.add("S\(session)_\(shot).NEF", at: time, flag: flag))
            }
            sessions.append(ids)
        }
        let picked = library.add("S3_late.NEF", at: GroupLibrary.june14 + 17 * 3600 + 60, flag: .pick)
        library.choices.stack([sessions[2][3], picked], top: sessions[2][3], in: library.grouping().stacks)
        let grouping = library.grouping()
        let list = library.list
        let moments = grouping.moments(of: list)
        #expect(moments.map(\.picks) == [1, 0, 1, 0, 0])
        let coverage = grouping.coverage(of: list)
        #expect(coverage == MomentCoverage(moments))
        #expect(coverage.moments == 5 && coverage.unpicked == [1, 3, 4])
        #expect(Array(coverage.photos) == [undated] + sessions[1] + sessions[3])

        let loosest = grouping.coverage(of: list, setting: MomentSetting(looseness: MomentSetting.loosest))
        #expect(loosest.moments == 4 && loosest.unpicked == [2, 3])
        #expect(Array(loosest.photos) == [undated] + sessions[3])

        let newest = PhotoList(
            source: .allPhotographs, sort: QuerySort(.captured, ascending: false),
            ids: ContiguousArray(list.ids.reversed()),
        )
        let reversed = grouping.coverage(of: newest)
        #expect(reversed.unpicked == [0, 2, 4])
        #expect(Array(reversed.photos) == sessions[3].reversed() + sessions[1].reversed() + [undated])
    }

    @Test func `grouped by another key, coverage is of the groups without a pick`() {
        var library = GroupLibrary()
        let nikon = library.add("A.NEF", at: GroupLibrary.june14, camera: 1, flag: .pick)
        let fuji = library.add("B.RAF", at: GroupLibrary.june14 + 5, camera: 2)
        let grouping = library.grouping()
        let coverage = MomentCoverage(grouping.groups(of: library.list, by: .camera))
        #expect(coverage.moments == 2 && coverage.unpicked == [0] && Array(coverage.photos) == [fuji])
        #expect(!coverage.photos.contains(nikon))
        #expect(grouping.coverage(of: library.list).unpicked.isEmpty)
    }
}
