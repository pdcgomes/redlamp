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
                    throw CLIError(description: "no film look \(id) (known: \(FilmLookCatalog.looks.map(\.id).joined(separator: ", ")))")
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
            let url = folder.appendingPathComponent("stock-\(look.id).json")
            if let existing = try? RecipeFile.decoder.decode(BaseLookPackage.self, from: Data(contentsOf: url)),
               existing.version == package.version, existing.table?.sha256 != package.table?.sha256 {
                throw CLIError(description: """
                \(look.id): the look changed but its version didn't. Published looks never change; bump \
                FilmLookCatalog.bundledVersion instead.
                """)
            }
            try RecipeFile.encoder.encode(package).write(to: url, options: .atomic)
            print("installed \(package.id)@\(package.version) → \(url.lastPathComponent)")
        }
        print("Regenerate the workspace (mise run generate) so the app bundles the new files.")
    }
}
