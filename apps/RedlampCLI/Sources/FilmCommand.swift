import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampRecipes

/// `redlamp recipe film`: builds a film look with the film model, and a contact sheet of it
/// against Redlamp Color on the look-development set.
enum FilmCommand {
    static let valued: Set<String> = [
        "--film", "--print", "--exposure", "--interlayer", "--grey", "--negative-density", "--flare", "--table-size",
        "--count", "--masking", "--scan-contrast", "--scan-neutral", "--scanner", "--look", "--tile", "--print-neutral",
    ]

    static func run(_ context: RecipeCommands.Context) async throws {
        let arguments = context.arguments
        let data = Repository.root.appendingPathComponent("research/film-data")
        if arguments.has("--fit-moods") {
            try await fitMoods(context)
            return
        }
        if arguments.has("--validate") {
            try await renderForValidation(context)
            return
        }
        if arguments.has("--all") || arguments.value("--look") != nil {
            try await buildCatalog(context, data: data)
            return
        }
        guard let film = arguments.value("--film") else {
            print("looks: \(FilmLookCatalog.looks.map(\.id).joined(separator: ", "))")
            print("stocks: \(FilmLooks.stockIDs(in: data).joined(separator: ", "))")
            return
        }
        var parameters = FilmLookParameters()
        func number(_ flag: String) -> Double? {
            arguments.value(flag).flatMap(Double.init)
        }
        parameters.exposure = number("--exposure") ?? parameters.exposure
        parameters.interlayer = number("--interlayer") ?? parameters.interlayer
        parameters.displayGrey = number("--grey") ?? parameters.displayGrey
        parameters.negativeGreyDensity = number("--negative-density") ?? parameters.negativeGreyDensity
        parameters.flare = number("--flare") ?? parameters.flare
        parameters.masking = number("--masking") ?? parameters.masking
        parameters.scanContrast = number("--scan-contrast") ?? parameters.scanContrast
        parameters.scanNeutral = number("--scan-neutral") ?? parameters.scanNeutral
        parameters.printNeutral = number("--print-neutral") ?? parameters.printNeutral
        parameters.scanner = arguments.value("--scanner").flatMap(ScannerProfile.init(rawValue:)) ?? parameters.scanner
        let name = arguments.value("--name") ?? film
        let started = Date()
        let table = try FilmLooks.table(
            film: film, print: arguments.value("--print"), parameters: parameters,
            size: arguments.value("--table-size").flatMap(Int.init) ?? 33, data: data,
        )
        print("built \(table) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")

        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let recipe = LookTableImport.recipe(for: table, name: name, id: "local/film/\(slug)")
        let output = URL(fileURLWithPath: arguments.value("--out") ?? "build/film/out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let file = output.appendingPathComponent("\(slug).redrecipe")
        try RecipeFile.encoder.encode(recipe).write(to: file, options: .atomic)

        let images = Array(LookDev.images().prefix(arguments.value("--count").flatMap(Int.init) ?? 8))
        let sheet = try await context.renderer().contactSheet(recipes: [nil, recipe], images: images, tile: 420)
        let sheetURL = output.appendingPathComponent("\(slug)-sheet.jpg")
        try ImageFile.write(sheet, to: sheetURL)
        print("wrote \(file.path) and \(sheetURL.path)")
    }

    /// `--look <id>` or `--all`: the catalogue's looks as recipes with their effects, and one
    /// contact sheet of them all against Redlamp Color. `--install` writes their tables into the
    /// app's bundled Base Looks; `--readme` writes the README's icons and examples.
    private static func buildCatalog(_ context: RecipeCommands.Context, data: URL) async throws {
        let arguments = context.arguments
        let looks = arguments.has("--all") ? FilmLookCatalog.looks
            : try arguments.value("--look").map { id in
                guard let look = FilmLookCatalog.look(id) else {
                    throw CLIError(
                        description: "no film look \(id) (known: \(FilmLookCatalog.looks.map(\.id).joined(separator: ", ")))",
                    )
                }
                return [look]
            } ?? []
        let output = URL(fileURLWithPath: arguments.value("--out") ?? "build/film/looks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let size = arguments.value("--table-size").flatMap(Int.init) ?? 33
        var recipes: [Recipe] = []
        for look in looks {
            let started = Date()
            let recipe = try FilmLooks.recipe(for: look, size: size, data: data)
            let file = output.appendingPathComponent("\(look.id).redrecipe")
            try RecipeFile.encoder.encode(recipe).write(to: file, options: .atomic)
            print("\(look.id): \(String(format: "%.1f", Date().timeIntervalSince(started))) s → \(file.path)")
            recipes.append(recipe)
        }
        if arguments.has("--install") {
            try install(looks, data: data)
        }
        if arguments.has("--readme") {
            try await FilmReadmeAssets.write(
                recipes: Array(zip(looks, recipes)), renderer: context.renderer(),
                into: Repository.root.appendingPathComponent("docs/images/film"),
            )
        }
        let images = Array(LookDev.images().prefix(arguments.value("--count").flatMap(Int.init) ?? 6))
        let sheet = try await context.renderer().contactSheet(
            recipes: [nil] + recipes, images: images, tile: arguments.value("--tile").flatMap(Int.init) ?? 300,
        )
        let sheetURL = output.appendingPathComponent(looks.count == 1 ? "\(looks[0].id)-sheet.jpg" : "film-looks.jpg")
        try ImageFile.write(sheet, to: sheetURL)
        print("wrote \(sheetURL.path)")
    }

    private static func install(_ looks: [FilmLookDefinition], data: URL) throws {
        let folder = Repository.root.appendingPathComponent("packages/RedlampRecipes/Resources/BaseLooks")
        for look in looks {
            let package = try FilmLooks.bundledPackage(for: look, data: data)
            let name = look.version == 1 ? "stock-\(look.id)" : "stock-\(look.id)@\(look.version)"
            if let existing = BuiltInBaseLooks.installed(name, in: folder),
               existing.version == package.version, existing.table?.sha256 != package.table?.sha256 {
                throw CLIError(description: """
                \(look.id): the look changed but its version didn't. Published looks never change; bump \
                the look's version in FilmLookCatalog instead.
                """)
            }
            try BuiltInBaseLooks.install(package, as: name, in: folder)
            print("installed \(package.id)@\(package.version) → \(name).json.lzfse")
        }
        print("Regenerate the workspace (mise run generate) so the app bundles the new files.")
    }

    /// `--validate`: each stock's plain look (and Redlamp's default) on the look-development set,
    /// for comparing with photographs shot on the film (`research/film-references/analyse.py`).
    private static func renderForValidation(_ context: RecipeCommands.Context) async throws {
        let output = Repository.root.appendingPathComponent("build/film-validation")
        let references = Repository.root.appendingPathComponent("build/film-references")
        let renderer = try context.renderer()
        let images = LookDev.images()
        let looks = FilmLookCatalog.looks.filter { look in
            look.process == .standard && look.parameters.exposure == 0 && look.filmVariant == nil
                && look.printVariant == nil
                && FileManager.default.fileExists(atPath: references.appendingPathComponent(look.film).path)
        }
        let recipes: [(String, Recipe?)] = [("default", nil)] + looks.compactMap { look in
            BuiltInRecipes.recipe(id: look.recipeID).map { (look.id, $0) }
        }
        for (name, recipe) in recipes {
            let folder = output.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for image in images {
                let file = folder.appendingPathComponent(image.deletingPathExtension().lastPathComponent + ".jpg")
                if FileManager.default.fileExists(atPath: file.path) {
                    continue
                }
                try await ImageFile.write(renderer.render(recipe, image: image, maxLongEdge: 512), to: file)
            }
            print("\(name): \(images.count) renders")
        }
        let map = Dictionary(uniqueKeysWithValues: looks.map { ($0.id, $0.film) })
        try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("looks.json"))
        print("wrote \(output.path)")
    }

    /// Mood looks tuned on photographs shot on each film: the film's recipe, with sliders fitted
    /// to the photographs' style fingerprint (`StyleFitter`) on varied look-development images.
    static let fittedMoods: [(slug: String, name: String, look: String, references: String)] = [
        ("portra-days", "Portra Days", "portra-400", "kodak-portra-400"),
        ("ektar-colour", "Ektar Colour", "ektar-100", "kodak-ektar-100"),
        ("gold-summer", "Gold Summer", "gold-200", "kodak-gold-200"),
        ("superia-snapshots", "Superia Snapshots", "superia-400", "fuji-superia-xtra-400"),
        ("wedding-day", "Wedding Day", "pro-400h", "fuji-pro-400h"),
        ("cinestill-nights", "CineStill Nights", "cinestill-800t", "cinestill-800t"),
        ("velvia-landscapes", "Velvia Landscapes", "velvia-50", "fuji-velvia-50"),
        ("kodachrome-memories", "Kodachrome Memories", "kodachrome-64", "kodak-kodachrome-64"),
        ("tri-x-street", "Tri-X Street", "tri-x-400", "kodak-tri-x-400"),
        ("hp5-documentary", "HP5 Documentary", "hp5-plus", "ilford-hp5-plus"),
    ]

    /// `--fit-moods`: fits each of `fittedMoods` and writes the slider values it found to
    /// `build/film/fitted-moods.json`, to be reviewed and pinned in `MoodLooks`.
    private static func fitMoods(_ context: RecipeCommands.Context) async throws {
        let renderer = try context.renderer()
        let all = LookDev.images()
        let images = stride(from: 0, to: all.count, by: max(all.count / 8, 1)).prefix(8).map { all[$0] }
        let fitter = StyleFitter(renderer: renderer, images: images)
        var results: [String: [String: Double]] = [:]
        for mood in fittedMoods {
            guard let look = FilmLookCatalog.look(mood.look), let base = BuiltInRecipes.recipe(id: look.recipeID) else {
                throw CLIError(description: "no bundled film look \(mood.look)")
            }
            let folder = Repository.root.appendingPathComponent("build/film-references/\(mood.references)")
            let photos = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            let target = try StyleFingerprint.average(photos.map(RecipeCommands.measure))
            // Per-band hue and saturation mostly follow the photographs' subjects, not the film.
            let result = try await fitter.fit(
                to: target, name: mood.name, evaluations: context.arguments.int("--evaluations") ?? 200, onto: base,
                excluding: [.hueOrange, .hueGreen, .hueBlue, .saturationGreen, .saturationBlue],
            )
            let fitted = result.recipe.settings.values.filter { key, value in base.settings.values[key] != value }
            results[mood.slug] = Dictionary(uniqueKeysWithValues: fitted.map { ($0.key.rawValue, $0.value) })
            let from = String(format: "%.3f", result.startDistance), to = String(format: "%.3f", result.distance)
            print("\(mood.slug): \(photos.count) photographs, distance \(from) → \(to): \(fitted.count) sliders")
        }
        let output = Repository.root.appendingPathComponent("build/film/fitted-moods.json")
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("wrote \(output.path)")
    }
}
