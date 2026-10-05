import Foundation
import Testing
@testable import RedlampLibrary

/// `redlamp library names`, which prints `NamingPreview`'s lines or its JSON, on a small fixture.
struct NamingPreviewTests {
    /// A volume whose folders can't be listed: an offline share.
    struct Unlistable: LibraryFileSystem {
        let base = LocalFileSystem()

        func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
            throw LibraryFileSystemError.unreachable(url)
        }

        func attributes(of url: URL) throws -> FileEntry {
            try base.attributes(of: url)
        }

        func read(_ url: URL, range: Range<Int>) throws -> Data {
            try base.read(url, range: range)
        }

        func volume(of url: URL) throws -> VolumeInfo {
            try base.volume(of: url)
        }
    }

    static func indexed(_ photos: Int, seed: UInt64) async throws -> IndexerSandbox {
        let sandbox = try await IndexerSandbox.make(.init(photos: photos, seed: seed))
        for await _ in LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]) {}
        return sandbox
    }

    @Test func `the names command lists each photo's name now and its new one, and renames nothing`() async throws {
        let sandbox = try await Self.indexed(40, seed: 5)
        defer { sandbox.remove() }
        let photos = (0 ..< 40).map { sandbox.fixture.photo(at: $0) }
        let byPath = Dictionary(uniqueKeysWithValues: photos.map { (sandbox.path($0.path), $0) })
        let first = try #require(photos.min { ($0.captured, $0.index) < ($1.captured, $1.index) })
        let day = NamingPresetTests.day(first.captured)
        try Data().write(to: sandbox.root.appending(path: first.folder + "/\(day)-001.txt"))

        let template = try NamingTemplate(parsing: "{date:yyyyMMdd}-{sequence:3:folder}")
        let preview = try await NamingPreview.make(template, index: sandbox.index)
        #expect(preview.entries.count == 40)
        var places: [String: Int] = [:]
        for entry in preview.entries {
            let photo = try #require(byPath[entry.path])
            places[photo.folder, default: 0] += 1
            let expected = "\(NamingPresetTests.day(photo.captured))-\(digits(places[photo.folder]!, 3))"
            let numbered = photo.path == first.path
            #expect(entry.result.base == (numbered ? expected + "-2" : expected), "\(entry.path)")
            #expect(entry.result
                .collision == (numbered ? NamingCollision(suffix: 2, holder: .file("\(day)-001.txt")) : nil))
            #expect(FileManager.default.fileExists(atPath: sandbox.url(photo).path))
        }

        let lines = preview.lines(limit: 3)
        #expect(lines.count == 4)
        let shown = preview.entries[0]
        #expect(lines[0].hasPrefix("\(shown.path) → \(shown.result.name)"))
        #expect(lines[3]
            .hasPrefix("40 photos for everything: 40 renamed, 0 unchanged, 1 numbered to tell them apart; named in "))
        #expect(lines[3].hasSuffix("ms. Nothing was renamed. The first 3 are shown."))
        let numberedLine = try #require(preview.lines().first { $0.hasPrefix(sandbox.path(first.path)) })
        #expect(numberedLine.hasSuffix("(numbered: \(day)-001.txt is in the folder)"))

        let json = try #require(try JSONSerialization.jsonObject(with: preview.json()) as? [String: Any])
        #expect(json["count"] as? Int == 40 && json["numbered"] as? Int == 1 && json["renamed"] as? Int == 40)
        let entries = try #require(json["photos"] as? [[String: Any]])
        #expect(entries.count == 40)
        let numbered = try #require(entries.first { $0["path"] as? String == sandbox.path(first.path) })
        let holder = try #require(numbered["numbered"] as? [String: Any])
        #expect(holder["holder"] as? String == "\(day)-001.txt" && holder["holderIsFile"] as? Bool == true)
        let limited = try #require(try JSONSerialization.jsonObject(with: preview.json(limit: 2)) as? [String: Any])
        #expect((limited["photos"] as? [Any])?.count == 2)
    }

    @Test func `a query picks the photos, and their empty tokens and the counters are reported`() async throws {
        let sandbox = try await Self.indexed(60, seed: 6)
        defer { sandbox.remove() }
        let query = try LibraryQuery(parsing: "rating>=3")
        let template = try NamingTemplate(parsing: "{counter:shoot:3}-{caption}")
        let preview = try await NamingPreview.make(
            template, query: query, index: sandbox.index, counters: NamingCounters(["shoot": 9]),
        )
        let expected = try #require(sandbox.manifest.count(of: "rating>=3"))
        #expect(preview.entries.count == expected && expected > 0)
        #expect(preview.entries.map { $0.result.base.prefix(3) } == (1 ... expected).map { digits(9 + $0, 3)[...] })
        let empty = preview.entries.count { $0.result.emptyTokens.contains(1) }
        #expect(preview.batch.emptyCounts == [0, empty])
        let summary = try #require(preview.lines().last)
        #expect(summary.contains("photos for rating>=3: "))
        #expect(empty == 0 || summary.contains("; empty: {caption} for \(empty);"))
        #expect(summary.hasSuffix("Counters after the job: shoot \(9 + expected)."))
    }

    @Test func `a folder that can't be listed takes the index's photos as the files in it`() async throws {
        let sandbox = try await Self.indexed(30, seed: 7)
        defer { sandbox.remove() }
        let photos = (0 ..< 30).map { sandbox.fixture.photo(at: $0) }
        let folder = try #require(Dictionary(grouping: photos, by: \.folder).values.first { $0.count >= 2 })
        let (moving, staying) = (folder[0], folder[1])
        try Data().write(to: sandbox.root.appending(path: moving.folder + "/Notes.txt"))
        let path = sandbox.path(moving.path)
        let id = try #require(try await sandbox.index.read { try $0.photo(path: path)?.id })

        for (fileSystem, listed) in [(LocalFileSystem() as any LibraryFileSystem, true), (Unlistable(), false)] {
            let (job, ids) = try await NamingJob.renaming([id], in: sandbox.index, fileSystem: fileSystem)
            #expect(ids == [id])
            let other = (staying.name as NSString).deletingPathExtension
            for (text, holder) in [(other, staying.name), ("Notes", "Notes.txt")] {
                let batch = try job.names(NamingTemplate(parsing: "{text}"), context: NamingContext(texts: ["": text]))
                let numbered = listed || holder == staying.name
                #expect(batch.results[0]
                    .collision == (numbered ? NamingCollision(suffix: 2, holder: .file(holder)) : nil))
            }
        }
    }
}
