import Foundation
import RedlampEngineAPI
import RedlampRecipes

/// `redlamp recipe profile`: fits film-slot Base Looks to cameras' own JPEGs.
///
/// Reads the pair manifest (research/profiler/fujifilm-pairs.json, downloaded by
/// research/profiler/fetch_pairs.py), fits each slot, and writes the look as the slot's
/// next version with a report and a comparison sheet into build/profiler/out. `--install`
/// also copies the look into the bundled resources.
enum ProfileCommand {
    struct Manifest: Decodable {
        struct Pair: Decodable {
            var slot: String
            var camera: String
            var file: String
        }

        var pairs: [Pair]
    }

    /// Slots need this many scenes before a fit is worth shipping.
    static let minimumScenes = 4

    static func run(_ context: RecipeCommands.Context) async throws {
        let arguments = context.arguments
        let manifestURL = arguments.value("--pairs").map(URL.init(fileURLWithPath:))
            ?? Repository.root.appendingPathComponent("research/profiler/fujifilm-pairs.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let folder = Repository.root.appendingPathComponent("build/profiler/fujifilm")
        let output = Repository.root.appendingPathComponent("build/profiler/out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let wanted = arguments.value("--slots").map { Set($0.split(separator: ",").map(String.init)) }
        let profiler = try LookProfiler(renderer: context.renderer())

        for slot in FilmSlot.allCases where wanted?.contains(slot.rawValue) ?? true {
            let pairs = manifest.pairs.filter { $0.slot == slot.rawValue }.compactMap { pair -> LookProfiler.Pair? in
                let url = folder.appendingPathComponent(pair.file)
                return FileManager.default.fileExists(atPath: url.path) ? LookProfiler.Pair(
                    raw: url,
                    scene: pair.camera,
                ) : nil
            }
            guard !pairs.isEmpty else { continue }
            print("\(slot.name) (\(slot.rawValue)): \(pairs.count) pairs")
            guard pairs.count >= minimumScenes else {
                print("  skipped: needs at least \(minimumScenes) scenes")
                continue
            }
            let previous = BuiltInBaseLooks.package(slot: slot.rawValue, version: StarterPackLooks.version)
            let tools = try context.renderer()
            let report = try await profiler.profile(pairs, previous: previous?.definition().table, accept: { table in
                // Shipped looks must not band or invert tones.
                let candidate = LookTableImport.recipe(for: table, name: "candidate")
                let results = await (try? tools.lint(candidate)) ?? []
                return results.allSatisfy { result in
                    ![.banding, .monotonicLuminance].contains(result.check) || result.status == .pass
                }
            }, log: { print($0) })
            let version = StarterPackLooks.version + 1
            let package = BaseLookPackage(
                id: StarterPackLooks.id(for: slot), version: version, name: slot.name,
                summary: "\(slot.summary) Measured from \(report.scenes) cameras' own renderings.",
                slot: slot.rawValue, parameters: previous?.parameters ?? .identity, table: report.table,
            )
            let neutral = String(format: "%.2f", report.neutral.mean)
            let before = report.previous.map { String(format: "%.2f", $0.mean) } ?? "–"
            let fitted = String(format: "%.2f (p90 %.2f)", report.fitted.mean, report.fitted.p90)
            print(
                "  ΔE to the camera: Redlamp Color \(neutral), version \(version - 1) \(before), fitted \(fitted) held out",
            )

            let file = output.appendingPathComponent("base-\(slot.rawValue)@\(version).json")
            try RecipeFile.encoder.encode(package).write(to: file, options: .atomic)
            var recipe = LookTableImport.recipe(for: report.table, name: "\(slot.name) v\(version)")
            recipe.embeddedBaseLooks = [package]
            recipe.baseLook = package.reference
            let sheet = try await profiler.comparisonSheet(Array(pairs.prefix(6)), look: recipe)
            try ImageFile.write(sheet, to: output.appendingPathComponent("\(slot.rawValue)-sheet.jpg"))
            print("  wrote \(file.lastPathComponent) and \(slot.rawValue)-sheet.jpg")
            if arguments.has("--install") {
                let resources = Repository.root.appendingPathComponent("packages/RedlampRecipes/Resources/BaseLooks")
                try FileManager.default.copyItem(at: file, to: resources.appendingPathComponent(file.lastPathComponent))
                print("  installed into Resources/BaseLooks (regenerate the workspace to bundle it)")
            }
        }
    }
}
