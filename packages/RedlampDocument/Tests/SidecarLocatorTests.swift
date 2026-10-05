import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

struct SidecarLocatorTests {
    /// A folder of photos and a folder for sidecars kept on this Mac, side by side.
    private struct Sandbox {
        let directory: URL

        var photos: URL {
            directory.appending(path: "Photos", directoryHint: .isDirectory)
        }

        var mac: URL {
            directory.appending(path: "Sidecars", directoryHint: .isDirectory)
        }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "sidecar-locator-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        /// An empty photo at `path` below `photos`.
        func photo(_ path: String) throws -> URL {
            let url = photos.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try Data().write(to: url)
            return url
        }

        func locator(onThisMac: Bool) -> SidecarLocator {
            SidecarLocator(folder: mac, roots: [
                SidecarLocator.Root(
                    path: photos.path,
                    volume: "VOLUME-1",
                    pathInVolume: "Shoots",
                    onThisMac: onThisMac,
                ),
            ])
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Every file in the package at `url`, by its path inside it, with its bytes.
    private static func files(in url: URL) throws -> [String: Data] {
        let paths = try #require(FileManager.default.subpathsOfDirectory(atPath: url.path) as [String]?)
        var files: [String: Data] = [:]
        for path in paths {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.appending(path: path).path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                files[path] = try Data(contentsOf: url.appending(path: path))
            }
        }
        return files
    }

    private static func sidecar(rating: Int, at seconds: TimeInterval) -> Sidecar {
        var recipe = EditRecipe()
        recipe[.exposure] = 0.25 * Double(rating)
        return Sidecar(
            recipe: recipe, metadata: PhotoMetadata(rating: rating), modified: Date(timeIntervalSince1970: seconds),
        )
    }

    @Test func `SidecarStore() keeps every sidecar beside its photo, with the bytes it always wrote`() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let image = try sandbox.photo("Day 1/IMG_0001.ARW")
        let store = SidecarStore()
        #expect(store.locator == .besidePhotos)
        #expect(store.url(for: image) == image.appendingPathExtension("redlamp"))
        #expect(store.editURL(for: image) == image.appendingPathExtension("redlamp"))

        let sample = SidecarSamples.everything
        try store.save(sample, for: image)
        let written = try Self.files(in: image.appendingPathExtension("redlamp"))
        let golden = try JSONEncoder.sidecar.encode(
            JSONDecoder().decode(JSONValue.self, from: Data(SidecarGoldenTests.everything.utf8)),
        )
        #expect(written[SidecarStore.editFile] == golden)
        let bitmaps = (sample.recipe.maskBitmaps + sample.snapshots.flatMap(\.recipe.maskBitmaps))
            .filter { $0.png != nil }
        #expect(!bitmaps.isEmpty)
        for bitmap in bitmaps {
            #expect(written["\(SidecarStore.masksDirectory)/\(bitmap.sha256).png"] == bitmap.png)
        }
        #expect(written.count == 1 + Set(bitmaps.map(\.sha256)).count)
        #expect(store.load(for: image)?.hasSameContent(as: sample) == true)
        #expect(!FileManager.default.fileExists(atPath: sandbox.mac.path))

        // A locator that knows no folder, or one that keeps them beside, writes the same files.
        let other = try sandbox.photo("Day 2/IMG_0002.ARW")
        try SidecarStore(locator: sandbox.locator(onThisMac: false)).save(sample, for: other)
        #expect(try Self.files(in: other.appendingPathExtension("redlamp")) == written)
        #expect(!FileManager.default.fileExists(atPath: sandbox.mac.path))
    }

    @Test func `SidecarStore(locator:) writes on this Mac and reads beside the photo first`() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let image = try sandbox.photo("DCIM 100/IMG 0001.ARW")
        let beside = image.appendingPathExtension("redlamp")
        let mac = sandbox.mac.appending(path: "VOLUME-1/Shoots/DCIM 100/IMG 0001.ARW.redlamp")
        let store = SidecarStore(locator: sandbox.locator(onThisMac: true))
        #expect(store.url(for: image) == mac)

        try store.save(Self.sidecar(rating: 4, at: 2000), for: image)
        #expect(FileManager.default.fileExists(atPath: mac.appending(path: SidecarStore.editFile).path))
        #expect(!FileManager.default.fileExists(atPath: beside.path))
        #expect(store.load(for: image)?.metadata?.rating == 4)
        #expect(store.summary(for: image)?.metadata.rating == 4)
        // The same bytes as beside the photo.
        let elsewhere = try sandbox.photo("Elsewhere/IMG 0001.ARW")
        try SidecarStore().save(Self.sidecar(rating: 4, at: 2000), for: elsewhere)
        #expect(try Self.files(in: mac) == Self.files(in: elsewhere.appendingPathExtension("redlamp")))

        // One beside the photo, saved at the same moment, is read first.
        try SidecarStore().save(Self.sidecar(rating: 2, at: 2000), for: image)
        #expect(store.locator.readURL(for: image) == beside)
        #expect(store.load(for: image)?.metadata?.rating == 2)
        #expect(store.summary(for: image)?.metadata.rating == 2)

