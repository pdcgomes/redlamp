import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing

struct SidecarTests {
    @Test func `round trips through disk`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appending(path: "IMG_0001.ARW")

        var recipe = EditRecipe()
        recipe[.exposure] = 0.75
        let sidecar = Sidecar(recipe: recipe, snapshots: [Snapshot(name: "Before grade", recipe: EditRecipe())])
        let store = SidecarStore()
        try store.save(sidecar, for: image)

        #expect(store.url(for: image).lastPathComponent == "IMG_0001.ARW.redlamp")
        let loaded = try #require(store.load(for: image))
        #expect(loaded.recipe == recipe)
        #expect(loaded.snapshots.count == 1)
    }

    @Test func `unchanged edits are not rewritten`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        let store = SidecarStore()
        try store.save(Sidecar(recipe: recipe, modified: Date(timeIntervalSince1970: 1000)), for: image)
        let first = try Data(contentsOf: store.editURL(for: image))

        try store.save(Sidecar(recipe: recipe, modified: Date(timeIntervalSince1970: 2000)), for: image)
        #expect(try Data(contentsOf: store.editURL(for: image)) == first)

        recipe[.exposure] = 1
        try store.save(Sidecar(recipe: recipe, modified: Date(timeIntervalSince1970: 3000)), for: image)
        #expect(try Data(contentsOf: store.editURL(for: image)) != first)
    }

    /// Dates are written in whole seconds, while a snapshot or AI mask made a moment ago has a
    /// fraction of one.
    @Test func `an edit with dates finer than a second is not rewritten`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        var recipe = EditRecipe()
        recipe.masks = [subjectMask(Data("png".utf8), createdAt: Date(timeIntervalSince1970: 1000.25))]
        let snapshot = Snapshot(name: "Before", created: Date(timeIntervalSince1970: 1000.75), recipe: EditRecipe())
        let sidecar = Sidecar(recipe: recipe, snapshots: [snapshot])
        try store.save(sidecar, for: image)
        let first = try fileNumber(store.editURL(for: image))

        try store.save(sidecar, for: image)
        #expect(try fileNumber(store.editURL(for: image)) == first)
    }

    @Test func `saving keeps fields a newer version added`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = #"""
        {"format":"app.redlamp.edit","modified":"2026-09-30T08:00:00Z","snapshots":[],
         "versions":[{"name":"Alt"}],
         "recipe":{"version":1,"processVersion":1,"values":{"basic.exposure":0.5,"future.parameter":3}}}
        """#
        try Data(json.utf8).write(to: store.url(for: image))

        // The editor builds a fresh sidecar from its current recipe on every save.
        var recipe = try #require(store.load(for: image)).recipe
        recipe[.exposure] = 1
        try store.save(Sidecar(recipe: recipe), for: image)

        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        guard case let .object(root) = written,
              case let .object(savedRecipe) = root["recipe"],
              case let .object(values) = savedRecipe["values"]
        else {
            Issue.record("sidecar did not encode as an object")
            return
        }
        #expect(root["versions"] == .array([.object(["name": .string("Alt")])]))
        #expect(values["future.parameter"] == .number(3))
        #expect(values["basic.exposure"] == .number(1))
    }

    @Test func `sidecars from a newer version are read only`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":99}}"#
        try Data(json.utf8).write(to: store.url(for: image))

        #expect(store.protection(for: image) == .writtenByNewerVersion)
        #expect(store.load(for: image)?.recipe.requiresNewerProcess == true)
        #expect(throws: SidecarStoreError.writtenByNewerVersion(store.url(for: image))) {
            try store.save(Sidecar(recipe: EditRecipe()), for: image)
        }
        store.delete(for: image)
        #expect(try Data(contentsOf: store.editURL(for: image)) == Data(json.utf8))
    }

    /// A sidecar this build can't decode (damaged, or an unknown value) may still hold an edit, its
    /// history and masks: it is never saved over or deleted, as a newer one isn't.
    @Test(arguments: [
        #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":9,"values":{"basic.exposure":"high"}}}"#,
    ])
    func `sidecars that can't be read are read only`(json: String) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try Data(json.utf8).write(to: store.url(for: image))

        #expect(store.load(for: image) == nil)
        #expect(store.protection(for: image) == .unreadable)
        #expect(throws: SidecarStoreError.unreadable(store.url(for: image))) {
            try store.save(Sidecar(recipe: EditRecipe()), for: image)
        }
        store.delete(for: image)
        #expect(try Data(contentsOf: store.editURL(for: image)) == Data(json.utf8))
    }

    @Test func `a missing or readable sidecar isn't read only`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        #expect(store.protection(for: image) == nil)
        try store.save(Sidecar(recipe: EditRecipe()), for: image)
        #expect(store.protection(for: image) == nil)
    }

    @Test func `format 1 profiles read as base looks and are written back as format 2`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let json = #"""
        {"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,
         "profile":{"id":"redlamp.vivid","name":"Redlamp Vivid","amount":80}}}
        """#
        try Data(json.utf8).write(to: SidecarStore().url(for: image))
        let store = SidecarStore()
        let loaded = try #require(store.load(for: image))
        #expect(loaded.recipe.baseLook == BuiltInBaseLook.vivid.reference.withAmount(80))
        var edited = loaded
        edited.recipe[.exposure] = 0.5
        try store.save(edited, for: image)
        let written = try String(contentsOf: store.editURL(for: image), encoding: .utf8)
        #expect(written.contains(#""baseLook""#))
        #expect(written.contains(#""redlamp/base/vivid""#))
        #expect(!written.contains(#""profile""#))
    }

    // MARK: - Packages

    private func subjectMask(_ png: Data, createdAt: Date = Date()) -> MaskLayer {
        MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(png: png, width: 4, height: 2), createdAt: createdAt,
        )))])
    }

    /// The file's inode: an atomic write replaces the file, so a rewrite changes it.
    private func fileNumber(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    }

    @Test func `saves a package with its mask bitmaps`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let png = Data("fake png".utf8)
        var recipe = EditRecipe()
        recipe.masks = [subjectMask(png)]
        try store.save(Sidecar(recipe: recipe), for: image)

        #expect(store.editURL(for: image).lastPathComponent == SidecarStore.editFile)
        let sha = MaskBitmap.hash(png)
        #expect(try Data(contentsOf: store.bitmapURL(sha, for: image)) == png)
        let json = try String(contentsOf: store.editURL(for: image), encoding: .utf8)
        #expect(json.contains(sha))
        #expect(!json.contains(png.base64EncodedString()))

        let loaded = try #require(store.load(for: image))
        #expect(loaded.recipe.maskBitmaps.first?.png == png)
    }

    @Test func `a sidecar is read where it is, by its own path`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let folder = image.deletingLastPathComponent()
        let store = SidecarStore()
        let png = Data("fake png".utf8)
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        recipe.masks = [subjectMask(png)]
        try store.save(Sidecar(recipe: recipe), for: image)
        let package = folder.appending(path: "Copied.redlamp")
        try FileManager.default.copyItem(at: store.url(for: image), to: package)
        let single = folder.appending(path: "Single.redlamp")
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":2,"processVersion":1,"values":{"basic.exposure":0.25}}}"#
        try Data(json.utf8).write(to: single)
        let damaged = folder.appending(path: "Damaged.redlamp")
        try Data("not json".utf8).write(to: damaged)

        let read = try #require(try store.read(sidecarAt: package))
        #expect(read.recipe[.exposure] == 0.5)
        #expect(read.recipe.maskBitmaps.first?.png == png)
        #expect(try store.read(sidecarAt: single)?.recipe[.exposure] == 0.25)
        let error = #expect(throws: SidecarStoreError.self) { try store.read(sidecarAt: damaged) }
        if case .damaged = error {} else {
            Issue.record("a damaged sidecar threw \(String(describing: error))")
        }
        #expect(try store.read(sidecarAt: folder.appending(path: "None.redlamp")) == nil)
    }

    @Test func `a single file sidecar becomes a package on save`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":2,"processVersion":1,"values":{"basic.exposure":0.5}}}"#
        try Data(json.utf8).write(to: store.url(for: image))
        #expect(store.editURL(for: image) == store.url(for: image))

        var sidecar = try #require(store.load(for: image))
        #expect(sidecar.recipe[.exposure] == 0.5)
        sidecar.recipe[.exposure] = 1
        try store.save(sidecar, for: image)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.url(for: image).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(store.load(for: image)?.recipe[.exposure] == 1)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: image.deletingLastPathComponent().path)
        #expect(siblings == ["IMG_0001.ARW.redlamp"])
    }

    @Test func `bitmaps no edit uses are removed`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        var recipe = EditRecipe()
        recipe.masks = [subjectMask(first)]
        let snapshot = Snapshot(name: "Before", recipe: recipe)
        try store.save(Sidecar(recipe: recipe), for: image)

        recipe.masks = [subjectMask(second)]
        try store.save(Sidecar(recipe: recipe, snapshots: [snapshot]), for: image)
        #expect(FileManager.default.fileExists(atPath: store.bitmapURL(MaskBitmap.hash(first), for: image).path))

        try store.save(Sidecar(recipe: recipe), for: image)
        #expect(!FileManager.default.fileExists(atPath: store.bitmapURL(MaskBitmap.hash(first), for: image).path))
        #expect(FileManager.default.fileExists(atPath: store.bitmapURL(MaskBitmap.hash(second), for: image).path))
        #expect(store.load(for: image)?.recipe.maskBitmaps.first?.png == second)
    }

    @Test func `deleting removes the package`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        var recipe = EditRecipe()
        recipe.masks = [subjectMask(Data("x".utf8))]
        try store.save(Sidecar(recipe: recipe), for: image)
        store.delete(for: image)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: image).path))
    }

    /// Rolling back to a build that predates this one: what this build writes, it still reads.
    @Test func `a sidecar this build writes has only fields the previous build reads`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        recipe.masks = [subjectMask(Data("x".utf8))]
        try store.save(Sidecar(
            recipe: recipe,
            snapshots: [Snapshot(name: "Before", recipe: EditRecipe())],
            metadata: PhotoMetadata(rating: 3, flag: .pick, label: .red),
        ), for: image)
        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        guard case let .object(root) = written, case let .object(savedRecipe) = root["recipe"] else {
            Issue.record("sidecar did not encode as an object")
            return
        }
        #expect(Set(root.keys).isSubset(of: ["format", "recipe", "snapshots", "metadata", "modified"]))
        #expect(savedRecipe["version"] == .number(Double(EditRecipe.formatVersion)))
        #expect(store.protection(for: image) == nil)
        let loaded = try #require(store.load(for: image))
        #expect(loaded.recipe[.exposure] == 0.5 && loaded.recipe.masks.count == 1)
        #expect(loaded.snapshots.count == 1 && loaded.metadata == PhotoMetadata(rating: 3, flag: .pick, label: .red))
    }

    private func temporaryImage() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "IMG_0001.ARW"), { try? FileManager.default.removeItem(at: directory) })
    }
}
