import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// Compare and Survey over stacks (LIB-16, LIB-28): a closed stack, or a JPEG beside its HEIC, is one photo in them as
/// it's one cell in the grid, its first, standing for all of them: the candidate goes from cell to cell, a culling key
/// reaches every photo of the active cell, Survey shows a photo for each cell selected and a photo's × takes its cell's
/// photos out of the selection.
@MainActor
struct LibraryCompareStackTests {
    /// A burst of three frames a third of a second apart, B01 to B03; a JPEG beside its HEIC, P01, a minute later;
    /// and S01 to S04 alone, ten minutes apart.
    private static let photos: [(path: String, time: Double, type: UTType)] = [
        ("B01.JPG", 0, .jpeg), ("B02.JPG", 0.33, .jpeg), ("B03.JPG", 0.66, .jpeg), ("P01.JPG", 60, .jpeg),
        ("P01.HEIC", 60, .heic), ("S01.JPG", 600, .jpeg), ("S02.JPG", 1200, .jpeg), ("S03.JPG", 1800, .jpeg),
        ("S04.JPG", 2400, .jpeg),
    ]

    @MainActor
    private final class Opened {
        var service: LibraryService?
    }

    private let base = LibrarySandbox.scratch
        .appending(path: "library-compare-stacks-\(UUID().uuidString)", directoryHint: .isDirectory)
        .standardizedFileURL
    private let suite = "library-compare-stacks-tests-\(UUID().uuidString)"
    private let opened = Opened()

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private func cleanUp() {
        LibrarySandbox.remove(base, closing: [opened.service])
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func write(_ path: String, time: Double, type: UTType) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let whole = time.rounded(.down)
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X-T5"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: String(
                    format: "2024:06:14 10:%02d:%02d", Int(whole) / 60, Int(whole) % 60,
                ),
                kCGImagePropertyExifSubsecTimeOriginal: String(format: "%02d", Int((time - whole) * 100)),
            ],
        ]
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }

    /// The folder indexed and open from the library in Library's grid, once its burst and pair are found.
    private func open() async throws -> EditorModel {
        for photo in Self.photos {
            try write(photo.path, time: photo.time, type: photo.type)
        }
        let library = FolderLibrary(defaults: UserDefaults(suiteName: suite))
        library.setIncludesSubfolders(false)
        library.add([root])
        let service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars, defaults: UserDefaults(suiteName: suite)!,
        ) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        opened.service = service
        library.attach(service)
        let deadline = ContinuousClock.now + .seconds(30)
        while await !service.canShow(root, includingSubfolders: true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let model = EditorModel(engine: StubEngine(), library: library)
        model.open([root])
        try await eventually { library.isShownFromLibrary && !library.isListing && library.count == Self.photos.count }
        model.showLibrary(.grid)
        try await eventually { model.gridStacks.list.map { $0.stacksShown == (0, 2) } == true }
        try #require(model.gridStacks.list.map { $0.stacksShown == (0, 2) } == true, "the burst and the pair found")
        return model
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func url(_ model: EditorModel, _ name: String) throws -> URL {
        try #require(model.items.first { $0.url.lastPathComponent == name }?.url)
    }

    private func names(_ urls: [URL?]) -> [String] {
        urls.map { $0?.lastPathComponent ?? "-" }
    }

    @Test func `Compare's photos are the grid's cells, and a culling key reaches every photo of the active one`()
        async throws {
        defer { cleanUp() }
        let model = try await open()
        let cells = model.gridCellPhotos
        try #require(cells.count == 6 && cells[0].count == 3 && cells[1].count == 2, "cells \(cells)")
        try model.clickInGrid(url(model, cells[0][0]))
        #expect(Set(model.selectedPhotos.map(\.lastPathComponent)) == Set(cells[0]))
        #expect(model.perform(.compareView))
        let compare = model.libraryCompare
        #expect(names([compare.select, compare.candidate]) == [cells[0][0], cells[1][0]], "the next cell, not B02")
        #expect(Set(model.selectedPhotos.map(\.lastPathComponent)) == Set(cells[0] + cells[1]))
        #expect(model.perform(.nextPhoto) && compare.candidate?.lastPathComponent == cells[2][0])
        #expect(model.perform(.rating3))
        let rated = Set(model.items.filter { $0.metadata.rating == 3 }.map(\.url.lastPathComponent))
        #expect(rated == Set(cells[0]), "the burst's every photo, and nothing else: \(rated)")
        model.activateCompared(.candidate)
        try model.clickInGrid(url(model, cells[1][0]))
        try await Task.sleep(for: .milliseconds(30))
        model.keepCompareInStep()
        #expect(compare.candidate?.lastPathComponent == cells[1][0], "the pair chosen in the filmstrip")
        #expect(model.perform(.flagPick))
        let picked = Set(model.items.filter { $0.metadata.flag == .pick }.map(\.url.lastPathComponent))
        #expect(picked == Set(cells[1]), "the JPEG and its HEIC: \(picked)")
        while let tail = model.cullingTail {
            await tail.value
            if model.cullingTail == tail {
                break
            }
        }
    }

    @Test func `Survey shows a photo for each cell selected, and a photo's × takes out all its cell's photos`()
        async throws {
        defer { cleanUp() }
        let model = try await open()
        let cells = model.gridCellPhotos
        try #require(cells.count == 6, "cells \(cells)")
        try model.clickInGrid(url(model, cells[0][0]))
        try model.clickInGrid(url(model, cells[1][0]), toggling: true)
        try model.clickInGrid(url(model, cells[3][0]), toggling: true)
        #expect(model.selectedPhotos.count == 6)
        #expect(model.perform(.surveyView))
        #expect(names(model.surveyPhotos) == [cells[0][0], cells[1][0], cells[3][0]])
        #expect(model.surveyActivePhoto?.lastPathComponent == cells[3][0])
        #expect(model.perform(.previousPhoto) && model.selection?.lastPathComponent == cells[1][0])
        #expect(try model.removeFromSurvey(url(model, cells[1][0])))
        #expect(Set(model.selectedPhotos.map(\.lastPathComponent)) == Set(cells[0] + cells[3]), "the pair's both")
        #expect(names(model.surveyPhotos) == [cells[0][0], cells[3][0]] && model.libraryView == .survey)
        #expect(model.surveyActivePhoto?.lastPathComponent == cells[3][0], "the photo selected after it is active")
    }
}
