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
        let first = try Data(contentsOf: store.url(for: image))

        try store.save(Sidecar(recipe: recipe, modified: Date(timeIntervalSince1970: 2000)), for: image)
        #expect(try Data(contentsOf: store.url(for: image)) == first)

        recipe[.exposure] = 1
        try store.save(Sidecar(recipe: recipe, modified: Date(timeIntervalSince1970: 3000)), for: image)
        #expect(try Data(contentsOf: store.url(for: image)) != first)
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

        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.url(for: image)))
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

        #expect(store.isWrittenByNewerVersion(for: image))
        #expect(store.load(for: image)?.recipe.requiresNewerProcess == true)
        #expect(throws: SidecarStoreError.writtenByNewerVersion(store.url(for: image))) {
            try store.save(Sidecar(recipe: EditRecipe()), for: image)
        }
        store.delete(for: image)
        #expect(try Data(contentsOf: store.url(for: image)) == Data(json.utf8))
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
        let written = try String(contentsOf: store.url(for: image), encoding: .utf8)
        #expect(written.contains(#""baseLook""#))
        #expect(written.contains(#""redlamp/base/vivid""#))
        #expect(!written.contains(#""profile""#))
    }

    private func temporaryImage() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "IMG_0001.ARW"), { try? FileManager.default.removeItem(at: directory) })
    }
}
