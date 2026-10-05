import Foundation
import Testing
@testable import RedlampLibrary

/// What `redlamp library xmp` prints, the report's lines or its JSON, on a small fixture.
struct XMPReportTests {
    @Test func `on a small fixture it shows each photo's .xmp against its .redlamp, and writes only when asked`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 300, seed: 11))
        defer { sandbox.remove() }
        let run = await IndexerRun.collect(
            LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]),
        )
        #expect(run.failures.isEmpty)
        let ids = try await sandbox.index.read { reader in
            var ids: [Int64] = []
            try reader.scanHotColumns { ids.append($0.id) }
            return ids
        }
        let photos = (0 ..< sandbox.manifest.spec.photos).map(sandbox.fixture.photo(at:))
        let totals = sandbox.manifest.totals
        let files = try FixtureTests.files(in: sandbox.root)
        let xmp = LibraryXMP(index: sandbox.index)

        let dry = try await xmp.sync(ids, dryRun: true)
        #expect(dry.photos.count { $0.sidecar != nil } == totals.xmpSidecars)
        #expect(dry.photos.count { $0.redlamp != nil } == totals.sidecars)
        let lines = dry.lines
        #expect(lines.contains(
            "300 photos: \(totals.xmpSidecars) with other apps' .xmp, \(totals.sidecars) with a .redlamp",
        ))
        for photo in photos {
            guard let other = photo.xmp else { continue }
            let line = try #require(lines.first { $0.hasPrefix(sandbox.url(photo).path + ":") })
            let fields = XMPFields(
                rating: other.rating > 0 ? other.rating : nil,
                label: other.label,
                keywords: other.keywords,
            )
            #expect(line.contains(".xmp \(photo.xmpName): \(XMPReport.describe(fields))"), "\(line)")
            #expect(line.hasSuffix("no .redlamp: as other apps have it"))
        }
        #expect(lines.contains("Writing .xmp is off: \(dry.photos.count { !$0.unwritten.isEmpty }) photos with values "
                + "their .xmp doesn't hold (--write writes them)"))
        #expect(lines.last == "A dry run: nothing was written.")
        let json = try #require(try JSONSerialization.jsonObject(with: dry.json()) as? [String: Any])
        #expect(json["tool"] as? String == "redlamp library xmp" && json["dryRun"] as? Bool == true)
        #expect((json["photos"] as? [[String: Any]])?.count == dry.photos.count)
        #expect(try FixtureTests.files(in: sandbox.root) == files)

        // Written: an .xmp beside each photo whose .redlamp holds a rating, flag or label; other apps'
        // stay as they are.
        let others = try photos.compactMap { photo -> (URL, Data)? in
            guard photo.xmp != nil else { return nil }
            let url = sandbox.root.appending(path: photo.folder).appending(path: photo.xmpName)
            return try (url, Data(contentsOf: url))
        }
        let written = try await xmp.sync(ids, writing: true)
        let holding = photos.filter { photo in
            guard let sidecar = photo.sidecar else { return false }
            return sidecar.rating > 0 || sidecar.flag != nil || sidecar.label != nil
        }
        #expect(written.xmpWritten.count == holding.count && !holding.isEmpty)
        #expect(written.lines.contains("\(holding.count) .xmp files written: \(holding.count) new, 0 rewritten keeping "
                + "other apps' fields"))
        for (url, data) in others {
            #expect(try Data(contentsOf: url) == data)
        }
        let again = try await xmp.sync(ids, writing: true)
        #expect(again.photos.filter { $0.redlamp != nil }.allSatisfy(\.unchanged) && again.xmpWritten.isEmpty)
    }
}
