import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Capture times shifted, set and given a zone on many photos as one batch with Undo (LIB-22): each
/// photo's sidecar keeps the change, its file is never touched, and the index, its sorting, `date:`,
/// bursts and `{date}` follow.
struct CaptureTimeChangeTests {
    /// What indexing every folder again changed or read, after `step`; empty when nothing.
    private static func reread(after step: String, _ sandbox: KeywordSandbox) async -> [String] {
        let files = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing())
        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        guard let summary = run.summary else { return ["\(step): no summary"] }
        let counts = [
            ("inserted", summary.photosInserted), ("updated", summary.photosUpdated), ("read", files.counts.heads),
            ("removed", summary.photosRemoved), ("failed", summary.failures),
        ]
        return counts.filter { $0.1 != 0 }.map { "\(step): \($0.1) \($0.0)" } + run.failures
    }

    @Test func `a shift of many photos and its Undo move their capture times, sorting, date: and {date}`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("A.JPG", at: "2024:06:01 23:30:00", subsec: "25", offset: "+01:00")
        try sandbox.sidecar("A.JPG", PhotoMetadata(rating: 2))
        try sandbox.shot("B.JPG", at: "2024:06:02 00:10:00", offset: "+01:00")
        try sandbox.photo("C.JPG")
        try await sandbox.indexAll()
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let photos = try await sandbox.ids(["A.JPG", "C.JPG"])

        let plan = try await metadata.plan(.shift(photos, by: 3600))
        #expect(plan.title == "Shift the capture time of a photo by +1 h", "C.JPG has no capture time")
        #expect(plan.photos.map(\.path) == [sandbox.url("A.JPG").path])
        let row = try await sandbox.row("A.JPG")
        #expect(plan.photos.first?.capture(of: row).time == cameraClock("2024-06-02 00:30:00", plus: 0.25))
        let outcome = try await metadata.run(plan)
        #expect(outcome.photos == 1 && outcome.written == 1 && outcome.skipped.isEmpty)
        let sidecar = try #require(sandbox.sidecar("A.JPG"))
        #expect(sidecar.metadata == PhotoMetadata(rating: 2, captureShift: 3600))
        #expect(sidecar.recipe[.exposure] == 0.35 && sidecar.unknownFields["fromTheFuture"] == .string("kept"))
        #expect(sandbox.sidecar("C.JPG") == nil)
        #expect(try await sandbox.row("A.JPG").captured == cameraClock("2024-06-02 00:30:00", plus: 0.25))
        #expect(try await sandbox.inCaptureOrder("date:2024") == ["B.JPG", "A.JPG"])
        #expect(try await sandbox.search("date:2024-06-02") == ["A.JPG", "B.JPG"])
        #expect(try await sandbox.named("A.JPG", "{date:yyyyMMdd-HHmmss.SS}") == "20240602-003000.25")

        let undone = try await metadata.undo()
        #expect(undone.title == "Undo Shift the capture time of a photo by +1 h" && undone.written == 1)
        #expect(sandbox.sidecar("A.JPG")?.metadata == PhotoMetadata(rating: 2))
        let back = try await sandbox.row("A.JPG")
        #expect(back.captured == cameraClock("2024-06-01 23:30:00", plus: 0.25) && back.cameraCaptured == nil)
        #expect(try await sandbox.inCaptureOrder("date:2024") == ["A.JPG", "B.JPG"])
        #expect(try await sandbox.search("date:2024-06-01") == ["A.JPG"])
        #expect(try await sandbox.named("A.JPG", "{date:yyyyMMdd-HHmmss.SS}") == "20240601-233000.25")
    }

    @Test func `a camera left on home time is shifted across midnight into the zone it was in, and back`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        // Shot in Tokyo at 06:30 with the camera still on Lisbon's summer time.
        try sandbox.shot("Tokyo/A.JPG", at: "2024:06:01 22:30:00", offset: "+01:00")
        try sandbox.shot("Tokyo/B.JPG", at: "2024:06:01 22:45:00")
        try await sandbox.indexAll()
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let ids = try await sandbox.ids(["Tokyo/A.JPG", "Tokyo/B.JPG"])
        try await metadata.apply(.shift(ids, by: 8 * 3600))
        let zoned = try await metadata.apply(.zone(ids, offset: 9 * 3600))
        #expect(zoned.title == "Set the camera's zone of 2 photos to UTC+09:00" && zoned.written == 2)

        let a = try await sandbox.row("Tokyo/A.JPG")
        #expect(a.captured == cameraClock("2024-06-02 06:30:00") && a.capturedOffset == 32400)
        #expect(sandbox.sidecar("Tokyo/A.JPG")?.metadata == PhotoMetadata(captureShift: 28800, captureOffset: 32400))
        #expect(try await sandbox.search("date:2024-06-02") == ["A.JPG", "B.JPG"])
        // The same moment as before, in the zone the photos were taken in.
        #expect(try await sandbox.named("Tokyo/A.JPG", "{date:yyyyMMdd-HHmm}-{date:HHmm:utc}") == "20240602-0630-2130")
        #expect(try await sandbox.named("Tokyo/B.JPG", "{date:HHmm:+0900}") == "0645")

        let files = try await metadata.apply(.zone(ids, offset: nil))
        #expect(files.title == "Give 2 photos the zones their files record")
        #expect(try await sandbox.row("Tokyo/A.JPG").capturedOffset == 3600)
        #expect(try await sandbox.row("Tokyo/B.JPG").capturedOffset == nil)
        try await metadata.undo()
        #expect(try await sandbox.row("Tokyo/A.JPG").capturedOffset == 32400)
        try await metadata.undo()
        try await metadata.undo()
        let back = try await sandbox.row("Tokyo/A.JPG")
        #expect(back.captured == cameraClock("2024-06-01 22:30:00") && back.capturedOffset == 3600)
        #expect(back.cameraCaptured == nil && back.cameraOffset == nil)
        #expect(sandbox.sidecar("Tokyo/A.JPG") == nil, "the sidecars the batches made are gone")
        #expect(try await metadata.lastUndoable() == nil)
        await #expect(throws: CaptureTimeError.zoneOutOfRange(15 * 3600)) {
            try await metadata.plan(.zone(ids, offset: 15 * 3600))
        }
    }

    @Test func `setting one photo's time shifts the rest by the same amount, as Lightroom's Edit Capture Time does`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("A.JPG", at: "2024:06:01 08:30:00", subsec: "25")
        try sandbox.shot("B.JPG", at: "2024:06:01 08:31:10")
        try sandbox.shot("C.JPG", at: "2024:05:31 23:59:59")
        try sandbox.photo("D.JPG")
        try await sandbox.indexAll()
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let (a, others) = try await (sandbox.id("A.JPG"), sandbox.ids(["B.JPG", "C.JPG", "D.JPG"]))
        let outcome = try await metadata.apply(.set(a, to: cameraClock("2024-06-01 15:30:00"), shifting: others))
        #expect(outcome.title == "Set a capture time to 2024-06-01 15:30:00, shifting 3 photos by +7 h")
        #expect(outcome.photos == 3 && outcome.written == 3)
        #expect(try await sandbox.row("A.JPG").captured == cameraClock("2024-06-01 15:30:00", plus: 0.25))
        #expect(try await sandbox.row("B.JPG").captured == cameraClock("2024-06-01 15:31:10"))
        #expect(try await sandbox.row("C.JPG").captured == cameraClock("2024-06-01 06:59:59"))
        #expect(try await sandbox.row("D.JPG").captured == nil && sandbox.sidecar("D.JPG") == nil)
        for path in ["A.JPG", "B.JPG", "C.JPG"] {
            #expect(sandbox.sidecar(path)?.metadata?.captureShift == 25200, "\(path)")
        }

        try await metadata.undo()
        #expect(try await sandbox.row("C.JPG").captured == cameraClock("2024-05-31 23:59:59"))
        let d = try await sandbox.id("D.JPG")
        await #expect(throws: CaptureTimeError.noCaptureTime(d)) {
            try await metadata.plan(.set(d, to: cameraClock("2024-06-01 15:30:00"), shifting: [a]))
        }
    }

    @Test func `a burst split by a shift is found again once its frames are together`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        let names = (1 ... 4).map { "Burst/F\($0).JPG" }
        for (second, name) in names.enumerated() {
            try sandbox.shot(name, at: "2024:06:01 12:00:0\(second)")
        }
        try await sandbox.indexAll()
        let ids = try await sandbox.ids(names)
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        func bursts() async throws -> Set<Set<Int64>> {
            let engine = QueryEngine(index: sandbox.index)
            try await engine.load()
            return try await Set(StackFinder.find(in: sandbox.index, store: #require(engine.store)).photos(.burst)
                .map(Set.init))
        }
        let (first, last) = (Set(ids.prefix(2)), Set(ids.suffix(2)))
        #expect(try await bursts() == [Set(ids)])

        try await metadata.apply(.shift(Array(last), by: 3600))
        #expect(try await bursts() == [first, last])
        try await metadata.apply(.shift(Array(first), by: 3600))
        #expect(try await bursts() == [Set(ids)])
        #expect(try await sandbox.row(names[0]).captured == cameraClock("2024-06-01 13:00:00"))
        try await metadata.undo()
        #expect(try await bursts() == [first, last])
        try await metadata.undo()
        #expect(try await bursts() == [Set(ids)])
    }

    @Test func `the camera's own time is recovered after a shift, from the index and from the files alone`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("A.JPG", at: "2024:06:01 08:30:00", subsec: "5", offset: "-04:00")
        try await sandbox.indexAll()
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let id = try await sandbox.id("A.JPG")
        try await metadata.apply(.shift([id], by: -90))
        try await metadata.apply(.zone([id], offset: -18000))
        let shifted = try await sandbox.row("A.JPG")
        #expect(shifted.captured == cameraClock("2024-06-01 08:28:30", plus: 0.5) && shifted.capturedOffset == -18000)
        #expect(shifted.cameraTime == cameraClock("2024-06-01 08:30:00", plus: 0.5) && shifted.cameraZone == -14400)
        #expect(shifted.captureShift == -90)

        let rebuilt = try await LibraryIndex.open(at: sandbox.library.url.appending(path: "Rebuilt.sqlite"), readers: 1)
        defer { rebuilt.closeAndWait() }
        let run = await IndexerRun
            .collect(LibraryIndexer(index: rebuilt, configuration: .testing()).index([sandbox.root]))
        #expect(run.failures.isEmpty)
        let path = LibraryIndexer.path(sandbox.url("A.JPG"))
        let fromFiles = try #require(try await rebuilt.read { try $0.photo(path: path) })
        #expect(fromFiles.captured == shifted.captured && fromFiles.capturedOffset == shifted.capturedOffset)
        #expect(fromFiles.cameraTime == shifted.cameraTime && fromFiles.cameraZone == shifted.cameraZone)
    }

    @Test func `indexing the folders again after a shift, a zone and their Undo reads nothing`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        let names = (0 ..< 12).map { String(format: "Day %d/IMG_%04d.JPG", $0 / 6 + 1, $0) }
        for (number, name) in names.enumerated() {
            try sandbox.shot(name, at: String(format: "2024:06:01 10:%02d:00", number), offset: "+01:00")
            if number.isMultiple(of: 3) {
                try sandbox.sidecar(name, PhotoMetadata(rating: 3))
            }
        }
        try await sandbox.indexAll()
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let ids = try await sandbox.ids(names)
        try await metadata.apply(.shift(ids, by: 3600))
        var found = await Self.reread(after: "shift", sandbox)
        try await metadata.apply(.set(ids[0], to: cameraClock("2024-06-02 09:00:00"), shifting: Array(ids.dropFirst())))
        found += await Self.reread(after: "set", sandbox)
        try await metadata.apply(.zone(Array(ids.prefix(5)), offset: 7200))
        found += await Self.reread(after: "zone", sandbox)
        for step in ["zone", "set", "shift"] {
            try await metadata.undo()
            found += await Self.reread(after: "\(step)'s Undo", sandbox)
        }
        #expect(found.isEmpty, "\(found)")
        #expect(try await sandbox.row(names[4]).captured == cameraClock("2024-06-01 10:04:00"))
    }
}
