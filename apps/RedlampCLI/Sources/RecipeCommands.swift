import CoreGraphics
import Foundation
import RedlampEngine
import RedlampEngineAPI
import RedlampRecipes
import RedlampServices

/// `redlamp recipe …`: look-development tools on the same engine and library as the app.
enum RecipeCommands {
    static let usage = """
    usage: redlamp recipe <command> [options]

    commands:
      list [--query <text>] [--json]           every recipe; the query takes Lightroom words too
      show <recipe>                            print a recipe as JSON
      lint <recipe|all> [--json]               check recipes against the lint chart (exit 1 on failure)
      render <image> --recipe <recipe> -o <out> [--size <px>] [--amount <0-200>]
      contact-sheet -o <sheet.png> [--recipes <list>] [--images <file>…] [--lookdev] [--chart]
                    [--original] [--tile <px>]
      hald-identity [-o <identity.png>] [--level <2-16>]
      import <file|folder>… [--space <space>] [--display rec709|srgb] [--name <name>]
             [-o <out.redrecipe|folder>] [--install]
                                               a .redrecipe, a Lightroom .xmp preset (a folder: every
                                               preset in it) or a .cube, .3dl or HaldCLUT look table; a
                                               preset's report lists what was mapped, approximated and
                                               ignored. For several, -o is a folder; exit 1 only when
                                               nothing converted. A look table is for --space srgb (the
                                               default), rec2020 (Redlamp's own) or camera log footage:
                                               slog3-sgamut3cine, slog3-sgamut3, logc3-awg3, vlog-vgamut
                                               or applelog, with output for --display rec709 (gamma 2.4,
                                               the default) or srgb
      export <recipe> -o <out.redrecipe> [--cube <out.cube>]
      build-pack [--out <dir>]                 regenerate the bundled LUT Base Looks
      golden [--record]                        compare (or record) golden renders of bundled recipes
      fingerprint <image>… [--json]            the style fingerprint of images
      fit --references <image>… [--images <raw>…] [--lut] [--name <name>] [-o <out.redrecipe>]
          [--evaluations <n>]
      profile [--pairs <manifest.json>] [--slots <slot,…>] [--install]
                                               fit film-slot Base Looks to camera JPEGs in raw files
      film [--film <stock>] [--print <stock>] [--exposure <ev>] [--interlayer <k>] [--grey <display>]
           [--negative-density <d>] [--flare <f>] [--name <name>] [--count <images>] [--out <dir>]
                                               build a look with the film model (no --film lists stocks)
      film --all | --look <id> [--install] [--readme]
                                               build the film catalogue's looks; --install bundles their
                                               tables, --readme writes docs/images/film
      app-kit [--compact] [-o <folder>]        write the phone capture kit for app filters (--compact:
                                               one image per filter instead of 3 charts and 8 photos)
      app-import <folder|export> --name <name> [--app prequel|lightroom] [--filter <name>] [--kit <folder>]
                 [--install]                   measure a phone app's filter from exports of the kit

    <recipe> is a .redrecipe path, an id (redlamp/essentials/punchy), a bundled slug
    (essentials/punchy) or a name. <list> is `all`, `group:<Group>` or comma-separated recipes.
    """

    static let valued: Set<String> = [
        "--output", "--query", "--recipe", "--size", "--amount", "--recipes", "--images", "--tile", "--level",
        "--space", "--display", "--name", "--cube", "--out", "--references", "--evaluations", "--seed", "--pairs",
        "--slots",
    ]

    /// One command's inputs.
    struct Context {
        var arguments: Arguments
        var library: RecipeLibrary

        func renderer() throws -> RecipeRenderer {
            try RecipeRenderer(engine: RedlampEngine(), library: library)
        }
    }

    static func run(_ raw: [String]) async throws {
        guard let command = raw.first else { throw CLIError(description: usage) }
        // `--images` and `--references` take every following non-option argument.
        let rest = expandLists(Array(raw.dropFirst()), for: ["--images", "--references"])
        let context = try Context(
            arguments: Arguments(rest, valued: valued.union(FilmCommand.valued).union(AppLookCommands.valued)),
            library: RecipeLibrary(),
        )
        switch command {
        case "list": list(context)
        case "show": try show(context)
        case "lint": try await lint(context)
        case "render": try await render(context)
        case "contact-sheet": try await contactSheet(context)
        case "hald-identity": try haldIdentity(context)
        case "import": try importFiles(context)
        case "export": try export(context)
        case "build-pack": try StarterPackBuilder
            .build(into: context.arguments.value("--out").map(URL.init(fileURLWithPath:)))
        case "golden": try await GoldenRenders.run(
                record: context.arguments.has("--record"),
                renderer: context.renderer(),
            )
        case "fingerprint": try fingerprint(context)
        case "fit": try await fit(context)
        case "profile": try await ProfileCommand.run(context)
        case "film": try await FilmCommand.run(context)
        case "app-kit": try await AppLookCommands.kit(context)
        case "app-import": try await AppLookCommands.importLook(context)
        default: throw CLIError(description: usage)
        }
    }