        // Saved here since, this Mac's is read.
        try store.save(Self.sidecar(rating: 5, at: 3000), for: image)
        #expect(store.locator.readURL(for: image) == mac)
        #expect(store.load(for: image)?.metadata?.rating == 5)
        #expect(store.summary(for: image)?.metadata.rating == 5)
        #expect(SidecarStore().load(for: image)?.metadata?.rating == 2)

        // A folder that keeps them beside its photos writes there, and still reads one left on this Mac.
        let moved = try sandbox.photo("DCIM 100/IMG 0002.ARW")
        try store.save(Self.sidecar(rating: 3, at: 2000), for: moved)
        let besideStore = SidecarStore(locator: sandbox.locator(onThisMac: false))
        #expect(besideStore.url(for: moved) == moved.appendingPathExtension("redlamp"))
        #expect(besideStore.load(for: moved)?.metadata?.rating == 3)
        #expect(besideStore.summary(for: moved)?.metadata.rating == 3)
        #expect(SidecarStore().load(for: moved) == nil)
    }

    @Test func `a sidecar on this Mac is kept by its volume and its path from the volume's root`() {
        let folder = URL(fileURLWithPath: "/Library/Redlamp/Sidecars", isDirectory: true)
        let locator = SidecarLocator(folder: folder, roots: [
            .init(path: "/Volumes/Card Été", volume: "8E2C-0001", pathInVolume: "", onThisMac: true),
            .init(
                path: "/Users/me/Pictures/Client Shoots/", volume: "1BEA-0002",
                pathInVolume: "/Users/me/Pictures/Client Shoots/", onThisMac: true,
            ),
            .init(path: "/Users/me/Pictures", volume: "1BEA-0002", pathInVolume: "Users/me/Pictures", onThisMac: false),
            .init(path: "/Volumes/NAS/Archive", volume: "name:NAS/2", pathInVolume: "Archive", onThisMac: true),
        ])

        let card = URL(fileURLWithPath: "/Volumes/Card Été/DCIM/100 MSDCF/Café ⌘ 1.ARW")
        #expect(locator.onThisMac(card)?
            .path == "/Library/Redlamp/Sidecars/8E2C-0001/DCIM/100 MSDCF/Café ⌘ 1.ARW.redlamp")
        #expect(locator.url(for: card) == locator.onThisMac(card))
        // The same folder spelt with decomposed accents, as some volumes list it.
        let decomposed = URL(fileURLWithPath: "/Volumes/Card E\u{301}te\u{301}/DCIM/IMG_0002.ARW")
        #expect(locator.onThisMac(decomposed)?.lastPathComponent == "IMG_0002.ARW.redlamp")
        #expect(locator.onThisMac(decomposed)?.deletingLastPathComponent().path
            == "/Library/Redlamp/Sidecars/8E2C-0001/DCIM")

        // The deepest folder decides, by its own path in the volume.
        let shoot = URL(fileURLWithPath: "/Users/me/Pictures/Client Shoots/Acme/A 1.CR3")
        #expect(locator.url(for: shoot).path
            == "/Library/Redlamp/Sidecars/1BEA-0002/Users/me/Pictures/Client Shoots/Acme/A 1.CR3.redlamp")
        let holiday = URL(fileURLWithPath: "/Users/me/Pictures/Holiday/B.NEF")
        #expect(locator.url(for: holiday) == holiday.appendingPathExtension("redlamp"))
        #expect(locator.onThisMac(holiday)?
            .path == "/Library/Redlamp/Sidecars/1BEA-0002/Users/me/Pictures/Holiday/B.NEF.redlamp")

        // A volume named rather than identified stays one folder.
        let archived = URL(fileURLWithPath: "/Volumes/NAS/Archive/2019/C.RAF")
        #expect(locator.url(for: archived).path == "/Library/Redlamp/Sidecars/name:NAS:2/Archive/2019/C.RAF.redlamp")

        // Outside every folder it knows, and a folder's name that only starts the same, beside the photo.
        for outside in ["/Volumes/Card Été 2/IMG_0003.ARW", "/Volumes/Other/IMG_0004.ARW", "/Volumes/Card Été"] {
            let url = URL(fileURLWithPath: outside)
            #expect(locator.onThisMac(url) == nil)
            #expect(locator.url(for: url) == url.appendingPathExtension("redlamp"))
            #expect(locator.readURL(for: url) == url.appendingPathExtension("redlamp"))
        }
        #expect(SidecarLocator.besidePhotos.onThisMac(card) == nil)
        #expect(SidecarLocator.besidePhotos.url(for: card) == card.appendingPathExtension("redlamp"))
    }

    @Test func `a folder at the volume's root keeps every photo's path from it`() {
        let folder = URL(fileURLWithPath: "/Sidecars", isDirectory: true)
        let locator = SidecarLocator(folder: folder, roots: [
            .init(path: "/", volume: "BOOT", pathInVolume: "", onThisMac: true),
        ])
        #expect(locator.url(for: URL(fileURLWithPath: "/Users/me/D.JPG"))
            .path == "/Sidecars/BOOT/Users/me/D.JPG.redlamp")
    }
}
