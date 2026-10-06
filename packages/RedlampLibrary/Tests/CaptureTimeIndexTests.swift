import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// A capture time as the index shows it once a photo's sidecar shifts it and gives the camera a zone
/// (LIB-22): the camera's time with the shift added, in the sidecar's zone, with the camera's own kept,
/// and a sidecar changed since shown without reading the photo again.
struct CaptureTimeIndexTests {
    @Test func `the index shows the camera's time with its sidecar's shift, in its zone, and keeps the camera's`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("Day/A.JPG", at: "2024:06:01 08:30:00", subsec: "25", offset: "+01:00")
        try sandbox.sidecar("Day/A.JPG", PhotoMetadata(captureShift: 3600, captureOffset: 7200))
        try sandbox.shot("Day/B.JPG", at: "2024:06:01 10:00:00")
        try await sandbox.indexAll()

        let shifted = try await sandbox.row("Day/A.JPG")
        #expect(shifted.captured == cameraClock("2024-06-01 09:30:00", plus: 0.25) && shifted.capturedOffset == 7200)
        #expect(shifted.cameraTime == cameraClock("2024-06-01 08:30:00", plus: 0.25) && shifted.cameraZone == 3600)
        #expect(shifted.captureShift == 3600)
        let camera = try await sandbox.row("Day/B.JPG")
        #expect(camera.captured == cameraClock("2024-06-01 10:00:00") && camera.capturedOffset == nil)
        #expect(camera.cameraCaptured == nil && camera.cameraOffset == nil && camera.captureShift == 0)
        #expect(camera.cameraTime == camera.captured && camera.cameraZone == nil)
    }

    @Test func `a shift or zone changed in the sidecar since is shown without reading the photo again`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        let photo = try sandbox.shot("A.JPG", at: "2024:06:01 08:30:00", subsec: "5", offset: "+01:00")
        try sandbox.sidecar("A.JPG", PhotoMetadata(captureShift: 3600, captureOffset: 7200))
        let files = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing())
        _ = await IndexerRun.collect(indexer.index([sandbox.root]))
        #expect(files.counts.heads == 1)

        for (shift, zone) in [(-1800, nil), (0, -18000), (0, nil)] as [(Int, Int?)] {
            try sandbox.sidecar("A.JPG", PhotoMetadata(captureShift: shift, captureOffset: zone))
            files.reset()
            let run = await IndexerRun.collect(indexer.index([sandbox.root]))
            let change = "a shift of \(shift) and the zone \(zone.map(String.init) ?? "the file's")"
            #expect(run.summary?.photosUpdated == 1, "\(change)")
            #expect(files.counts.reads[LibraryIndexer.path(photo)] == nil, "\(change)")
            let row = try await sandbox.row("A.JPG")
            #expect(row.captured == cameraClock("2024-06-01 08:30:00", plus: 0.5 + Double(shift)), "\(change)")
            #expect(row.capturedOffset == zone ?? 3600, "\(change)")
            #expect(row.cameraTime == cameraClock("2024-06-01 08:30:00", plus: 0.5) && row.cameraZone == 3600)
        }
        let row = try await sandbox.row("A.JPG")
        #expect(row.cameraCaptured == nil && row.cameraOffset == nil)
    }

    @Test func `sorting, date: and {date} follow a shift across midnight, and {date}'s zones the sidecar's`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("A.JPG", at: "2024:06:01 23:30:00", offset: "+01:00")
        try sandbox.shot("B.JPG", at: "2024:06:02 00:10:00", offset: "+01:00")
        try await sandbox.indexAll()
        #expect(try await sandbox.inCaptureOrder() == ["A.JPG", "B.JPG"])
        #expect(try await sandbox.search("date:2024-06-01") == ["A.JPG"])
        #expect(try await sandbox.named("A.JPG", "{date:yyyyMMdd-HHmm}-{date:HHmm:utc}") == "20240601-2330-2230")

        try sandbox.sidecar("A.JPG", PhotoMetadata(captureShift: 3600, captureOffset: -18000))
        try await sandbox.indexAll()
        #expect(try await sandbox.inCaptureOrder() == ["B.JPG", "A.JPG"])
        #expect(try await sandbox.search("date:2024-06-01").isEmpty)
        #expect(try await sandbox.search("date:2024-06-02") == ["A.JPG", "B.JPG"])
        #expect(try await sandbox.named("A.JPG", "{date:yyyyMMdd-HHmm}-{date:HHmm:utc}") == "20240602-0030-0530")
    }

    @Test func `another app's shifted capture time is shown until the sidecar holds one, and date: and {date} follow it`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("A.JPG", at: "2024:06:01 23:30:00", offset: "+01:00")
        try XMPCaptureTimeTests.write(
            XMPCaptureTimeTests.xmp(dateTimeOriginal: "2024-06-02T00:30:00+01:00"), at: "A.xmp", in: sandbox,
            modified: -60,
        )
        try sandbox.shot("B.JPG", at: "2024:06:02 00:10:00", offset: "+01:00")
        try sandbox.shot("C.JPG", at: "2024:06:02 00:20:00", offset: "+01:00")
        try XMPCaptureTimeTests.write(
            XMPCaptureTimeTests.xmp(dateTimeOriginal: "2024:06:01 23:40:00.000"), at: "C.JPG.xmp", in: sandbox,
            modified: -60,
        )
        try await sandbox.indexAll()

        let shifted = try await sandbox.row("A.JPG")
        #expect(shifted.captured == cameraClock("2024-06-02 00:30:00") && shifted.capturedOffset == 3600)
        #expect(shifted.cameraTime == cameraClock("2024-06-01 23:30:00") && shifted.cameraZone == 3600)
        #expect(shifted.otherFields.contains(.captureTime))
        #expect(try await sandbox.row("C.JPG").captured == cameraClock("2024-06-01 23:40:00"), "darktable's")
        #expect(try await sandbox.inCaptureOrder() == ["C.JPG", "B.JPG", "A.JPG"])
        #expect(try await sandbox.search("date:2024-06-02") == ["A.JPG", "B.JPG"])
        #expect(try await sandbox.named("A.JPG", "{date:yyyyMMdd-HHmm}") == "20240602-0030")

        try sandbox.sidecar("A.JPG", PhotoMetadata(captureShift: -600))
        try await sandbox.indexAll()
        let own = try await sandbox.row("A.JPG")
        #expect(own.captured == cameraClock("2024-06-01 23:20:00") && !own.otherFields.contains(.captureTime))
        #expect(try await sandbox.inCaptureOrder() == ["A.JPG", "C.JPG", "B.JPG"])
        #expect(try await sandbox.search("date:2024-06-01") == ["A.JPG", "C.JPG"])

        try sandbox.sidecar("A.JPG", PhotoMetadata(rating: 2))
        try await sandbox.indexAll()
        let again = try await sandbox.row("A.JPG")
        #expect(again.captured == cameraClock("2024-06-02 00:30:00") && again.otherFields.contains(.captureTime))
        #expect(again.cameraTime == cameraClock("2024-06-01 23:30:00") && again.rating == 2)
    }

    @Test func `another app's capture time that is the camera's shifts nothing`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("A.JPG", at: "2024:06:01 23:30:00", offset: "+01:00")
        try XMPCaptureTimeTests.write(
            XMPCaptureTimeTests.xmp(dateTimeOriginal: "2024-06-01T23:30:00+01:00", rating: 3), at: "A.xmp",
            in: sandbox, modified: -60,
        )
        try await sandbox.indexAll()
        let row = try await sandbox.row("A.JPG")
        #expect(row.captured == cameraClock("2024-06-01 23:30:00") && row.cameraCaptured == nil)
        #expect(row.rating == 3 && !row.otherFields.contains(.captureTime))
    }

    @Test func `naming fields read from a photo's file take its sidecar's shift and zone`() {
        let metadata = CaptureMetadata(captured: cameraClock("2024-06-01 23:30:00", plus: 0.25), capturedOffset: 3600)
        var fields = NamingFields(name: "A.JPG", folder: "/Photos", metadata: metadata)
        fields.apply(PhotoMetadata(captureShift: 3600, captureOffset: -18000))
        #expect(fields.captured == cameraClock("2024-06-02 00:30:00", plus: 0.25) && fields.capturedOffset == -18000)
        var unzoned = NamingFields(name: "B.JPG", folder: "/Photos", metadata: metadata)
        unzoned.apply(PhotoMetadata(captureShift: -60))
        #expect(unzoned.captured == cameraClock("2024-06-01 23:29:00", plus: 0.25) && unzoned.capturedOffset == 3600)
    }
}