    // MARK: - Commands

    static func list(_ context: Context) {
        let recipes = context.library.search(context.arguments.value("--query") ?? "")
        if context.arguments.has("--json") {
            try? printJSON(recipes
                .map { ["id": $0.id, "name": $0.name, "group": $0.group, "version": "\($0.version)"] })
        } else {
            for recipe in recipes {
                let table = recipe.usesLookTable ? " [LUT]" : ""
                print("\(recipe.id)@\(recipe.version)  \(recipe.group) / \(recipe.name)\(table)")
            }
        }
        for (url, issues) in context.library.loadIssues {
            let reasons = issues.map(\.description).joined(separator: "; ")
            FileHandle.standardError.write(Data("\(url.lastPathComponent): \(reasons)\n".utf8))
        }
    }

    static func show(_ context: Context) throws {
        guard let spec = context.arguments.positional.first else { throw CLIError(description: "show needs a recipe") }
        let recipe = try context.library.exportable(context.library.resolve(spec))
        try print(String(decoding: RecipeFile.encode(recipe), as: UTF8.self))
    }

    static func lint(_ context: Context) async throws {
        let recipes = try context.library.resolveList(context.arguments.positional.first ?? "all")
        let tools = try context.renderer()
        let json = context.arguments.has("--json")
        var report: [[String: String]] = []
        var failed = false
        for recipe in recipes {
            let results = try await tools.lint(recipe)
            let overall = RecipeLint.overall(results)
            failed = failed || overall == .fail
            if json {
                report += results.map { result in
                    [
                        "recipe": recipe.id, "check": result.check.rawValue, "status": result.status.rawValue,
                        "value": String(format: "%.4f", result.value), "detail": result.detail,
                    ]
                }
                continue
            }
            let marks = results.map { "\($0.check.rawValue)=\($0.status.rawValue)" }.joined(separator: " ")
            print(
                "\(overall.rawValue.uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)) \(recipe.id)  \(marks)",
            )
            for result in results where result.status == .warn || result.status == .fail {
                print("       \(result.check.title): \(result.detail)")
            }
        }
        if json {
            try printJSON(report)
        }
        if failed {
            throw ExitCode(1)
        }
    }

    static func render(_ context: Context) async throws {
        let arguments = context.arguments
        guard let image = arguments.positional.first, let spec = arguments.value("--recipe"),
              let output = arguments.value("--output")
        else { throw CLIError(description: "render needs <image> --recipe <recipe> -o <out>") }
        let recipe = try context.library.resolve(spec)
        let rendered = try await context.renderer().render(
            recipe, image: URL(fileURLWithPath: image), maxLongEdge: arguments.int("--size"),
            amount: arguments.double("--amount") ?? 100,
        )
        try ImageFile.write(rendered, to: URL(fileURLWithPath: output), protecting: [URL(fileURLWithPath: image)])
        print("\(recipe.name) → \(output) \(rendered.width)x\(rendered.height)")
    }

    static func contactSheet(_ context: Context) async throws {
        let arguments = context.arguments
        guard let output = arguments.value("--output") else { throw CLIError(description: "contact-sheet needs -o") }
        var recipes: [Recipe?] = try context.library.resolveList(arguments.value("--recipes") ?? "all")
        if arguments.has("--original") {
            recipes.insert(nil, at: 0)
        }
        var images = arguments.values("--images").map { URL(fileURLWithPath: $0) }
        if arguments.has("--lookdev") || (images.isEmpty && !arguments.has("--chart")) {
            images += LookDev.images()
        }
        if arguments.has("--chart") {
            try images.append(RecipeChart.fileURL())
        }
        guard !images.isEmpty else { throw CLIError(description: "no images (pass --images, --lookdev or --chart)") }
        let sheet = try await context.renderer()
            .contactSheet(recipes: recipes, images: images, tile: arguments.int("--tile") ?? 240)
        try ImageFile.write(sheet, to: URL(fileURLWithPath: output), protecting: images)
        print("\(recipes.count) recipes × \(images.count) images → \(output) \(sheet.width)x\(sheet.height)")
    }

