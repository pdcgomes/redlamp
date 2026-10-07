import Foundation
import Testing
@testable import RedlampLibrary

struct DuplicateBenchTests {
    @Test func `the duplicates scenario is added after the others, and found by name`() {
        BenchScenarios.registerDuplicates()
        BenchScenarios.registerDuplicates()
        #expect(BenchScenarios.all.map(\.name).filter { $0 == "duplicates" } == ["duplicates"])
        #expect(BenchScenarios.named("duplicates") is DuplicateScenario)
    }

    @Test func `grouping finds every copy among many photos in one pass, in 32 bytes a photo and a table`() {
        let photos = 100_000
        let library = SyntheticDuplicates(photos: photos, share: 0.01, seed: 7)
        let candidates = library.grouper().candidates()
        let expected = Set(Dictionary(grouping: 0 ..< photos) { library.original(of: $0) ?? $0 }.values
            .filter { $0.count > 1 }.map { Set($0.map { Int64($0 + 1) }) })
        #expect(Set(candidates.groups.map { Set($0.photos) }) == expected)
        #expect(candidates.copyCount == library.copies && candidates.groups.count == library.originals)
        #expect((800 ... 1200).contains(library.copies))
        #expect(candidates.photosGrouped == photos)
        #expect(MemoryLayout<DuplicateGrouper.Entry>.stride == 32)
        // The arrays' capacities count the blocks the allocator gives back, which under load can be ones freed
        // earlier and larger than asked for: the footprint is held to twice what grouping asks for.
        let table = 1 << (Int.bitWidth - (2 * photos).leadingZeroBitCount)
        let asked = photos * 32 + table * MemoryLayout<Int32>.stride + library.copies * 8
        let perPhoto = Double(candidates.memoryFootprint) / Double(photos)
        #expect(
            (asked ... 2 * asked).contains(candidates.memoryFootprint),
            "\(perPhoto) bytes a photo, asked for \(Double(asked) / Double(photos))",
        )
    }

    @Test func `it groups a synthetic library and confirms the fixture's copies, reading none of them twice`(
    ) async throws {
        let fixture = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 300, seed: 41, duplicateShare: 0.04))
            .write(to: fixture.url)
        let indexFolder = try TemporaryFolder()
        for profile in [VolumeProfile.ssd, .nas] {
            let context = BenchContext(fixture: fixture.url, manifest: summary.manifest, profile: profile)
            let report = try await BenchReport.run(
                [DuplicateScenario(photos: 20000, indexFolder: indexFolder.url)], in: context,
            )
            let results = Dictionary(report.results.map { ($0.id, $0) }) { first, _ in first }
            // Counts are exact whatever the load; times are measured on a busy machine.
            let miscounted = report.failed.filter { $0.budget?.kind == .exactly }
            #expect(miscounted.isEmpty, "\(report.text)")
            for id in ["library-duplicates-copies", "library-duplicates-group-copies", "library-duplicates-reread"] {
                #expect(results[id]?.passed == true, "\(id)")
            }
            #expect(results["library-duplicates-copies"]?.value == Double(summary.manifest.totals.duplicates ?? -1))
            #expect(results["library-duplicates-group"]?.budget == .below(1000, "ms"))
            #expect((results["library-duplicates-confirm-rate"]?.value ?? 0) > 0)
            #expect((results["library-duplicates-group-memory"]?.value ?? 0) > 32)
        }
    }
}
