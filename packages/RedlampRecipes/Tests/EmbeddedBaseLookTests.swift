import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampRecipes

/// Looks baked from photos' camera profiles (TON-09) are kept here but never shared.
struct EmbeddedBaseLookTests {
    @Test func `an exported recipe carries an installed look but not a photo's embedded one`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "redlamp-embedded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecipeLibrary(root: root, includeBundled: false)
        let table = try LookTable(size: 3, space: .sceneLog) { $0 * 0.9 }
        let embedded = BaseLookPackage(
            id: BaseLookReference.embeddedIDPrefix + "0011223344556677",
            name: "Adobe Standard",
            table: table,
        )
        let installed = BaseLookPackage(id: "local/look", name: "Mine", table: table)
        try library.lookStore.save(embedded)
        try library.lookStore.save(installed)
        library.reload()
        #expect(embedded.reference.isEmbedded && !installed.reference.isEmbedded)
        #expect(library.isAvailable(embedded.reference))

        var recipe = LookTableImport.recipe(for: table, name: "Test")
        recipe.embeddedBaseLooks = []
        recipe.baseLook = embedded.reference
        #expect(library.exportable(recipe).embeddedBaseLooks.isEmpty)
        recipe.baseLook = installed.reference
        #expect(library.exportable(recipe).embeddedBaseLooks.map(\.id) == [installed.id])
    }
}
