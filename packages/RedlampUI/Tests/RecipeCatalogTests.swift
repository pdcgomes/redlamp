import Foundation
import RedlampEngineAPI
import RedlampRecipes
import Testing
@_spi(Harness) @testable import RedlampUI

/// The catalog keeps the engine's Base Looks in step with the library, registering only
/// what a change adds.
@MainActor
struct RecipeCatalogTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "recipe-catalog-\(UUID().uuidString)")

    private func catalog(_ engine: StubEngine) throws -> RecipeCatalog {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return RecipeCatalog(engine: engine, library: RecipeLibrary(root: root, includeBundled: false))
    }

    private func grey(_ value: Float, id: String = "local/test/grey") throws -> BaseLookDefinition {
        try BaseLookDefinition(
            id: id, version: 1, name: "Grey", parameters: .identity,
            table: LookTable(size: 3) { _ in SIMD3(repeating: value) },
        )
    }

    @Test func `launch registers every look the library has`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine()
        let catalog = try catalog(engine)
        let registered = Set(engine.registeredLooks.map(\.reference))
        #expect(registered == Set(catalog.baseLooks.compactMap { try? $0.definition().reference }))
    }

    @Test func `toggling a favourite registers nothing`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine()
        let catalog = try catalog(engine)
        let recipe = try #require(catalog.save(Recipe(
            id: "user/test/plain", name: "Plain", group: "Mine", includes: [.tone], settings: RecipeSettings(),
        )))
        let before = engine.registeredLooks.count
        catalog.setFavorite(recipe, true)
        catalog.setFavorite(recipe, false)
        #expect(engine.registeredLooks.count == before)
    }

    @Test func `adding a look registers that look alone`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine()
        let catalog = try catalog(engine)
        let before = engine.registeredLooks.count
        let look = try grey(0.5)
        catalog.remember(look)
        #expect(engine.registeredLooks.count == before + 1)
        #expect(engine.registeredLooks.last == look)

        let changed = try grey(0.25)
        catalog.remember(changed)
        #expect(engine.registeredLooks.count == before + 2)
        #expect(engine.registeredLooks.last == changed)
    }

    @Test func `previewing a recipe again registers its embedded look once`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine()
        let catalog = try catalog(engine)
        let look = try grey(0.5, id: "local/test/embedded")
        let recipe = Recipe(
            id: "user/test/embedded", name: "Embedded", group: "Mine", includes: [.tone], settings: RecipeSettings(),
            baseLook: look.reference,
            embeddedBaseLooks: [BaseLookPackage(id: look.id, name: look.name, table: look.table)],
        )
        let before = engine.registeredLooks.count
        catalog.prepare(recipe)
        catalog.prepare(recipe)
        #expect(engine.registeredLooks.count == before + 1)
    }
}
