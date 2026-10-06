import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// A source's summary (LIB-41): its days, cameras, lenses, setting ranges, pairs and stacks.
struct SourceSummaryTests {
    @Test func `the summary gives the source's days, cameras, lenses, ranges, pairs and stacks`() throws {
        var library = GroupLibrary()
        let day = GroupLibrary.june14
        let pair = [
            library.add("PAIR_1.CR3", at: day + 10 * 3600, flag: .pick, iso: 100, aperture: 1.4, shutter: 1.0 / 8000),
            library.add("PAIR_1.JPG", at: day + 10 * 3600, iso: 100, aperture: 1.4, shutter: 1.0 / 8000),
        ]
        let burst = (0 ..< 3).map { frame in
            library.add(
                "BURST_\(frame).NEF", at: day + 11 * 3600 + Double(frame) / 5, lens: 2, iso: 800 * Double(1 << frame),
                shutter: 1.0 / 1000,
            )
        }
        let focus = (0 ..< 4).map { frame in
            library.add(
                "FOCUS_\(frame).RAF", at: day + 86400 + 9 * 3600 + Double(frame) * 2, camera: 2, iso: 200,
                aperture: 8,
            )
        }
        let long = library.add(
            "LONG_1.RAF",
            at: day + 2 * 86400 + 22 * 3600,
            camera: 2,
            lens: nil,
            iso: 6400,
            aperture: 16,
            shutter: 2,
        )
        let scan = library.add("SCAN_1.TIF", at: nil, camera: nil, lens: nil, iso: nil, aperture: nil, shutter: nil)
        library.choices.stack([long, scan], in: library.grouping().stacks)
        let grouping = library.grouping()

        let summary = try grouping.summary(of: library.list)
        #expect(summary.photos == 11 && summary.picks == 1)
        #expect(summary.firstDay == .day(2025, 6, 14) && summary.lastDay == .day(2025, 6, 16) && summary.days == 3)
        #expect(summary.undated == 1)
        #expect(summary.cameras.map(\.name) == ["Fujifilm X-T5", "Nikon Z 6", nil])
        #expect(summary.cameras.map(\.count) == [5, 5, 1])
        #expect(summary.cameras.first?.filter?.description == #"camera:"Fujifilm X-T5""#)
        #expect(summary.lenses.map(\.name) == ["NIKKOR Z 24-70mm f/4 S", "XF35mmF1.4 R", nil])
        #expect(summary.lenses.map(\.count) == [6, 3, 2])
        #expect(summary.iso == 100 ... 6400 && summary.aperture == 1.4 ... 16)
        #expect(summary.shutter == 1.0 / 8000 ... 2)
        #expect(summary.stacks == [.pair: 1, .burst: 1, .focus: 1, .manual: 1])

        let some = PhotoList(source: .allPhotographs, ids: [pair[1], burst[0], focus[0], focus[1], 999])
        let part = try grouping.summary(of: some)
        #expect(part.photos == 5 && part.picks == 0 && part.undated == 1 && part.days == 2)
        #expect(part.stacks == [.focus: 1])
        #expect(part.iso == 100 ... 800 && part.aperture == 1.4 ... 8 && part.shutter == 1.0 / 8000 ... 1.0 / 250)

        let none = try grouping.summary(of: PhotoList(source: .allPhotographs, ids: [scan]))
        #expect(none.firstDay == nil && none.days == 0 && none.undated == 1 && none.iso == nil && none.stacks.isEmpty)
        #expect(none.cameras == [FacetValue(name: nil, count: 1, filter: nil)])
    }
}
