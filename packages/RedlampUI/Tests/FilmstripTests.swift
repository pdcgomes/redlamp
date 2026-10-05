import AppKit
import CoreGraphics
import Foundation
import RedlampDocument
import RedlampEngineAPI
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

    private func titles(_ menu: NSMenu?) -> [String] {
        menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
    }

    @Test func `the menu on a selected photo is the Photo menu's`() async throws {
        defer { cleanUp() }
        let (model, _, window) = try await showStrip(count: 4)
        defer { window.contentView = nil }
        try await eventually { model.info != nil }
        model.copySelection = .default
        let open = try #require(model.selection)
        #expect(titles(FilmstripMenu.menu(for: open, model: model)) == [
            "Copy Settings…", "Copy Settings with Last Choice",
        ])
        model.copySettings()
        model.selectAllPhotos()
        let menu = FilmstripMenu.menu(for: model.items[2].url, model: model)
        #expect(titles(menu) == [
            "Copy Settings…", "Copy Settings with Last Choice", "Paste Settings", "Sync Settings…",
            "Sync Settings with Last Choice", "Auto Sync",
        ])
        #expect(menu?.items.first?.keyEquivalent == "c")
        #expect(menu?.items.first { $0.title == "Auto Sync" }?.state == .off)
        model.toggleAutoSync()
        defer { model.toggleAutoSync() }
        #expect(FilmstripMenu.menu(for: open, model: model)?.items.first { $0.title == "Auto Sync" }?.state == .on)
    }

    /// A photo outside the selection is pasted onto in the background; the open one stays as it is.
    @Test func `the menu on another photo pastes onto it alone, without opening it`() async throws {
        defer { cleanUp() }
        let (model, _, window) = try await showStrip(count: 4)
        defer { window.contentView = nil }
        try await eventually { model.info != nil }
        model.copySelection = .default
        let open = try #require(model.selection)
        model.setValue(.exposure, 1)
        model.copySettings()
        model.setValue(.exposure, 0.5)
        let other = model.items[3].url
        let menu = try #require(FilmstripMenu.menu(for: other, model: model))
        #expect(titles(menu) == ["Copy Settings…", "Copy Settings with Last Choice", "Paste Settings"])
        let keys = menu.items.map(\.keyEquivalent).filter { !$0.isEmpty }
        #expect(keys.isEmpty, "the keys act on the open photo")
        let paste = try #require(menu.items.firstIndex { $0.title == "Paste Settings" })
        menu.performActionForItem(at: paste)
        await model.settingsSync.idle()
        #expect(SidecarStore().load(for: other)?.recipe[.exposure] == 1)
        #expect(model.selection == open && model.selectedPhotos == [open])
        #expect(model.recipe[.exposure] == 0.5)
        #expect(titles(FilmstripMenu.menu(for: other, model: model)).last == "Undo Sync Settings")
    }

    /// Copying from a photo that isn't open reads its sidecar.
    @Test func `copying from another photo reads its edit`() async throws {
        defer { cleanUp() }
        let (model, _, window) = try await showStrip(count: 4)
        defer { window.contentView = nil }
        try await eventually { model.info != nil }
        model.copySelection = .default
        let other = model.items[2].url
        var edited = EditRecipe()
        edited[.contrast] = 30
        try SidecarStore().save(Sidecar(recipe: edited), for: other)

        await model.chooseSettingsToCopy(from: other)
        let chooser = try #require(model.settingsChooser)
        #expect(chooser.source[.contrast] == 30 && chooser.sourceURL == other)
        model.confirmSettingsChoice(chooser.selection)
        model.pasteSettings()
        #expect(model.recipe[.contrast] == 30)

        await model.copySettings(from: model.items[1].url)
        model.pasteSettings()
        #expect(model.recipe[.contrast] == 0, "a photo without an edit copies the default edit")
    }

    /// Right-click on a cell: its photo's menu, and a ring while it's open.
    @Test func `a cell's right-click opens its photo's menu`() async throws {
        defer { cleanUp() }
        let (model, strip, window) = try await showStrip(count: 4)
        defer { window.contentView = nil }
        try await eventually { model.info != nil && cell(strip, 2) != nil }
        let target = try #require(cell(strip, 2))
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        ))
        let menu = try #require(target.menu(for: event))
        #expect(titles(menu).first == "Copy Settings…")
        target.willOpenMenu(menu, with: event)
        #expect(target.isMenuTarget)
        target.didCloseMenu(menu, with: event)
        #expect(!target.isMenuTarget)
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
