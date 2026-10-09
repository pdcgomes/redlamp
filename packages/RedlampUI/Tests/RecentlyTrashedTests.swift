import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// Recently Trashed in the app (LIB-26): the photos the library's batches moved to the Trash, shown as a source
/// in the grid and the filmstrip; Put Back by photo, by the selection and by batch, bringing back the photos,
/// their sidecars and their rows through the file operations' journal; nothing in it written, and its photos
/// kept out of Develop; and, empty, a line saying what it holds.
///
/// The Trash is the real one: every photo is a copy made on the external disk's scratch folder, and what a
/// test leaves in the Trash is removed with it.
@MainActor
@Suite(.serialized)
struct RecentlyTrashedTests {
    private let base = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
        .appending(path: "naming-trash-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private func photo(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    private static func edited(rating: Int) -> Sidecar {
        var recipe = EditRecipe()
        recipe[.exposure] = 1
        return Sidecar(recipe: recipe, metadata: PhotoMetadata(rating: rating))
    }

    /// Small JPEGs at `paths` below the root, each its own colour, so each has its own content key.
    private func photos(_ paths: [String]) throws {
        for (number, path) in paths.enumerated() {
            let url = photo(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ))
            context.setFillColor(
                red: CGFloat(number % 7) / 7, green: CGFloat(number % 5) / 5, blue: CGFloat(number % 3) / 3, alpha: 1,
            )
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil,
            ))
            try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: url)
        }
    }

    private func eventually(seconds: Double = 10, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A library following the root, once it has indexed it and caught up with the disk, in an editor.
    private func indexedLibrary() async throws -> (EditorModel, LibraryService) {
        let library = FolderLibrary()
        library.add([root])
        let service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars,
        ) { url, size in StoreThumbnailMaker.imageIO(url, nil, size) }
        library.attach(service)
        for _ in 0 ..< 2000 where await !service.canShow(root, includingSubfolders: true) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await service.canShow(root, includingSubfolders: true), "the library caught up with the root")
        return (EditorModel(engine: StubEngine(), library: library), service)
    }

    /// Runs `body` on the library once it has indexed the photos, then removes what it left in the Trash and
    /// the test's folder, whether `body` threw or not.
    private func withLibrary(_ body: (EditorModel, LibraryService) async throws -> Void) async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let (model, service) = try await indexedLibrary()
        do {
            try await body(model, service)
        } catch {
            await cleanUp(service)
            throw error
        }
        await cleanUp(service)
    }

    private func cleanUp(_ service: LibraryService) async {
        for place in await service.trashedPlaces() {
            try? FileManager.default.removeItem(atPath: place)
        }
        service.closeWithIndex()
    }

    /// The index's row IDs of the photos at `paths`, by path.
    private func rows(_ paths: [String], in service: LibraryService) async throws -> [String: Int64] {
        let core = try #require(service.core)
        let urls = paths.map(photo)
        let found = try await core.index.read { reader in
            try urls.compactMap { url in try LibraryService.photo(at: url, in: reader).map { (url, $0.id) } }
        }
        return Dictionary(uniqueKeysWithValues: found.map { url, id in
            (url.path.replacingOccurrences(of: root.path + "/", with: ""), id)
        })
    }

    /// The place in the Trash of the photo that was at `path`.
    private func place(of path: String, in library: FolderLibrary) throws -> URL {
        let original = photo(path).standardizedFileURL.path
        return try #require(library.items.first { library.trashedPhoto(at: $0.url)?.original == original }?.url)
    }

    @Test func `the Recently Trashed source lists what a batch moved to the Trash, at its places there, with its badges and thumbnails from the store`(
    ) async throws {
        try photos(["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/C.JPG"])
        try SidecarStore().save(Self.edited(rating: 3), for: photo("Shoot/A.JPG"))
        try await withLibrary { model, service in
            let library = model.library
            try await service.moveToTrash([photo("Shoot/A.JPG"), photo("Shoot/B.JPG")])
            try await eventually { library.trashedCount == 2 }
            #expect(library.trashedCount == 2)

            model.showRecentlyTrashed()
            try await eventually { library.showsRecentlyTrashed && library.count == 2 && model.selection != nil }
            #expect(model.module == .library && model.folder == nil)
            #expect(library.items.allSatisfy { LibraryService.isInTrash($0.url) })
            #expect(library.items.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
            let a = try place(of: "Shoot/A.JPG", in: library)
            #expect(library.item(for: a)?.metadata.rating == 3, "its badges as its row had them")
            for item in library.items {
                let (thumbnails, key) = try #require(library.storeThumbnail(for: item))
                #expect(thumbnails.store.contains(key, tier: .grid), "\(item.name)'s thumbnail is in the store")
            }
            #expect(model.selection == library.items.first?.url)
            #expect(model.canPerform(.putBack) && model.canPerform(.putBackBatch))
            #expect(!model.canPerform(.developModule) && !model.canPerform(.editTool) && !model.canPerform(.rating3))
            #expect(!model.perform(.developModule) && model.module == .library, "its photos don't open in Develop")

            model.showFolder(root.appending(path: "Shoot", directoryHint: .isDirectory))
            try await eventually { !library.showsRecentlyTrashed && library.count == 1 }
            #expect(!library.showsRecentlyTrashed && library.items.map(\.name) == ["C.JPG"])
            #expect(!model.canPerform(.putBack))
        }
    }

    @Test func `putting back by photo, by the selection and by batch brings back the photos, their sidecars and their rows`(
    ) async throws {
        let names = ["A", "B", "C", "D", "E"].map { "Shoot/\($0).JPG" }
        try photos(names)
        try SidecarStore().save(Self.edited(rating: 2), for: photo("Shoot/A.JPG"))
        try SidecarStore().save(Self.edited(rating: 4), for: photo("Shoot/D.JPG"))
        let sidecars = try names.reduce(into: [String: Data]()) { found, name in
            let edit = SidecarLocator.besidePhoto(photo(name)).appending(path: "edit.json")
            if FileManager.default.fileExists(atPath: edit.path) {
                found[name] = try Data(contentsOf: edit)
            }
        }
        try #require(sidecars.count == 2)
        try await withLibrary { model, service in
            let library = model.library
            let before = try await rows(names, in: service)
            try #require(before.count == 5)
            let shoot = root.appending(path: "Shoot", directoryHint: .isDirectory)
            try await eventually { library.photoCount(of: shoot) == 5 }

            try await service.moveToTrash([photo(names[0]), photo(names[1])])
            try await service.moveToTrash([photo(names[2])])
            try await service.moveToTrash([photo(names[3]), photo(names[4])])
            model.showRecentlyTrashed()
            try await eventually { library.showsRecentlyTrashed && library.count == 5 }
            try #require(library.count == 5)
            try await eventually { library.photoCount(of: shoot) == 0 }
            #expect(names.allSatisfy { !FileManager.default.fileExists(atPath: photo($0).path) })

            // By photo: A, from its menu, while B is the photo selected.
            try model.select(place(of: names[1], in: library))
            try await model.putBack(place(of: names[0], in: library))?.value
            try await eventually { library.count == 4 }
            #expect(FileManager.default.fileExists(atPath: photo(names[0]).path))
            #expect(!FileManager.default.fileExists(atPath: photo(names[1]).path), "B, selected, stays in the Trash")

            // By the selection: B and C, by Put Back's key.
            try model.select(place(of: names[1], in: library))
            try model.click(place(of: names[2], in: library), toggling: true)
            #expect(model.selectedPhotos.count == 2)
            #expect(model.perform(.putBack))
            try await eventually { library.count == 2 }
            #expect([names[1], names[2]].allSatisfy { FileManager.default.fileExists(atPath: photo($0).path) })

            // By batch: D and E, D selected.
            try model.select(place(of: names[3], in: library))
            #expect(model.perform(.putBackBatch))
            try await eventually { library.count == 0 && library.trashedCount == 0 }
            #expect(names.allSatisfy { FileManager.default.fileExists(atPath: photo($0).path) })
            for (name, data) in sidecars {
                let edit = SidecarLocator.besidePhoto(photo(name)).appending(path: "edit.json")
                #expect(try Data(contentsOf: edit) == data, "\(name)'s sidecar came back as it went")
            }
            #expect(try await rows(names, in: service) == before, "every row back under its ID")
            try await eventually { library.photoCount(of: shoot) == 5 }
            #expect(library.photoCount(of: shoot) == 5, "counted again")
            #expect(await service.trashedPlaces().isEmpty)

            // Put Back was a batch of the journal's: Undo moves the last one's photos to the Trash again.
            let core = try #require(service.core)
            try await core.files.undo()
            try await eventually { library.count == 2 }
            #expect(library.count == 2 && !FileManager.default.fileExists(atPath: photo(names[3]).path))
            try model.select(#require(library.items.first?.url))
            await model.putBackBatch()?.value
            try await eventually { library.count == 0 }
            #expect(names.allSatisfy { FileManager.default.fileExists(atPath: photo($0).path) })
        }
    }

    @Test func `⌘Z after Put Back moves the photos to the Trash again and ⇧⌘Z puts them back, in turn with culling's changes`(
    ) async throws {
        let names = ["A", "B", "C"].map { "Shoot/\($0).JPG" }
        try photos(names)
        try SidecarStore().save(Self.edited(rating: 2), for: photo(names[0]))
        let edit = SidecarLocator.besidePhoto(photo(names[0])).appending(path: "edit.json")
        let sidecar = try Data(contentsOf: edit)
        try await withLibrary { model, service in
            let library = model.library
            let before = try await rows(names, in: service)
            try #require(before.count == 3)
            let shoot = root.appending(path: "Shoot", directoryHint: .isDirectory)
            @MainActor func inTrash() -> Bool {
                [names[0], names[1]].allSatisfy { !FileManager.default.fileExists(atPath: photo($0).path) }
                    && !FileManager.default.fileExists(atPath: edit.path) && library.trashedCount == 2
            }
            @MainActor func back() -> Bool {
                names.allSatisfy { FileManager.default.fileExists(atPath: photo($0).path) }
                    && library.trashedCount == 0
            }
            try await service.moveToTrash([photo(names[0]), photo(names[1])])
            model.showRecentlyTrashed()
            try await eventually { library.showsRecentlyTrashed && library.count == 2 }
            try model.select(place(of: names[0], in: library))
            #expect(!model.canPerform(.undo), "nothing to take back yet")
            await model.putBackBatch()?.value
            try await eventually { back() && library.count == 0 }
            #expect(try Data(contentsOf: edit) == sidecar && model.canPerform(.undo))

            // In Recently Trashed, ⌘Z and ⇧⌘Z, each way with the photos' sidecars and rows.
            #expect(model.perform(.undo))
            await model.putBackSteps.made()
            try await eventually { inTrash() && library.count == 2 }
            #expect(inTrash(), "⌘Z moved them to the Trash again, A's sidecar with it")
            let staying = try #require(before[names[2]])
            #expect(try await rows(names, in: service) == [names[2]: staying], "their rows out of the index")
            #expect(model.canPerform(.redo) && model.perform(.redo))
            await model.putBackSteps.made()
            try await eventually { back() && library.count == 0 }
            #expect(back() && (try? Data(contentsOf: edit)) == sidecar, "⇧⌘Z put them back, A's sidecar as it was")
            #expect(try await rows(names, in: service) == before, "every row back under its ID")

            // In their folder, after a culling change: ⌘Z takes back the rating first, then the Put Back.
            model.showFolder(shoot)
            try await eventually { !library.showsRecentlyTrashed && library.count == 3 }
            model.select(photo(names[2]))
            model.cull(.rating(4), from: photo(names[2]))
            try await eventually { !model.isWritingCulling && library.item(for: photo(names[2]))?.metadata.rating == 4 }
            #expect(model.perform(.undo))
            try await eventually { !model.isWritingCulling && library.item(for: photo(names[2]))?.metadata.rating == 0 }
            #expect(back(), "the rating went first")
            #expect(model.perform(.undo))
            await model.putBackSteps.made()
            try await eventually { inTrash() && library.count == 1 }
            #expect(inTrash() && library.items.map(\.name) == ["C.JPG"], "then the Put Back")
            // ⇧⌘Z makes them again newest first: the Put Back, then the rating.
            #expect(model.perform(.redo))
            await model.putBackSteps.made()
            try await eventually { back() && library.count == 3 }
            #expect(back() && library.item(for: photo(names[2]))?.metadata.rating == 0)
            #expect(model.perform(.redo))
            try await eventually { !model.isWritingCulling && library.item(for: photo(names[2]))?.metadata.rating == 4 }
            #expect(library.item(for: photo(names[2]))?.metadata.rating == 4)
            #expect(try await rows(names, in: service).keys.sorted() == names)
        }
    }

    @Test func `a Put Back whose photos have moved since isn't taken back, and ⌘Z goes on to the change before it`(
    ) async throws {
        let names = ["A", "B"].map { "Shoot/\($0).JPG" }
        try photos(names)
        try await withLibrary { model, service in
            let library = model.library
            let shoot = root.appending(path: "Shoot", directoryHint: .isDirectory)
            model.showModule(.library)
            model.showFolder(shoot)
            try await eventually { library.count == 2 }
            model.select(photo(names[1]))
            model.cull(.rating(3), from: photo(names[1]))
            try await eventually { !model.isWritingCulling && library.item(for: photo(names[1]))?.metadata.rating == 3 }
            #expect(library.item(for: photo(names[1]))?.metadata.rating == 3)
            try await service.moveToTrash([photo(names[0])])
            model.showRecentlyTrashed()
            try await eventually { library.showsRecentlyTrashed && library.count == 1 }
            try await model.putBack(#require(library.items.first?.url))?.value
            try #require(FileManager.default.fileExists(atPath: photo(names[0]).path))

            let elsewhere = base.appending(path: "Elsewhere.JPG", directoryHint: .notDirectory)
            try FileManager.default.moveItem(at: photo(names[0]), to: elsewhere)
            let logged = model.activity.events.count
            #expect(model.perform(.undo))
            await model.putBackSteps.made()
            #expect(model.activity.events.dropFirst(logged).contains { $0.kind == .error && $0.text.hasPrefix("Undo") })
            #expect(FileManager.default.fileExists(atPath: elsewhere.path), "what moved away stays where it is")
            #expect(model.putBackSteps.undo.isEmpty && model.putBackSteps.redo.isEmpty)
            model.showFolder(shoot)
            try await eventually { !library.showsRecentlyTrashed && library.item(for: photo(names[1])) != nil }
            #expect(model.module == .library && model.perform(.undo))
            try await eventually { !model.isWritingCulling && library.item(for: photo(names[1]))?.metadata.rating == 0 }
            #expect(library.item(for: photo(names[1]))?.metadata.rating == 0, "⌘Z took back the rating before it")
        }
    }

    @Test func `photos in Recently Trashed don't open in Develop, and culling leaves them and their sidecars as they are`(
    ) async throws {
        try photos(["Shoot/A.JPG"])
        try SidecarStore().save(Self.edited(rating: 3), for: photo("Shoot/A.JPG"))
        try await withLibrary { model, service in
            let library = model.library
            // Shown at once, before the list after the batch is in: its photo is selected as it arrives.
            try await service.moveToTrash([photo("Shoot/A.JPG")])
            model.showRecentlyTrashed()
            try await eventually { library.showsRecentlyTrashed && library.count == 1 && model.selection != nil }
            let place = try #require(library.items.first?.url)
            #expect(model.selection == place)
            let trashed = try #require(library.trashedPhoto(at: place))
            let sidecar = try #require(trashed.files.first { $0.role == .sidecar })
            let edit = URL(fileURLWithPath: sidecar.place).appending(path: "edit.json")
            let kept = try Data(contentsOf: edit)

            #expect(!model.perform(.editTool) && model.module == .library && model.info == nil)
            let logged = model.activity.events.count
            @MainActor func refused() -> Bool {
                model.activity.events.dropFirst(logged)
                    .contains { $0.kind == .error && $0.text.contains("in the Trash") }
            }
            model.cull(.rating(5), from: place)
            try await eventually { !model.isWritingCulling && refused() }
            #expect(refused(), "the activity log says why")
            #expect(try Data(contentsOf: edit) == kept, "its sidecar in the Trash wasn't written")
            let beside = place.path + ".redlamp"
            #expect(
                sidecar.place == beside || !FileManager.default.fileExists(atPath: beside),
                "none was made beside it",
            )
            if sidecar.place == beside {
                #expect(library.item(for: place)?.metadata.rating == 3, "shown as its sidecar has it")
            }
        }
    }

    @Test func `an empty Recently Trashed says what it holds in the Folders panel`() async throws {
        try photos(["Shoot/A.JPG"])
        try await withLibrary { model, _ in
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 260, height: 500), styleMask: [.titled], backing: .buffered,
                defer: false,
            )
            let list = SidebarListView(model: model)
            window.contentView = list
            defer { window.contentView = nil }
            list.layoutSubtreeIfNeeded()
            @MainActor func kinds() -> [SidebarNode.Kind] {
                (0 ..< list.folders.numberOfRows).compactMap { (list.folders.item(atRow: $0) as? SidebarNode)?.kind }
            }
            @MainActor func trashRow() -> (index: Int, row: TrashRow)? {
                for (index, kind) in kinds().enumerated() {
                    if case let .recentlyTrashed(row) = kind {
                        return (index, row)
                    }
                }
                return nil
            }
            try await eventually { trashRow()?.row.count == 0 }
            #expect(trashRow()?.row == TrashRow(count: 0, isOpen: false))

            model.showRecentlyTrashed()
            try await eventually { trashRow()?.row.isOpen == true }
            let placeholders = kinds().compactMap { kind -> String? in
                if case let .placeholder(text) = kind {
                    text
                } else {
                    nil
                }
            }
            #expect(placeholders == [RecentlyTrashedText.empty])
            let index = try #require(trashRow()?.index)
            let cell = list.folders.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarCellView
            #expect(cell?.toolTip == RecentlyTrashedText.help)
        }
    }
}
