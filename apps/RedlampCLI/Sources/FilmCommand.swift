import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampRecipes

/// `redlamp recipe film`: builds a film look with the film model, and a contact sheet of it
/// against Redlamp Color on the look-development set.
enum FilmCommand {
    static let valued: Set<String> = [
        "--film", "--print", "--exposure", "--interlayer", "--grey", "--negative-density", "--flare", "--table-size",
        "--count", "--masking", "--scan-contrast", "--scan-neutral",
    ]

    static func run(_ context: RecipeCommands.Context) async throws {
        let arguments = context.arguments
        let data = Repository.root.appendingPathComponent("research/film-data")
        guard let film = arguments.value("--film") else {
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
}
