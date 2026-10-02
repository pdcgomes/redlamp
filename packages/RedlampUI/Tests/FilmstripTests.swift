import AppKit
import CoreGraphics
import Foundation
import RedlampDocument
import Testing
@testable import RedlampUI

/// The AppKit filmstrip: reused cells, thumbnails and badges per cell, and the selection.
@MainActor
struct FilmstripTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "strip-\(UUID().uuidString)")
    private let packs = FileManager.default.temporaryDirectory.appending(path: "strip-packs-\(UUID().uuidString)")

    private func makeFolder(count: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..< count {
            FileManager.default.createFile(
                atPath: folder.appending(path: String(format: "IMG_%05d.ARW", index)).path, contents: Data([1]),
            )
        }
    }

    private nonisolated static func image(_ size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: size, height: size * 2 / 3, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { return nil }
        return context.makeImage()
    }

    private func showStrip(count: Int) async throws -> (EditorModel, FilmstripStripView, NSWindow) {
        try makeFolder(count: count)
        let loader = ThumbnailLoader(packs: ThumbnailPacks(directory: packs)) { _, size in Self.image(size) }
        let model = EditorModel(engine: StubEngine(), thumbnailLoader: loader)
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: FilmstripStripView.height), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        let strip = FilmstripStripView(model: model)
        window.contentView = strip
        model.open([folder])
        try await eventually { model.library.count == count && model.selection != nil }
        strip.layoutSubtreeIfNeeded()
        strip.collectionView.layoutSubtreeIfNeeded()
        return (model, strip, window)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: packs)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func cell(_ strip: FilmstripStripView, _ row: Int) -> FilmstripCellView? {
        (strip.collectionView.item(at: IndexPath(item: row, section: 0)) as? FilmstripItem)?.cell
    }

    @Test func `a thousand photos make only a screenful of cells`() async throws {
        defer { cleanUp() }
        let (_, strip, window) = try await showStrip(count: 1000)
        defer { window.contentView = nil }
        #expect(strip.collectionView.numberOfItems(inSection: 0) == 1000)
        let cells = strip.collectionView.subviews.count { $0 is FilmstripCellView }
        #expect(cells > 0 && cells < 40, "\(cells) cells for a 900 pt strip")
    }

    @Test func `visible cells get their thumbnails, and a badge changes only its cell`() async throws {
        defer { cleanUp() }
        let (model, strip, window) = try await showStrip(count: 50)
        defer { window.contentView = nil }
        try await eventually { cell(strip, 0)?.image != nil && cell(strip, 3)?.image != nil }
        #expect(cell(strip, 0)?.image != nil)
        let neighbour = cell(strip, 3)
        let neighbourImage = neighbour?.image

        model.library.update(model.items[2].url) { $0.metadata.rating = 5 }
        #expect(cell(strip, 2)?.item?.metadata.rating == 5)
        #expect(cell(strip, 3) === neighbour, "no reload")
        #expect(cell(strip, 3)?.image === neighbourImage)
    }

    @Test func `the selected photo's cell is highlighted`() async throws {
        defer { cleanUp() }
        let (model, strip, window) = try await showStrip(count: 20)
        defer { window.contentView = nil }
        try await eventually { cell(strip, 0)?.isSelected == true }
        #expect(cell(strip, 0)?.isSelected == true)
        model.select(model.items[4].url)
        try await eventually { cell(strip, 4)?.isSelected == true }
        #expect(cell(strip, 4)?.isSelected == true)
        #expect(cell(strip, 0)?.isSelected == false)
    }

    @Test func `a photo added to the folder slides in without a reload`() async throws {
        defer { cleanUp() }
        let (model, strip, window) = try await showStrip(count: 5)
        defer { window.contentView = nil }
        let first = cell(strip, 0)
        model.library.insert(LibraryItem(url: folder.appending(path: "IMG_00002a.ARW")))
        strip.collectionView.layoutSubtreeIfNeeded()
        #expect(strip.collectionView.numberOfItems(inSection: 0) == 6)
        #expect(cell(strip, 0) === first)
        #expect(cell(strip, 3)?.item?.name == "IMG_00002a.ARW")
    }
}
