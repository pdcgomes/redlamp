import Foundation
import Testing
@testable import RedlampLibrary

struct QueryBenchTests {
    @Test func `the query scenarios are added after the others, and found by name`() {
        BenchScenarios.registerQueries()
        BenchScenarios.registerQueries()
        let names = BenchScenarios.all.map(\.name)
        #expect(names.filter { $0 == "search" || $0 == "facets" } == ["search", "facets"])
        #expect(BenchScenarios.named("search") is SearchScenario)
        #expect(BenchScenarios.named("facets") is FacetScenario)
    }

    @Test func `search and facets search the index they're given, and find the manifest's counts`() async throws {
        let fixture = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 300, seed: 61)).write(to: fixture.url)
        let indexFolder = try TemporaryFolder()
        try await IndexingScenario.build([fixture.url], at: indexFolder.url.appending(path: "Index.sqlite"))
        let context = BenchContext(fixture: fixture.url, manifest: summary.manifest, profile: .ssd)
        let report = try await BenchReport.run(
            [SearchScenario(indexFolder: indexFolder.url), FacetScenario(indexFolder: indexFolder.url)], in: context,
        )
        // Counts are exact whatever the load; times are measured on a busy machine.
        let miscounted = report.failed.filter { $0.budget?.kind == .exactly }
        #expect(miscounted.isEmpty, "\(report.text)")
        let counts = report.results.filter { $0.id.hasPrefix("library-search-count-") }
        #expect(counts.count == FixtureQuery.corpus.count && counts.allSatisfy { $0.passed == true })
        let results = Dictionary(report.results.map { ($0.id, $0) }) { first, _ in first }
        #expect(results["library-search-first"]?.budget == .below(16, "ms"))
        #expect(results["library-facets"]?.budget == .below(100, "ms"))
        #expect((results["library-search-memory"]?.value ?? 0) > 0)
        #expect(results["library-facets-miscounted"]?.value == 0)
        let index = try await LibraryIndex.open(at: indexFolder.url.appending(path: "Index.sqlite"))
        defer { index.closeAndWait() }
        #expect(try await index.read { try $0.photoCount() } == summary.manifest.totals.photos)
    }

    @Test func `the search bench refuses to index a fixture, and says there's no index of it`() async throws {
        let fixture = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 60, seed: 62)).write(to: fixture.url)
        let context = BenchContext(fixture: fixture.url, manifest: summary.manifest, profile: .ssd)
        let empty = try TemporaryFolder()
        let url = empty.url.appending(path: "Index.sqlite")
        await #expect {
            _ = try await SearchScenario(indexFolder: empty.url).run(context)
        } throws: { error in
            let text = String(describing: error)
            return text.contains("no index of the fixture at \(url.path)")
                && text.contains("redlamp library index \(fixture.url.path) --index \(url.path)")
        }
        #expect(!FileManager.default.fileExists(atPath: url.path), "it makes no index")

        let other = try TemporaryFolder()
        let written = try await LibraryIndex.open(at: other.url.appending(path: "Index.sqlite"))
        try await written.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "OTHER", name: "Other", kind: .ssd))
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Other"))
            let folder = try writer.upsertFolder(FolderRecord(root: root, parent: nil, path: "/Volumes/Other/2024"))
            try writer.upsertPhotos([PhotoRecord(folder: folder, name: "A.JPG")])
        }
        await written.close()
        await #expect {
            _ = try await FacetScenario(indexFolder: other.url).run(context)
        } throws: { error in
            String(describing: error).contains("holds 1 photos, not the fixture's \(summary.manifest.totals.photos)")
        }
        let index = try await LibraryIndex.open(at: other.url.appending(path: "Index.sqlite"))
        defer { index.closeAndWait() }
        #expect(try await index.read { try $0.photoCount() } == 1, "nothing indexed into it")
    }

    @Test func `the index is kept in the temporary folder, under the fixture's name, size, seed and path`() {
        let manifest = FixtureManifest(
            spec: .init(photos: 20000, seed: 1), rawSources: [], totals: .init(), folders: [], queries: [],
        )
        let here = BenchContext(
            fixture: URL(fileURLWithPath: "/Volumes/SSD/lib-20k"),
            manifest: manifest,
            profile: .ssd,
        )
        let there = BenchContext(fixture: URL(fileURLWithPath: "/tmp/lib-20k"), manifest: manifest, profile: .nas)
        let folder = QueryScenario.indexFolder(for: here)
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
        #expect(folder.path.hasPrefix(URL(fileURLWithPath: temporary).path))
        #expect(folder.lastPathComponent.hasPrefix("lib-20k-20000-1-"))
        #expect(folder != QueryScenario.indexFolder(for: there))
        #expect(folder == QueryScenario.indexFolder(for: BenchContext(
            fixture: here.fixture, manifest: manifest, profile: .wifi,
        )))
    }
}
