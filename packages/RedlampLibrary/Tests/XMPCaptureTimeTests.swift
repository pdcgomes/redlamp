import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// A shifted capture time in the `.xmp` Redlamp writes for other apps, and another app's capture time
/// read as a shift (LIB-24, LIB-22): `exif:DateTimeOriginal` and `photoshop:DateCreated`, against the time
/// the photo's file records, which is never written.
struct XMPCaptureTimeTests {
    /// An `.xmp` as another app gives a photo a capture time, with a rating and a namespace of its own.
    static func xmp(dateTimeOriginal: String? = nil, dateCreated: String? = nil, rating: Int = 0) -> String {
        let dates = [("exif:DateTimeOriginal", dateTimeOriginal), ("photoshop:DateCreated", dateCreated)]
            .compactMap { name, value in value.map { "\n   \(name)=\"\($0)\"" } }.joined()
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:acme="http://example.com/acme/1.0/"
           xmp:Rating="\(rating)"\(dates)
           acme:Reviewed="yes"/>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }

    /// Writes `text` at `path`, modified `offset` seconds from now.
    static func write(
        _ text: String,
        at path: String,
        in sandbox: KeywordSandbox,
        modified offset: TimeInterval,
    ) throws {
        try Data(text.utf8).write(to: sandbox.url(path))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: sandbox.url(path).path,
        )
    }

    static func packet(_ path: String, in sandbox: KeywordSandbox) throws -> XMPPacket {
        try #require(XMPPacket(Data(contentsOf: sandbox.url(path))))
    }

    static func parsed(_ text: String) throws -> XMPPacket {
        try #require(XMPPacket(Data(text.utf8)))
    }

    // MARK: - Reading and writing a time

    @Test func `times are read as XMP, EXIF and darktable write them, and written as Adobe's apps do`() throws {
        let read = { (text: String) in XMPCaptureTime(text: text) }
        #expect(read("2024-06-01T10:00:00+01:00") == XMPCaptureTime(
            time: cameraClock("2024-06-01 10:00:00"),
            offset: 3600,
        ))
        #expect(read(" 2024-06-01T10:00:00.25Z ") == XMPCaptureTime(
            time: cameraClock("2024-06-01 10:00:00", plus: 0.25), offset: 0,
        ))
        #expect(read("2024:06:01 08:30:00.000") == XMPCaptureTime(time: cameraClock("2024-06-01 08:30:00")))
        #expect(read("2024-06-01T10:05") == XMPCaptureTime(time: cameraClock("2024-06-01 10:05:00")))
        #expect(read("2024-06-01T10:00:00-0330")?.offset == -(3 * 3600 + 30 * 60))
        for text in [
            "2024-06-01", "2024", "2024-13-01T10:00:00", "2024-06-01T25:00:00", "2024-06-01T10:00:00.2e5",
            "2024-06-01T10:00:00+1:00", "yesterday", "2024-06-01T10:00:00+19:00",
        ] {
            #expect(read(text) == nil, "\(text)")
        }

        #expect(XMPCaptureTime(time: cameraClock("2024-06-02 01:00:00", plus: 0.25), offset: 3600).text
            == "2024-06-02T01:00:00.25+01:00")
        #expect(XMPCaptureTime(time: cameraClock("2024-06-02 01:00:00", plus: 0.5), offset: -4 * 3600).text
            == "2024-06-02T01:00:00.5-04:00")
        #expect(XMPCaptureTime(time: cameraClock("1999-12-31 23:59:59")).text == "1999-12-31T23:59:59")
        let camera = XMPCaptureTime(time: cameraClock("2024-06-01 08:30:00", plus: 0.75), offset: 3600)
        #expect(try #require(read("2024-06-01T08:30:00")).shift(from: camera) == 0, "to the second, as EXIF is")
        #expect(try #require(read("2024-06-01T10:00:00.75+01:00")).shift(from: camera) == 5400)
    }

    @Test func `an xmp's capture time is its exif:DateTimeOriginal, else its photoshop:DateCreated with a time of day`(
    ) throws {
        #expect(try XMPCaptureTime(Self.parsed(Self.xmp(
            dateTimeOriginal: "2024-06-01T10:00:00+01:00", dateCreated: "2024-06-01T11:00:00+01:00",
        )))?.time == cameraClock("2024-06-01 10:00:00"))
        #expect(try XMPCaptureTime(Self.parsed(Self.xmp(dateCreated: "2024-06-01T11:00:00")))?.time
            == cameraClock("2024-06-01 11:00:00"))
        #expect(try XMPCaptureTime(Self.parsed(Self.xmp(dateCreated: "1965-06-12"))) == nil, "a date, as of a scan")
        #expect(try XMPCaptureTime(Self.parsed(Self.xmp())) == nil)
    }

    @Test func `a capture time other than the camera's is a shift and a zone, and the camera's own is none`() throws {
        let camera = XMPCaptureTime(time: cameraClock("2024-06-01 08:30:00"), offset: 3600)
        let other = try Self.parsed(Self.xmp(dateTimeOriginal: "2024-06-01T03:30:00-04:00"))
        let source = XMPSource(packet: other, conventions: XMPConventions())
        #expect(!source.present.contains(.captureTime), "read only against the camera's time")
        let read = source.capturing(XMPCaptureTime(other), camera: camera)
        #expect(read.present.contains(.captureTime))
        #expect(read.fields.captureShift == -5 * 3600 && read.fields.captureOffset == -4 * 3600)
        let own = try Self.parsed(Self.xmp(dateTimeOriginal: "2024-06-01T08:30:00+01:00"))
        let unshifted = XMPSource(packet: own, conventions: XMPConventions())
            .capturing(XMPCaptureTime(own), camera: camera)
        #expect(unshifted.present.contains(.captureTime) && !unshifted.fields.holds(.captureTime))
        #expect(source.capturing(XMPCaptureTime(other), camera: nil) == source)
    }

    // MARK: - The .xmp Redlamp writes

    @Test func `a shifted capture time goes into the xmp Redlamp writes, and the camera's comes back when it's undone`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("IMG_0001.JPG", at: "2024:06:01 23:30:00", subsec: "25", offset: "+01:00")
        try sandbox.sidecar("IMG_0001.JPG", PhotoMetadata(rating: 3))
        try await sandbox.indexAll()
        let xmp = LibraryXMP(index: sandbox.index, paths: sandbox.paths)
        try await xmp.setSettings(XMPSettings(writes: true))
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let id = try await sandbox.id("IMG_0001.JPG")
        _ = try await xmp.sync([id])
        #expect(try Self.packet("IMG_0001.xmp", in: sandbox).text(XMPNamespace.dateTimeOriginal) == nil, "unshifted")

        try await metadata.apply(.shift([id], by: 5400))
        var report = try await xmp.sync([id])
        #expect(report.photo("IMG_0001.JPG")?.written == [.captureTime])
        #expect(report.photo("IMG_0001.JPG")?.taken == [])
        var packet = try Self.packet("IMG_0001.xmp", in: sandbox)
        #expect(packet.text(XMPNamespace.dateTimeOriginal) == "2024-06-02T01:00:00.25+01:00")
        #expect(packet.text(XMPNamespace.dateCreated) == "2024-06-02T01:00:00.25+01:00")
        #expect(packet.text(XMPNamespace.rating) == "3")
        report = try await xmp.sync([id])
        #expect(report.photo("IMG_0001.JPG")?.written == [] && report.photo("IMG_0001.JPG")?.taken == [])

        try await metadata.apply(.zone([id], offset: 2 * 3600))
        report = try await xmp.sync([id])
        #expect(report.photo("IMG_0001.JPG")?.written == [.captureTime])
        packet = try Self.packet("IMG_0001.xmp", in: sandbox)
        #expect(packet.text(XMPNamespace.dateTimeOriginal) == "2024-06-02T01:00:00.25+02:00")
        let camera = try #require(try await sandbox.row("IMG_0001.JPG").cameraTime)
        let read = try #require(XMPSource(xmp: Data(contentsOf: sandbox.url("IMG_0001.xmp"))))
            .capturing(XMPCaptureTime(packet), camera: XMPCaptureTime(time: camera, offset: 3600))
        #expect(read.fields.captureShift == 5400 && read.fields.captureOffset == 2 * 3600)

        try await metadata.apply(.shift([id], by: -5400))
        try await metadata.apply(.zone([id], offset: nil))
        report = try await xmp.sync([id])
        #expect(report.photo("IMG_0001.JPG")?.written == [.captureTime])
        packet = try Self.packet("IMG_0001.xmp", in: sandbox)
        #expect(packet.text(XMPNamespace.dateTimeOriginal) == "2024-06-01T23:30:00.25+01:00")
        #expect(packet.text(XMPNamespace.dateCreated) == "2024-06-01T23:30:00.25+01:00")
        #expect(sandbox.sidecar("IMG_0001.JPG")?.metadata == PhotoMetadata(rating: 3))
    }

    // MARK: - Other apps' .xmp

    @Test func `another app's capture time is read as a shift and merged as its other fields are`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        for name in ["IMG_0002", "IMG_0003", "IMG_0004", "IMG_0005"] {
            try sandbox.shot("\(name).JPG", at: "2024:06:01 08:30:00", offset: "+01:00")
        }
        // Lightroom Classic's Edit Capture Time, an hour and a half on.
        try sandbox.sidecar("IMG_0002.JPG", PhotoMetadata(rating: 2))
        try Self.write(
            Self.xmp(dateTimeOriginal: "2024-06-01T10:00:00+01:00", dateCreated: "2024-06-01T10:00:00+01:00"),
            at: "IMG_0002.xmp", in: sandbox, modified: 60,
        )
        // A camera left on home time in New York, its time and zone put right by another app.
        try sandbox.sidecar("IMG_0003.JPG", PhotoMetadata(rating: 1))
        try Self.write(
            Self.xmp(dateCreated: "2024-06-01T03:30:00-04:00"),
            at: "IMG_0003.xmp",
            in: sandbox,
            modified: 60,
        )
        // darktable's own, with the camera's time.
        try sandbox.sidecar("IMG_0004.JPG", PhotoMetadata(rating: 4))
        try Self.write(
            Self.xmp(dateTimeOriginal: "2024:06:01 08:30:00.000"), at: "IMG_0004.JPG.xmp", in: sandbox, modified: 60,
        )
        // A .redlamp that shifts the time already keeps its shift the first time.
        try sandbox.sidecar("IMG_0005.JPG", PhotoMetadata(rating: 5, captureShift: 600))
        try Self.write(
            Self.xmp(dateTimeOriginal: "2024-06-01T10:00:00+01:00"), at: "IMG_0005.xmp", in: sandbox, modified: 60,
        )
        try await sandbox.indexAll()
        let xmp = LibraryXMP(index: sandbox.index, paths: sandbox.paths)
        let ids = try await sandbox.ids(["IMG_0002.JPG", "IMG_0003.JPG", "IMG_0004.JPG", "IMG_0005.JPG"])
        let report = try await xmp.sync(ids)

        #expect(report.photo("IMG_0002.JPG")?.taken == [.captureTime])
        #expect(sandbox.sidecar("IMG_0002.JPG")?.metadata == PhotoMetadata(rating: 2, captureShift: 5400))
        let shifted = try await sandbox.row("IMG_0002.JPG")
        #expect(shifted.captured == cameraClock("2024-06-01 10:00:00") && shifted.capturedOffset == 3600)
        #expect(shifted.cameraCaptured == cameraClock("2024-06-01 08:30:00") && shifted.cameraOffset == 3600)
        #expect(!shifted.otherFields.contains(.captureTime))
        #expect(report.photo("IMG_0002.JPG")?.other.captureShift == 5400)

        #expect(report.photo("IMG_0003.JPG")?.taken == [.captureTime])
        #expect(sandbox.sidecar("IMG_0003.JPG")?.metadata == PhotoMetadata(
            rating: 1, captureShift: -5 * 3600, captureOffset: -4 * 3600,
        ))
        let zoned = try await sandbox.row("IMG_0003.JPG")
        #expect(zoned.captured == cameraClock("2024-06-01 03:30:00") && zoned.capturedOffset == -4 * 3600)

        #expect(report.photo("IMG_0004.JPG")?.taken == [], "darktable's time is the camera's")
        #expect(sandbox.sidecar("IMG_0004.JPG")?.metadata == PhotoMetadata(rating: 4))
        #expect(report.photo("IMG_0005.JPG")?.taken == [])
        #expect(sandbox.sidecar("IMG_0005.JPG")?.metadata == PhotoMetadata(rating: 5, captureShift: 600))
        #expect(report.lines.contains { $0.contains("took other apps' changes: capture time 2") }, "\(report.lines)")

        // Indexed again, the rows keep the times taken, without reading the photos again.
        try await sandbox.indexAll()
        #expect(try await sandbox.row("IMG_0002.JPG").captured == cameraClock("2024-06-01 10:00:00"))

        // Later, the other app moves IMG_0005's time, and only it changed it since: its time is taken.
        try Self.write(
            Self.xmp(dateTimeOriginal: "2024-06-01T11:00:00+01:00"), at: "IMG_0005.xmp", in: sandbox, modified: 120,
        )
        try await sandbox.indexAll()
        let later = try await xmp.sync(ids)
        #expect(later.photo("IMG_0005.JPG")?.taken == [.captureTime])
        #expect(sandbox.sidecar("IMG_0005.JPG")?.metadata == PhotoMetadata(rating: 5, captureShift: 9000))
        #expect(later.photo("IMG_0002.JPG")?.unchanged == true)
    }
}
