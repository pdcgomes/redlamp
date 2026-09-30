import Foundation
import RedlampEngineAPI
import RedlampRecipes
import simd
import Testing

struct RecipeFormatTests {
    private func sample() throws -> Recipe {
        let table = try LookTable(size: 5) { c in SIMD3(c.x * 0.9 + 0.05, c.y, c.z * 0.95) }
        let look = BaseLookPackage(id: "local/test/look", name: "Test Look", parameters: .identity, table: table)
        return Recipe(
            id: "local/test", name: "Test", group: "Tests", tags: ["a"],
            includes: [.tone, .baseLook, .effects],
            settings: RecipeSettings(values: [.contrast: 20, .grainAmount: 15]),
            baseLook: look.reference, embeddedBaseLooks: [look],
        )
    }

    @Test func `round trips through a file`() throws {
        let recipe = try sample()
        let data = try RecipeFile.encode(recipe)
        let (decoded, issues) = try RecipeValidator.decode(data)
        #expect(decoded == recipe)
        #expect(issues.isEmpty)
        #expect(try decoded.embeddedBaseLooks[0].definition().table == recipe.embeddedBaseLooks[0].definition().table)
    }

    @Test func `unknown fields and parameters survive and are reported`() throws {
        let json = #"""
        {"format":1,"id":"local/x","version":1,"name":"X","includes":["tone","futureGroup"],
         "settings":{"values":{"basic.contrast":10,"future.param":3}},"futureField":{"a":1}}
        """#
        let (recipe, issues) = try RecipeValidator.decode(Data(json.utf8))
        #expect(recipe.requiresNewerRedlamp)
        #expect(issues.count == 3)
        let again = try RecipeValidator.decode(RecipeFile.encode(recipe)).recipe
        #expect(again.settings.unknownValues == ["future.param": 3])
        #expect(again.settings.unknownIncludes == ["futureGroup"])
        let text = try String(data: RecipeFile.encode(again), encoding: .utf8) ?? ""
        #expect(text.contains("futureField"))
    }

    @Test func `values are clamped and foreign settings dropped`() throws {
        let json = #"""
        {"id":"local/x","name":"X","includes":["tone"],
         "settings":{"values":{"basic.contrast":500,"lens.distortion":20,"mixer.hue.red":10}}}
        """#
        let (recipe, issues) = try RecipeValidator.decode(Data(json.utf8))
        #expect(recipe.settings.values == [.contrast: 100])
        #expect(issues.allSatisfy { $0.severity == .warning })
        #expect(issues.count == 3)
    }

    @Test func `the redlamp namespace is reserved`() throws {
        let json = #"{"id":"redlamp/fake","name":"Fake","includes":[]}"#
        #expect(throws: RecipeValidationError.self) { try RecipeValidator.decode(Data(json.utf8)) }
        #expect(try RecipeValidator.decode(Data(json.utf8), origin: .bundled).recipe.id == "redlamp/fake")
        #expect(throws: RecipeValidationError.self) {
            try RecipeValidator.decode(Data(#"{"id":"Bad ID","name":"x"}"#.utf8))
        }
    }

    @Test func `a tampered look table is rejected`() throws {
        var recipe = try sample()
        recipe.embeddedBaseLooks[0].table?.sha256 = String(repeating: "0", count: 64)
        #expect(throws: RecipeValidationError.self) { try RecipeValidator.decode(RecipeFile.encode(recipe)) }
    }

    @Test func `applying sets included groups and leaves the rest`() throws {
        var edit = EditRecipe()
        edit[.exposure] = 1
        edit[.shadows] = 40
        edit[.vibrance] = 30
        let recipe = try sample()
        let applied = recipe.apply(to: edit)
        #expect(applied[.contrast] == 20)
        #expect(applied[.grainAmount] == 15)
        // Tone is included, so unlisted tone values return to their defaults...
        #expect(applied[.exposure] == 0)
        #expect(applied[.shadows] == 0)
        // ...while presence isn't, so vibrance stays.
        #expect(applied[.vibrance] == 30)
        #expect(applied.baseLook == recipe.baseLook)
        #expect(applied.appliedRecipe == AppliedRecipe(id: "local/test", version: 1, name: "Test", amount: 100))
    }

    @Test func `amount interpolates from the current edit`() throws {
        var edit = EditRecipe()
        edit[.contrast] = 10
        let recipe = try sample()
        #expect(recipe.apply(to: edit, amount: 0) == edit)
        #expect(recipe.apply(to: edit, amount: 50)[.contrast] == 15)
        #expect(recipe.apply(to: edit, amount: 200)[.contrast] == 30)
        #expect(recipe.apply(to: edit, amount: 50).baseLook.amount == 50)
    }

    @Test func `temperature blends in mireds`() {
        var edit = EditRecipe()
        edit[.temperature] = 4000
        let recipe = Recipe(
            id: "local/wb", name: "WB", group: "", includes: [.whiteBalance],
            settings: RecipeSettings(values: [.temperature: 8000], whiteBalanceMode: .custom),
        )
        let half = recipe.apply(to: edit, amount: 50)[.temperature]
        #expect(abs(half - 1e6 / ((250 + 125) / 2)) < 1)
    }

    @Test func `capture keeps only the chosen groups`() {
        var edit = EditRecipe()
        edit[.contrast] = 30
        edit[.temperature] = 7000
        edit[.vignetteAmount] = -20
        let recipe = Recipe.capture(edit, name: "Mine", includes: [.tone, .effects])
        #expect(recipe.isLocal)
        #expect(recipe.settings.values == [.contrast: 30, .vignetteAmount: -20])
        #expect(recipe.baseLook == nil)
    }

    @Test func `legacy profile ids migrate to base looks`() throws {
        let json = #"{"version":1,"profile":{"id":"redlamp.portrait","name":"Redlamp Portrait","amount":100}}"#
        let edit = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(edit.baseLook == BuiltInBaseLook.portrait.reference)
        let encoded = try String(data: JSONEncoder().encode(edit), encoding: .utf8) ?? ""
        #expect(encoded.contains("baseLook"))
        #expect(!encoded.contains("\"profile\""))
    }
}

struct LookTableTests {
    @Test func `hashes pin the content`() throws {
        let a = LookTable.identity(size: 9)
        let b = try LookTable(size: 9) { $0 }
        #expect(a.contentHash == b.contentHash)
        let c = try LookTable(size: 9) { SIMD3($0.x, $0.y, $0.z * 0.99) }
        #expect(a.contentHash != c.contentHash)
        #expect(try LookTable(size: 9, littleEndianBytes: c.littleEndianBytes) == c)
    }

    @Test func `tetrahedral sampling reproduces the grid and identity`() throws {
        let identity = LookTable.identity(size: 17)
        for probe in [SIMD3<Float>(0.1, 0.5, 0.9), SIMD3(0.33, 0.33, 0.33), SIMD3(1, 0, 0.5)] {
            #expect(simd_distance(identity.sample(probe), probe) < 2e-3)
        }
        let table = try LookTable(size: 5) { SIMD3($0.y, $0.z, $0.x) }
        #expect(simd_distance(table.sample(SIMD3(0.25, 0.5, 0.75)), SIMD3(0.5, 0.75, 0.25)) < 2e-3)
    }

    @Test func `invalid tables are refused`() {
        #expect(throws: LookTable.TableError.self) { try LookTable(size: 1, floats: [0, 0, 0]) }
        #expect(throws: LookTable.TableError.self) {
            try LookTable(size: 2, floats: [Float](repeating: .nan, count: 24))
        }
    }

    @Test func `cube files import, with sRGB adapted into Redlamp's space`() throws {
        var lines = ["TITLE \"Swap\"", "LUT_3D_SIZE 2"]
        for b in 0 ..< 2 {
            for g in 0 ..< 2 {
                for r in 0 ..< 2 {
                    lines.append("\(r) \(g) \(b)")
                }
            }
        }
        let native = try LookTableImport.parseCube(lines.joined(separator: "\n"), space: .displayRec2020)
        #expect(native.title == "Swap")
        #expect(native.table.isIdentity)
        let adapted = try LookTableImport.parseCube(lines.joined(separator: "\n"), space: .sRGB)
        // An identity table stays an identity after converting spaces in and out.
        let probe = SIMD3<Float>(0.4, 0.5, 0.6)
        #expect(simd_distance(adapted.table.sample(probe), probe) < 5e-3)
        #expect(throws: LookTableImportError.self) { try LookTableImport.parseCube("LUT_3D_SIZE 3\n0 0 0") }
    }

    @Test func `hald identity round trips`() throws {
        let identity = try #require(LookTableImport.haldIdentity(level: 4))
        #expect(identity.width == 64)
        let table = try LookTableImport.parseHald(identity, space: .displayRec2020)
        #expect(table.size == 16)
        #expect(table.isIdentity)
    }
}
