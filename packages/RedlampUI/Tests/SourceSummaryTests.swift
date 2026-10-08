import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// A source's summary (LIB-23, LIB-41): its photos and picks, its days, cameras and lenses, its ISO, shutter and
/// aperture ranges, and its pairs and stacks, from the library, in words, for a collection, a Library entry and a
/// folder alike.
@MainActor
@Suite(.serialized)
struct SourceSummaryTests {
    private struct Shot {
        var name: String
        var taken: String
        var model: String
        var iso: Int
        var aperture: Double
        var shutter: Double
    }

    /// A small JPEG with `shot`'s EXIF: when it was taken, the camera, the lens and the exposure.
    private static func jpeg(_ shot: Shot, number: Int) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(red: CGFloat(number % 7) / 7, green: 0.5, blue: CGFloat(number % 3) / 3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Redlamp", kCGImagePropertyTIFFModel: shot.model,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: shot.taken, kCGImagePropertyExifISOSpeedRatings: [shot.iso],
                kCGImagePropertyExifFNumber: shot.aperture, kCGImagePropertyExifExposureTime: shot.shutter,
                kCGImagePropertyExifLensModel: "Test Lens \(shot.model)",
            ],
        ]
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func `a collection's summary names its days, cameras, lenses and settings, and its pairs and stacks`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let shots = [
            Shot(name: "A.JPG", taken: "2025:06:14 10:00:00", model: "Body One", iso: 200, aperture: 2, shutter: 0.004),
            Shot(name: "B.JPG", taken: "2025:06:15 11:00:00", model: "Body One", iso: 3200, aperture: 5.6, shutter: 2),
            Shot(
                name: "C.JPG",
                taken: "2025:06:15 12:00:00",
                model: "Body Two",
                iso: 100,
                aperture: 8,
                shutter: 0.00025,
            ),
        ]
        try FileManager.default.createDirectory(at: sandbox.folder("Trip"), withIntermediateDirectories: true)
        for (number, shot) in shots.enumerated() {
            try Self.jpeg(shot, number: number).write(to: sandbox.photo("Trip/" + shot.name))
        }
        let model = try await sandbox.open()
        let sources = model.librarySources
        let service = try #require(sandbox.service)
        try await sandbox.counts { $0.count(of: .allPhotographs) == 3 }
        model.showFolder(sandbox.folder("Trip"))
        try await sandbox.eventually { model.items.count == 3 }
        try await sandbox.cull(.flagPick, [sandbox.photo("Trip/B.JPG")])
        #expect(sources.create(.collection, named: "Trip"))
        let trip = try #require(CollectionPath("Trip"))
        await model.libraryPanels.written()
        try await sandbox.counts { $0.collections[trip] != nil }
        model.select(sandbox.photo("Trip/A.JPG"))
        model.click(sandbox.photo("Trip/B.JPG"), toggling: true)
        model.click(sandbox.photo("Trip/C.JPG"), toggling: true)
        #expect(sources.add(to: trip))
        try await sandbox.eventually { model.libraryPanels.undoCount > 1 }
        await model.libraryPanels.written()
        try await sandbox.counts { $0.count(of: .collection(trip)) == 3 }

        let summary = try #require(await service.summary(of: .collection(trip)))
        #expect(summary.photos == 3 && summary.picks == 1 && summary.days == 2)
        #expect(summary.cameras.map(\.count) == [2, 1] && summary.lenses.count == 2)
        let first = try #require(SourceSummaryText.day(.day(2025, 6, 14)))
        let last = try #require(SourceSummaryText.day(.day(2025, 6, 15)))
        let lines = SourceSummaryText.lines(summary)
        try #require(lines.count == 6, "\(lines)")
        #expect(lines[0] == "3 photos, 1 pick")
        #expect(lines[1] == "Taken over 2 days, from \(first) to \(last)")
        #expect(lines[2].hasPrefix("Cameras: ") && lines[2].contains("Body One") && lines[2].hasSuffix("(1)"))
        #expect(lines[3].hasPrefix("Lenses: Test Lens"))
        #expect(lines[4] == "ISO 100 to 3200 · 1/4000 s to 2 s · f/2 to f/8")
        #expect(lines[5] == "No pairs or stacks")

        // A Library entry's and a folder's alike: the pick alone, and the folder's three.
        let picks = try #require(await service.summary(of: .query(.filter(LibraryQuery.Filter(
            .flag,
            .equal,
            [.flag(.pick)],
        )))))
        #expect(SourceSummaryText.lines(picks).prefix(2) == ["1 photo, 1 pick", "Taken on \(last)"])
        let folder = try #require(await service.summary(of: .folder(sandbox.folder("Trip"), includingSubfolders: true)))
        #expect(folder.photos == 3)
    }

    @Test func `the summary shown beside a row says it's counting, then what the library found`() async throws {
        let sandbox = SourcesSandbox()
        defer {
            SourceSummaryPopover.close()
            sandbox.remove()
        }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG"])
        let model = try await sandbox.open()
        let sources = model.librarySources
        try await sandbox.counts { $0.count(of: .allPhotographs) == 2 }
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let row = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(row)
        window.orderFront(nil)
        defer { window.close() }
        sources.showSummary(of: .allPhotographs, relativeTo: row)
        #expect(SourceSummaryPopover.shownLines == ["All Photographs", "Counting…"])
        try await sandbox.eventually { SourceSummaryPopover.shownLines.count > 2 }
        let shown = SourceSummaryPopover.shownLines
        #expect(shown.prefix(3) == ["All Photographs", "2 photos", "No capture times"])
        #expect(shown.last == "No pairs or stacks")
    }
}
