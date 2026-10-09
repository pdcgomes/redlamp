import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Synchronization
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// The library in the app: folders shown from photo lists as listing shows them, LibraryLive's
/// changes as row diffs, the switch from a listed folder without a jump, sidecars kept on this Mac,
/// thumbnails from the store, the off-switch and the fallback, and a launch that never waits.
@MainActor
struct LibraryServiceTests {
    private let base = FileManager.default.temporaryDirectory
        .appending(path: "library-app-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
    private let suite = "library-app-tests-\(UUID().uuidString)"

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private var paths: LibraryPaths {
        LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory))
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suite)!
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// Small JPEGs at `paths` below the root, each its own colour, so each has its own content key.
    private func photos(_ paths: [String]) throws {
        for (number, path) in paths.enumerated() {
            try write(path, shade: number)
        }
    }

    private func write(_ path: String, shade: Int) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(
            red: CGFloat(shade % 7) / 7, green: CGFloat(shade % 5) / 5, blue: CGFloat(shade % 3) / 3, alpha: 1,
        )
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ))
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }

    private func photo(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    private static var edited: EditRecipe {
        var recipe = EditRecipe()
        recipe[.exposure] = 1
        return recipe
    }

    private func service(_ library: FolderLibrary, defaults: UserDefaults? = nil) -> LibraryService {
        LibraryService(paths: paths, sidecars: library.sidecars, defaults: defaults) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
    }

    /// A library following the root, once it has indexed it and caught up with the disk.
    private func indexedLibrary(defaults: UserDefaults? = nil) async throws -> (FolderLibrary, LibraryService) {
        let library = FolderLibrary()
        library.add([root])
        let service = service(library, defaults: defaults)
        library.attach(service)
        try await caughtUp(service)
        return (library, service)
    }

    private func caughtUp(_ service: LibraryService) async throws {
        for _ in 0 ..< 2000 {
            if await service.canShow(root, includingSubfolders: true) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the library didn't catch up with \(root.path): \(service.state)")
    }

    private func eventually(seconds: Double = 30, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func open(_ url: URL, in model: EditorModel) async throws {
        model.select(url)
        try await eventually { model.info?.url == url }
        try #require(model.info?.url == url)
    }

    @Test func `an indexed folder is shown from its photo list as listing it shows it`() async throws {
        defer { cleanUp() }
        try photos(["IMG_2.JPG", "IMG_10.JPG", "IMG_1.JPG", "B/IMG_3.JPG", "A/IMG_4.JPG", "A/C/IMG_5.JPG"])
        try SidecarStore().save(
            Sidecar(recipe: Self.edited, metadata: PhotoMetadata(rating: 4, flag: .pick)), for: photo("IMG_10.JPG"),
        )
        let listed = FolderLibrary()
        listed.setIncludesSubfolders(true)
        listed.open(root)
        try await eventually { !listed.isListing && listed.item(for: photo("IMG_10.JPG"))?.hasEdits == true }

        let (library, _) = try await indexedLibrary()
        library.setIncludesSubfolders(true)
        library.open(root)
        try await eventually { library.isShownFromLibrary && !library.isListing }
        #expect(library.isShownFromLibrary)
        #expect(library.items.map(\.name) == [
            "IMG_1.JPG",
            "IMG_2.JPG",
            "IMG_10.JPG",
            "IMG_4.JPG",
            "IMG_5.JPG",
            "IMG_3.JPG",
        ])
        #expect(library.items.map(\.url) == listed.items.map(\.url))
        #expect(library.items.map(\.size) == listed.items.map(\.size))
        #expect(library.items.map(\.hasEdits) == listed.items.map(\.hasEdits))
        #expect(library.items.map(\.metadata) == listed.items.map(\.metadata))
        #expect(library.index(of: photo("A/C/IMG_5.JPG")) == 4)
    }

    @Test func `the library's changes reach the filmstrip as the row diffs they make`() async throws {
        defer { cleanUp() }
        try photos(["A.JPG", "C.JPG", "E.JPG"])
        let (library, _) = try await indexedLibrary()
        library.open(root)
        try await eventually { library.isShownFromLibrary && !library.isListing }
        try #require(library.items.map(\.name) == ["A.JPG", "C.JPG", "E.JPG"])

        var rows = library.items.map(\.url)
        var diffs: [LibraryDiff] = []
        var mismatches = 0
        let observation = library.observe { diff in
            diffs.append(diff)
            var after = rows.enumerated().filter { !diff.removed.contains($0.offset) }.map(\.element)
            for index in diff.inserted {
                after.insert(library.items[index].url, at: index)
            }
            if diff.reset || after != library.items.map(\.url) {
                mismatches += 1
            }
            rows = library.items.map(\.url)
        }
        defer { observation.invalidate() }

        // Redlamp's own write, which FSEvents doesn't report: the library reads the sidecar again.
        try SidecarStore().save(Sidecar(recipe: Self.edited, metadata: PhotoMetadata(rating: 3)), for: photo("C.JPG"))
        library.sidecarSaved(photo("C.JPG"))
        try await eventually { library.items[1].metadata.rating == 3 }
        #expect(library.items[1].metadata.rating == 3 && library.items[1].hasEdits)
        #expect(diffs == [LibraryDiff(updated: [1])], "the badge changes only its row")

        // A photo arrives, one goes and one is renamed, on disk.
        try write("B.JPG", shade: 7)
        try FileManager.default.removeItem(at: photo("E.JPG"))
        try FileManager.default.moveItem(at: photo("A.JPG"), to: photo("D.JPG"))
        try await eventually { library.items.map(\.name) == ["B.JPG", "C.JPG", "D.JPG"] }
        #expect(library.items.map(\.name) == ["B.JPG", "C.JPG", "D.JPG"])
        #expect(mismatches == 0, "every diff takes the rows before it to the rows after it, without a reset")
        #expect(library.items[1].metadata.rating == 3, "the photo that stayed keeps its badges")
    }

    @Test func `a photo's content key comes across when its file changes, and not when only its badges do`(
    ) async throws {
        defer { cleanUp() }
        try photos(["A.JPG", "C.JPG"])
        let (library, _) = try await indexedLibrary()
        library.open(root)
        try await eventually { library.isShownFromLibrary && !library.isListing }
        try #require(library.items.map(\.name) == ["A.JPG", "C.JPG"])
        let key = try #require(library.storeThumbnail(for: library.items[1])?.1)

        try SidecarStore().save(Sidecar(recipe: Self.edited, metadata: PhotoMetadata(rating: 3)), for: photo("C.JPG"))
        library.sidecarSaved(photo("C.JPG"))
        try await eventually { library.items[1].metadata.rating == 3 }
        #expect(library.items[1].metadata.rating == 3)
        #expect(library.storeThumbnail(for: library.items[1])?.1 == key, "a badge's change keeps the photo's key")

        try write("C.JPG", shade: 9)
        try await eventually { library.storeThumbnail(for: library.items[1])?.1 != key }
        let rewritten = try #require(library.storeThumbnail(for: library.items[1])?.1)
        #expect(rewritten != key, "the photo rewritten with other pixels shows its new key")
    }

    @Test func `a folder the library hasn't indexed is listed, then shown from the library without a jump`(
    ) async throws {
        defer { cleanUp() }
        let names = ["IMG_1.JPG", "IMG_2.JPG", "IMG_3.JPG", "Sub/IMG_4.JPG"]
        try photos(names)
        let written = Date()
        try SidecarStore().save(
            Sidecar(recipe: Self.edited, metadata: PhotoMetadata(rating: 2)),
            for: photo("IMG_2.JPG"),
        )
        let library = FolderLibrary()
        // Long settled while listed, whenever the disk watcher lists the folder again; written a
        // moment ago once the library shows it (below).
        library.clock = { written.addingTimeInterval(3600) }
        library.add([root])
        library.setIncludesSubfolders(true)
        var diffs: [LibraryDiff] = []
        let observation = library.observe { diffs.append($0) }
        defer { observation.invalidate() }
        library.open(root)
        library.attach(service(library))
        try await eventually { !library.isListing && library.item(for: photo("IMG_2.JPG"))?.hasEdits == true }
        #expect(!library.isShownFromLibrary, "listed as before while the library indexes it")
        let listed = library.items
        let resets = diffs.filter(\.reset).count

        try await eventually { library.isShownFromLibrary }
        #expect(diffs.filter(\.reset).count == resets, "no reset: the filmstrip keeps its place")
        #expect(library.items == listed, "the same photos, with the same dates and badges")

        // The library rereads the photos, unchanged, then one badge changes after them.
        library.clock = { written }
        #expect(names.allSatisfy { name in
            library.item(for: photo(name)).map { FolderLibrary.isSettling($0.modified, at: written) } == true
        }, "inside the settle window from now on")
        for name in names where name != "IMG_2.JPG" {
            library.sidecarSaved(photo(name))
        }
        try SidecarStore().save(
            Sidecar(recipe: Self.edited, metadata: PhotoMetadata(rating: 4)),
            for: photo("IMG_2.JPG"),
        )
        library.sidecarSaved(photo("IMG_2.JPG"))
        try await eventually { library.item(for: photo("IMG_2.JPG"))?.metadata.rating == 4 }
        #expect(
            library.items.map(\.isSettling) == listed.map(\.isSettling),
            "an unchanged photo keeps the settle state the filmstrip showed",
        )
        #expect(
            library.items.filter { $0.name != "IMG_2.JPG" } == listed.filter { $0.name != "IMG_2.JPG" },
            "only the photo whose badge changed changes",
        )
    }

    @Test func `with the library off, or its index unable to open, Folders lists folders as before`() async throws {
        defer { cleanUp() }
        #expect(LibraryService.isEnabled(defaults), "on unless the defaults say otherwise")
        defaults.set(false, forKey: LibraryService.enabledKey)
        #expect(!LibraryService.isEnabled(defaults))

        try photos(["IMG_1.JPG", "IMG_2.JPG"])
        try Data().write(to: base.appending(path: "Blocked"))
        let library = FolderLibrary()
        library.add([root])
        let service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Blocked/Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars,
        ) { _, _ in nil }
        library.attach(service)
        try await eventually { service.state != .opening }
        guard case .unavailable = service.state else {
            Issue.record("an index that can't be made opened: \(service.state)")
            return
        }
        library.open(root)
        try await eventually { !library.isListing && library.count == 2 }
        #expect(library.count == 2 && !library.isShownFromLibrary)
        #expect(library.sidecars.store(for: photo("IMG_1.JPG")).locator == .besidePhotos)
    }

    @Test func `an edit on a folder kept on this Mac is saved there, and opens from there next time`() async throws {
        defer { cleanUp() }
        try photos(["IMG_1.JPG"])
        let photo = photo("IMG_1.JPG")
        let (library, service) = try await indexedLibrary(defaults: defaults)
        let core = try #require(service.core)
        let path = LibraryService.path(root)
        let id = try #require(try await core.index.read { try $0.root(path: path)?.id })
        try await core.sidecars.setPlacement(.onThisMac, forRoot: id)
        await service.placementsChanged()
        let onThisMac = try #require(library.sidecars.locator.onThisMac(photo))
        #expect(onThisMac.path.hasPrefix(paths.sidecars.path))

        let model = EditorModel(engine: StubEngine(), library: library)
        try await open(photo, in: model)
        model.setValue(.exposure, 0.8)
        model.saveNow()
        await model.saves.flush()
        try await eventually { FileManager.default.fileExists(atPath: onThisMac.path) }
        #expect(FileManager.default.fileExists(atPath: onThisMac.path))
        #expect(!FileManager.default.fileExists(atPath: SidecarLocator.besidePhoto(photo).path), "nothing beside it")
        service.close()

        // The next launch opens the photo before the index is open: the locator kept in the defaults
        // finds its edit.
        let relaunched = FolderLibrary()
        relaunched.add([root])
        relaunched.attach(self.service(relaunched, defaults: defaults))
        let reopened = EditorModel(engine: StubEngine(), library: relaunched)
        try await open(photo, in: reopened)
        #expect(reopened.recipe[.exposure] == 0.8)
        #expect(SidecarStore().load(for: photo) == nil, "a photo outside the library's folders reads beside it")
    }

    @Test func `an indexed folder's thumbnails come from the store, not the photos or the folder's pack`() async throws {
        defer { cleanUp() }
        try photos(["IMG_1.JPG", "IMG_2.JPG"])
        let (library, service) = try await indexedLibrary()
        library.open(root)
        try await eventually { library.isShownFromLibrary && !library.isListing }
        let decodes = Mutex(0)
        let packs = ThumbnailPacks(directory: base.appending(path: "Packs", directoryHint: .isDirectory))
        let loader = ThumbnailLoader(packs: packs) { _, _ in
            decodes.withLock { $0 += 1 }
            return nil
        }
        loader.library = { library.storeThumbnail(for: $0) }
        for item in library.items {
            let image = try #require(await loader.image(for: item))
            #expect(max(image.width, image.height) <= ThumbnailLoader.pixelSize)
            let key = try #require(library.storeThumbnail(for: item)?.1)
            #expect(service.thumbnails?.store.contains(key, tier: .grid) == true)
            #expect(!packs.contains(item.url, size: item.size, modified: item.modified))
        }
        #expect(decodes.withLock { $0 } == 0, "nothing decoded from the photos themselves")
        #expect(loader.cachedCount == 2)
    }

    @Test func `the library opens without holding up launch, and Folders lists folders meanwhile`() async throws {
        defer { cleanUp() }
        try photos(["IMG_1.JPG", "IMG_2.JPG", "IMG_3.JPG"])
        // Another connection holds the index's write lock: opening it waits.
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let holder = try SQLiteDatabase(path: paths.index.path)
        try holder.execute("PRAGMA journal_mode = WAL")
        try holder.execute("BEGIN EXCLUSIVE")

        let library = FolderLibrary()
        library.add([root])
        let service = service(library)
        let started = ContinuousClock.now
        library.attach(service)
        // Well under the index's busy timeout of 5 s, which an open on the main thread would wait out.
        #expect(ContinuousClock.now - started < .seconds(1), "attaching returns at once")
        library.open(root)
        try await eventually { !library.isListing && library.count == 3 }
        #expect(library.count == 3 && !library.isShownFromLibrary, "listed as before")
        #expect(service.state == .opening)

        try holder.execute("COMMIT")
        try await eventually { service.isReady }
        #expect(service.isReady)
        try await eventually { library.isShownFromLibrary }
        #expect(library.isShownFromLibrary)
    }
}
