import Foundation
import RedlampEngineAPI
import RedlampRecipes

/// `redlamp recipe profile`: fits film-slot Base Looks to cameras' own JPEGs.
///
/// Reads the pair manifests (research/profiler/fujifilm-pairs.json and review-pairs.json,
/// downloaded by the fetchers next to them; `--pairs a.json,b.json` picks others), fits
/// each slot, and writes the look as the slot's next version with a report and a comparison
/// sheet into build/profiler/out. `--install` also copies the look into the bundled resources.
enum ProfileCommand {
    struct Manifest: Decodable {
        struct Pair: Decodable {
            var slot: String
            var camera: String
            var file: String
        }

        /// Where the files are, relative to the checkout.
        var folder: String?
        var pairs: [Pair]
    }

    static let defaultManifests = ["research/profiler/fujifilm-pairs.json", "research/profiler/review-pairs.json"]

    /// Slots need this many scenes before a fit is worth shipping.
    static let minimumScenes = 4

    static func run(_ context: RecipeCommands.Context) async throws {
        let arguments = context.arguments
        let paths = arguments.value("--pairs").map { $0.split(separator: ",").map(String.init) } ?? defaultManifests
        let available = try paths.flatMap { path -> [(Manifest.Pair, URL)] in
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : Repository.root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            let folder = Repository.root.appendingPathComponent(manifest.folder ?? "build/profiler/fujifilm")
            return manifest.pairs.map { ($0, folder.appendingPathComponent($0.file)) }
                .filter { FileManager.default.fileExists(atPath: $0.1.path) }
        }
        let output = Repository.root.appendingPathComponent("build/profiler/out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let wanted = arguments.value("--slots").map { Set($0.split(separator: ",").map(String.init)) }
        let profiler = try LookProfiler(renderer: context.renderer())

        for slot in FilmSlot.allCases where wanted?.contains(slot.rawValue) ?? true {
            // Scenes are grouped by camera: cross-validation leaves out whole bodies, and each
            // body's exposure offset is removed as a unit. With one body, each photo is its own
            // group, so the reported error is still on photos the fit never saw.
            let matching = available.filter { $0.0.slot == slot.rawValue }
            let oneCamera = Set(matching.map(\.0.camera)).count == 1
            let pairs = matching.map { pair, url in
                LookProfiler.Pair(raw: url, scene: oneCamera ? "\(pair.camera) \(pair.file)" : pair.camera)
            }
            guard !pairs.isEmpty else { continue }
            print("\(slot.name) (\(slot.rawValue)): \(pairs.count) pairs")
            guard pairs.count >= minimumScenes else {
                print("  skipped: needs at least \(minimumScenes) scenes")
                continue
            }
            let previous = BuiltInBaseLooks.package(slot: slot.rawValue)
            let tools = try context.renderer()
            let report = try await profiler.profile(pairs, previous: previous?.definition().table, accept: { table in
                // Shipped looks must not band or invert tones.
                let candidate = LookTableImport.recipe(for: table, name: "candidate")
                let results = await (try? tools.lint(candidate)) ?? []
                return results.allSatisfy { result in
                    ![.banding, .monotonicLuminance].contains(result.check) || result.status == .pass
                }
            }, log: { print($0) })
            let version = (previous?.version ?? StarterPackLooks.version) + 1
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
                try BuiltInBaseLooks.install(package, as: "base-\(slot.rawValue)@\(version)", in: resources)
                print("  installed into Resources/BaseLooks (regenerate the workspace to bundle it)")
            }
        }
    }
}