    static func haldIdentity(_ context: Context) throws {
        let level = try context.arguments.int("--level") ?? 8
        guard (2 ... 16).contains(level), let image = LookTableImport.haldIdentity(level: level) else {
            throw CLIError(description: "level must be 2…16")
        }
        let output = context.arguments.value("--output") ?? "hald-identity-\(level).png"
        try LookTableImport.writePNG(image, to: URL(fileURLWithPath: output))
        print("""
        \(output): a \(level * level)-point identity (\(image.width)×\(image.height), sRGB). Grade it with the same \
        adjustments as a photo, in any editor, keeping it in sRGB, then: redlamp recipe import <graded.png>
        """)
    }

    /// One file, read as the app's import reads it, or several files and folders of presets.
    static func importFiles(_ context: Context) throws {
        let inputs = context.arguments.positional
        guard !inputs.isEmpty else { throw CLIError(description: "import needs a file, or a folder of presets") }
        let space = try tableSpace(context.arguments)
        var isFolder: ObjCBool = false
        if inputs.count == 1,
           !(FileManager.default.fileExists(atPath: inputs[0], isDirectory: &isFolder) && isFolder.boolValue) {
            try importFile(URL(fileURLWithPath: inputs[0]), space: space, context)
        } else {
            try importFiles(inputs.map { URL(fileURLWithPath: $0) }, space: space, context)
        }
    }

    /// Without `-o` or `--install` the recipe is the output, on standard output, and the
    /// report goes to standard error.
    static func importFile(_ url: URL, space: ImportedTableSpace, _ context: Context) throws {
        let arguments = context.arguments
        var imported = try RecipeLibrary.read(
            importing: url, tableSpace: space, name: arguments.value("--name"), reading: InProcessDecoder(),
        )
        let output = arguments.value("--output")
        guard output != nil || arguments.has("--install") else {
            if imported.report != nil || !imported.issues.isEmpty {
                printError(RecipeImportSummary.Item(file: url, outcome: .imported(imported)).text)
            }
            try print(String(decoding: RecipeFile.encode(imported.recipe), as: UTF8.self))
            return
        }
        if arguments.has("--install") {
            imported = try context.library.install(imported)
        }
        if let output {
            try RecipeFile.write(imported.recipe, to: URL(fileURLWithPath: output))
        }
        print(RecipeImportSummary.Item(file: url, outcome: .imported(imported)).text)
        if arguments.has("--install") {
            print("installed \(imported.recipe.id) (\(imported.recipe.name))")
        }
        if let output {
            print("wrote \(output)")
        }
    }

    /// Each file, and every preset in each folder, with its report; installed, or written
    /// into the `-o` folder, when asked. Files that don't convert are listed on standard
    /// error, and the command fails only when none converted.
    static func importFiles(_ inputs: [URL], space: ImportedTableSpace, _ context: Context) throws {
        let arguments = context.arguments
        guard arguments.value("--name") == nil else {
            throw CLIError(description: "--name names the recipe of a single file")
        }
        var summary = RecipeLibrary.read(importing: inputs, tableSpace: space, reading: InProcessDecoder())
        if arguments.has("--install") {
            summary = context.library.install(summary)
        }
        for item in summary.items {
            if case .failed = item.outcome {
                printError(item.text)
            } else {
                print(item.text)
            }
        }
        let verb = arguments.has("--install") ? "installed" : "converted"
        let done = summary.imported.count
        guard done > 0 else {
            printError("nothing was \(verb)")
            throw ExitCode(1)
        }
        let output = arguments.value("--output")
        if let output {
            let folder = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var taken = Set<String>()
            for imported in summary.imported {
                let name = uniqueName(RecipeFile.fileName(for: imported.recipe), taken: &taken)
                try RecipeFile.write(imported.recipe, to: folder.appendingPathComponent(name))
            }
        }
        let kept = arguments.has("--install") || output != nil
        print("\(verb) \(done) of \(summary.items.count) files\(kept ? "" : "; -o <folder> or --install keeps them")")
        if let output {
            print("wrote \(done) recipe\(done == 1 ? "" : "s") to \(output)")
        }
    }

    /// A line on standard error, after whatever standard output holds, so the two stay in
    /// order when they go to the same file.
    static func printError(_ line: String) {
        fflush(stdout)
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    /// `name`, or `name 2`, `name 3`… when this run already used it; file names differ by
    /// more than case.
    static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while !taken.insert(candidate.lowercased()).inserted {
            candidate = "\(base) \(number).\(ext)"
            number += 1
        }
        return candidate
    }

