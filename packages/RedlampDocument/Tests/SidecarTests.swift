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

    @Test func `presets only touch what they set`() throws {
        var recipe = EditRecipe()
        recipe[.exposure] = 1
        let preset = try #require(BuiltInPresets.all.first { $0.id == "bw.contrast" })
        let applied = preset.apply(to: recipe)
        #expect(applied[.exposure] == 1)
        #expect(applied.treatment == .blackAndWhite)
        #expect(applied[.contrast] == 40)
    }
}
