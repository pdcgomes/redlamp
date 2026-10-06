import Foundation
import Testing
@testable import RedlampLibrary

/// `redlamp library groups`, which prints `LibraryGroupReport`'s lines or its JSON (LIB-41).
struct GroupReportTests {
    @Test func `the groups command prints each group, the moments without a pick and the summary`() async throws {
        let library = try await GroupIndexLibrary.make()
        defer { library.sandbox.remove() }
        let report = try await LibraryGroupReport.run(.all, by: .camera, index: library.index)
        let lines = report.lines()
        #expect(Array(lines.dropLast()) == [
            #"Canon EOS R5: 4 photos, 1 pick (camera:"Canon EOS R5" -camera:"Canon EOS R50")"#,
            #"Canon EOS R50: 3 photos, 1 pick (camera:"Canon EOS R50")"#,
            "No camera: 2 photos, no picks",
            "Moments without a pick: 3 of 5, 4 photos",
            "  14 June 2025, 23:59: 1 photo",
            "  16 June 2025, 18:00: 2 photos",
            "  No capture time: 1 photo",
            "Summary: 9 photos, 2 picks, over 3 days from 14 June 2025 to 16 June 2025, 1 without a capture time",
            "  Cameras: Canon EOS R5 (4), Canon EOS R50 (3), no camera (2)",
            "  Lenses: XF35mmF1.4 R (5), XF35mmF1.4 R WR (2), no lens (2)",
            "  Stacks: 1 raw and JPEG pair",
        ])
        #expect(lines.last?.hasPrefix(
            "3 groups by camera of 9 photos for everything, sorted by captured; a moment at a pause over 60 s and 4 "
                + "times the pace around it (looseness 0); in ",
        ) == true, "\(lines.last ?? "")")

        let json = try #require(try JSONSerialization.jsonObject(with: report.json()) as? [String: Any])
        #expect(json["by"] as? String == "camera" && json["photos"] as? Int == 9 && json["query"] as? String == "")
        let groups = try #require(json["groups"] as? [[String: Any]])
        #expect(groups.map { $0["count"] as? Int } == [4, 3, 2] && groups.map { $0["picks"] as? Int } == [1, 1, 0])
        #expect(groups[1]["filter"] as? String == #"camera:"Canon EOS R50""# && groups[2]["filter"] == nil)
        #expect(groups[0]["first"] as? String == "2025-06-14T10:00:00" && groups[0]["last"] as? String ==
            "2025-06-16T18:00:00")
        let coverage = try #require(json["momentsWithoutPick"] as? [String: Any])
        #expect(coverage["moments"] as? Int == 5 && coverage["photos"] as? Int == 4)
        #expect((coverage["unpicked"] as? [[String: Any]])?.map { $0["name"] as? String } == [
            "14 June 2025, 23:59", "16 June 2025, 18:00", "No capture time",
        ])
        let summary = try #require(json["summary"] as? [String: Any])
        #expect(summary["firstDay"] as? String == "2025-06-14" && summary["days"] as? Int == 3)
        #expect(summary["stacks"] as? [String: Int] == ["pair": 1] && summary["iso"] == nil)
        let setting = try #require(json["setting"] as? [String: Any])
        #expect(setting["floorSeconds"] as? Double == 60 && setting["ceilingSeconds"] as? Double == 3600)
    }

    @Test func `the groups command groups a search's photos in its order, with the setting it's given`() async throws {
        let library = try await GroupIndexLibrary.make()
        defer { library.sandbox.remove() }
        let report = try await LibraryGroupReport.run(
            LibraryQuery(parsing: "camera:R5"), by: .day, setting: MomentSetting(looseness: 2),
            sort: QuerySort(.captured, ascending: false), index: library.index,
        )
        let lines = report.lines()
        #expect(Array(lines.prefix(3)) == [
            "16 June 2025: 1 photo, no picks (date:2025-06-16)",
            "15 June 2025: 3 photos, 1 pick (date:2025-06-15)",
            "14 June 2025: 3 photos, 1 pick (date:2025-06-14)",
        ])
        #expect(lines.last?.contains(
            "3 groups by day of 7 photos for camera:R5, sorted by captured, descending; a moment at a pause over "
                + "120 s and 5.7 times the pace around it (looseness 2); in ",
        ) == true, "\(lines.last ?? "")")
        #expect(report.groups.list.ids.first == report.groups[0].photos.first)
    }
}