    /// `--space` and `--display`: what an imported look table was made for.
    static func tableSpace(_ arguments: Arguments) throws -> ImportedTableSpace {
        let output: LookTableOutput = switch arguments.value("--display") {
        case nil, "rec709": .rec709
        case "srgb": .sRGB
        case let other?: throw CLIError(description: "--display is rec709 or srgb, not \(other)")
        }
        switch arguments.value("--space") {
        case nil, "srgb":
            return .sRGB
        case "rec2020":
            return .displayRec2020
        case let other?:
            guard let camera = CameraLogSpace(rawValue: other) else {
                let spaces = ["srgb", "rec2020"] + CameraLogSpace.allCases.map(\.rawValue)
                throw CLIError(description: "--space is one of \(spaces.joined(separator: ", ")), not \(other)")
            }
            return .cameraLog(camera, output: output)
        }
    }

    static func export(_ context: Context) throws {
        guard let spec = context.arguments.positional.first, let output = context.arguments.value("--output") else {
            throw CLIError(description: "export needs <recipe> -o <out.redrecipe>")
        }
        let recipe = try context.library.resolve(spec)
        try context.library.export(recipe, to: URL(fileURLWithPath: output))
        if let cube = context.arguments.value("--cube"),
           let package = context.library.exportable(recipe).embeddedBaseLooks.first,
           let table = try package.definition().table {
            try LookTableImport.cubeText(table, title: package.name).write(
                toFile: cube,
                atomically: true,
                encoding: .utf8,
            )
            print("wrote \(cube) (in Redlamp's display Rec.2020 space)")
        }
        print("wrote \(output)")
    }

    static func fingerprint(_ context: Context) throws {
        let images = context.arguments.positional + context.arguments.values("--images")
        guard !images.isEmpty else { throw CLIError(description: "fingerprint needs images") }
        for path in images {
            let fingerprint = try measure(URL(fileURLWithPath: path))
            if context.arguments.has("--json") {
                try printJSON(["image": AnyEncodable(path), "fingerprint": AnyEncodable(fingerprint)])
            } else {
                print("\(URL(fileURLWithPath: path).lastPathComponent): \(fingerprint.summary)")
            }
        }
    }

    static func fit(_ context: Context) async throws {
        let arguments = context.arguments
        let references = arguments.values("--references").map { URL(fileURLWithPath: $0) }
        guard !references.isEmpty else { throw CLIError(description: "fit needs --references <image>…") }
        var images = arguments.values("--images").map { URL(fileURLWithPath: $0) }
        if images.isEmpty {
            images = Array(LookDev.images().prefix(6))
        }
        let target = try StyleFingerprint.average(references.map(measure))
        let fitter = try StyleFitter(renderer: context.renderer(), images: images)
        let result = try await fitter.fit(
            to: target, name: arguments.value("--name") ?? "Fitted Look", useLookTable: arguments.has("--lut"),
            evaluations: arguments.int("--evaluations") ?? 160, seed: UInt64(arguments.int("--seed") ?? 1),
        )
        let from = String(format: "%.3f", result.startDistance), to = String(format: "%.3f", result.distance)
        print("distance \(from) → \(to) in \(result.evaluations) renders")
        if let output = arguments.value("--output") {
            try RecipeFile.write(result.recipe, to: URL(fileURLWithPath: output))
            print("wrote \(output)")
        } else {
            try print(String(decoding: RecipeFile.encode(result.recipe), as: UTF8.self))
        }
    }

    // MARK: - Helpers

    static func measure(_ url: URL) throws -> StyleFingerprint {
        guard let pixels = try PixelImage(ImageFile.read(url), maxLongEdge: StyleFingerprint.analysisSize) else {
            throw CLIError(description: "cannot read \(url.path)")
        }
        return StyleFingerprint(pixels)
    }

    /// Lets `--images a b c` mean three values.
    static func expandLists(_ arguments: [String], for names: Set<String>) -> [String] {
        var result: [String] = []
        var current: String?
        for argument in arguments {
            if argument.hasPrefix("-") {
                current = names.contains(argument) ? argument : nil
                if current == nil {
                    result.append(argument)
                }
            } else if let current {
                result += [current, argument]
            } else {
                result.append(argument)
            }
        }
        return result
    }
}

struct ExitCode: Error {
    let code: Int32

    init(_ code: Int32) {
        self.code = code
    }
}

/// Wraps any encodable value for heterogeneous JSON.
struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        encode = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encode(encoder)
    }
}
