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

    @Test func `launch registers every look the library has, reading none of their tables`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine()
        let catalog = try catalog(engine)
        #expect(engine.registeredLooks.isEmpty)
        let sources = engine.lookSources
        let read = sources.compactMap { $0.load() }
        #expect(read.count == sources.count)
        #expect(Set(read) == Set(catalog.baseLooks.compactMap { try? $0.definition() }))
        #expect(zip(sources, read).allSatisfy { $0.reference == $1.reference && $0.parameters == $1.parameters })
    }

    @Test func `toggling a favourite registers nothing`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine()
        let catalog = try catalog(engine)
        let recipe = try #require(catalog.save(Recipe(
            id: "user/test/plain", name: "Plain", group: "Mine", includes: [.tone], settings: RecipeSettings(),
        )))
        let before = engine.lookSources.count
        catalog.setFavorite(recipe, true)
        catalog.setFavorite(recipe, false)
        #expect(engine.lookSources.count == before)
    }

    @Test func `adding a look registers that look alone`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine()
        let catalog = try catalog(engine)
        let before = engine.lookSources.count
        let look = try grey(0.5)
        catalog.remember(look)
        #expect(engine.lookSources.count == before + 1)
        #expect(engine.lookSources.last?.load() == look)

        let changed = try grey(0.25)
        catalog.remember(changed)
        #expect(engine.lookSources.count == before + 2)
        #expect(engine.lookSources.last?.load() == changed)
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
