import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampRecipes

/// `redlamp recipe build-pack`: writes the bundled film-style Base Looks.
enum StarterPackBuilder {
    static func build(into directory: URL?) throws {
        let folder = directory ?? Repository.root.appendingPathComponent("packages/RedlampRecipes/Resources/BaseLooks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for slot in FilmSlot.allCases {
            let package = try StarterPackLooks.package(for: slot)
            let url = folder.appendingPathComponent("base-\(slot.rawValue).json")
            if let data = try? Data(contentsOf: url),
               let existing = try? RecipeFile.decoder.decode(BaseLookPackage.self, from: data),
               existing.version == package.version, existing.table?.sha256 != package.table?.sha256 {
                throw CLIError(description: """
                \(slot.rawValue): the design changed but the version didn't. Published looks never change; \
                bump StarterPackLooks.version (and the recipes that use it) instead.
                """)
            }
            try RecipeFile.encoder.encode(package).write(to: url, options: .atomic)
            let stats = try LookTableStats(package.definition().table!)
            print(
                "\(package.id)@\(package.version)  strength \(String(format: "%.3f", stats.strength))  neutral \(String(format: "%.4f", stats.neutralChroma))  → \(url.lastPathComponent)",
            )
        }
        print("Regenerate the workspace (mise run generate) so the app bundles the new files.")
    }
}

/// `redlamp recipe golden`: checks (or records) the bundled recipes' golden renders.
enum GoldenRenders {
    static func run(record: Bool, renderer: RecipeRenderer) async throws {
        let folder = GoldenRender.directory(root: Repository.root, processVersion: EditRecipe.currentProcessVersion)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var failures = 0
        for recipe in BuiltInRecipes.all {
            let url = folder.appendingPathComponent(GoldenRender.fileName(for: recipe))
            let rendered = try await GoldenRender.render(recipe, with: renderer)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard record else {
                    print("MISSING \(recipe.id)@\(recipe.version) (run with --record)")
                    failures += 1
                    continue
                }
                try ImageFile.write(rendered, to: url)
                print("RECORDED \(recipe.id)@\(recipe.version)")
                continue
            }
            // Golden renders are never overwritten, even with --record.
            let golden = try ImageFile.read(url)
            guard let comparison = GoldenRender.compare(golden, rendered) else {
                print("FAIL \(recipe.id): size changed")
                failures += 1
                continue
            }
            let status = comparison.passes ? "ok  " : "FAIL"
            if !comparison.passes {
                failures += 1
            }
            print(
                "\(status) \(recipe.id)@\(recipe.version)  mean ΔE \(String(format: "%.2f", comparison.meanDeltaE))  max \(String(format: "%.2f", comparison.maxDeltaE))",
            )
        }
        if failures > 0 {
            throw ExitCode(1)
        }
    }
}
