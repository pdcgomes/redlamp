import CoreGraphics
import CryptoKit
import Foundation
import RedlampBench
import RedlampEngineAPI
import RedlampRecipes
import RedlampServices

/// One photo of the kit, as listed in research/app-looks/kit-photos.json.
struct KitPhotoSpec: Decodable {
    var name: String
    var subject: String
    /// A look-development raw rendered neutrally.
    var raw: String?
    var title: String?
    var author: String?
    var license: String?
    /// A remote original, checked against `sha1`.
    var url: String?
    var page: String?
    var sha1: String?
}

/// `redlamp recipe app-kit` and `app-import`: measure a phone app's filter into a Redlamp
/// Base Look. See docs/recipes/app-looks.md.
enum AppLookCommands {
    static let kitFolder = "build/app-looks/kit"
    static let compactKitFolder = "build/app-looks/kit-compact"
    static let outFolder = "build/app-looks/out"
    static let sourcesFolder = "build/app-looks/sources"
    static let zipFile = "build/app-looks/redlamp-capture-kit.zip"
    static let photoList = "research/app-looks/kit-photos.json"
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
    static let apps: Set<String> = ["prequel", "lightroom"]
    static let valued: Set<String> = ["--app", "--filter", "--kit", "--compact-kit"]

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - app-kit

    static func photoSpecs() throws -> [KitPhotoSpec] {
        struct List: Decodable {
            var photos: [KitPhotoSpec]
        }
        return try JSONDecoder().decode(
            List.self, from: Data(contentsOf: Repository.root.appendingPathComponent(photoList)),
        ).photos
    }

    static func kit(_ context: RecipeCommands.Context) async throws {
        if context.arguments.has("--task") {
            return try publishTemplate(context)
        }
        if context.arguments.has("--compact") {
            return try await compactKit(context)
        }
        let root = Repository.root
        let folder = context.arguments.value("--output").map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(kitFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files = try writeCharts(into: folder)
        let renderer = try context.renderer()
        for (index, spec) in try photoSpecs().enumerated() {
            let name = "redlamp-kit-photo-\(index + 1)-\(spec.name).jpg"
            guard let made = try await photo(spec, renderer: renderer) else {
                print("skipped \(name): \(spec.raw ?? spec.name) isn't downloaded (mise run lookdev)")
                continue
            }
            let (image, source) = made
            let url = folder.appendingPathComponent(name)
            try ImageFile.write(image, to: url, quality: 0.95)
            try files.append(CaptureKitManifest.File(
                file: name, role: "photo", subject: spec.subject, data: Data(contentsOf: url),
                width: image.width, height: image.height, source: source,
            ))
            print("wrote \(name) \(image.width)x\(image.height)")
        }
        let readme = Data(AppLookKitReadme.text(files: files).utf8)
        try readme.write(to: folder.appendingPathComponent("README.txt"), options: .atomic)
        files.append(CaptureKitManifest.File(file: "README.txt", role: "readme", data: readme))
        try encoder.encode(CaptureKitManifest(files: files))
            .write(to: folder.appendingPathComponent(CaptureKitManifest.fileName), options: .atomic)
        let zip = context.arguments.value("--output") == nil
            ? root.appendingPathComponent(zipFile)
            : folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent).zip")
        try? FileManager.default.removeItem(at: zip)
        try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", folder.path, zip.path])
        print("kit: \(folder.path) (\(files.count) files)\nzip: \(zip.path)")
    }

    /// One PNG holding the lattice, the photos as tiles and the resolution probe. PNG, so the
    /// lattice reaches the app without JPEG's chroma subsampling and requantisation.
    static func compactKit(_ context: RecipeCommands.Context) async throws {
        let layout = CaptureLayout.compact
        let folder = context.arguments.value("--output").map { URL(fileURLWithPath: $0) }
            ?? Repository.root.appendingPathComponent(compactKitFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renderer = try context.renderer()
        var tiles: [PixelImage] = [], subjects: [String] = []
        for spec in try photoSpecs().prefix(layout.photoTiles.count) {
            guard let made = try await photo(spec, renderer: renderer), let pixels = PixelImage(made.0) else {
                print("skipped tile \(spec.name): \(spec.raw ?? spec.name) isn't downloaded (mise run lookdev)")
                continue
            }
            tiles.append(pixels)
            subjects.append(spec.name)
        }
        guard let image = CaptureChart.cgImage8(layout.pixels(chart: 0, tiles: tiles)) else {
            throw CLIError(description: "cannot draw the compact kit")
        }
        let url = folder.appendingPathComponent(CaptureKitManifest.compactFileName)
        try LookTableImport.writePNG(image, to: url)
        var files = try [CaptureKitManifest.File(
            file: url.lastPathComponent, role: "compact", chart: 1,
            subject: "colour lattice \(layout.lattice)³, grey ramp, line pairs and \(tiles.count) photo tiles",
            data: Data(contentsOf: url), width: image.width, height: image.height, tiles: subjects,
        )]
        let readme = Data(AppLookKitReadme.compactText(file: url.lastPathComponent, tiles: subjects).utf8)
        try readme.write(to: folder.appendingPathComponent("README.txt"), options: .atomic)
        files.append(CaptureKitManifest.File(file: "README.txt", role: "readme", data: readme))
        try encoder.encode(CaptureKitManifest(layout: layout, files: files))
            .write(to: folder.appendingPathComponent(CaptureKitManifest.fileName), options: .atomic)
        print("wrote \(url.path) \(image.width)x\(image.height), README.txt and kit.json")
    }

    /// The kits already written, as the bench hub's `look-kit` template (TON-36), so the iPhone app's
    /// new look references copy exactly these images.
    static func publishTemplate(_ context: RecipeCommands.Context) throws {
        let root = Repository.root
        func folder(_ option: String, _ fallback: String) -> URL? {
            let url = context.arguments.value(option).map { URL(fileURLWithPath: $0) } ?? root
                .appendingPathComponent(fallback)
            return FileManager.default
                .fileExists(atPath: url.appendingPathComponent(CaptureKitManifest.fileName).path) ? url : nil
        }
        let full = folder("--kit", kitFolder), compact = folder("--compact-kit", compactKitFolder)
        guard full != nil || compact != nil else {
            throw CLIError(
                description: "no kit to publish: run `redlamp recipe app-kit` (and --compact) first, or pass --kit",
            )
        }
        let template = try BenchCapture.publishKit(full: full, compact: compact, in: BenchStore())
        print("published \(template.manifest.assets.count) kit images as \(template.url.path)")
    }

    static func writeCharts(into folder: URL) throws -> [CaptureKitManifest.File] {
        try (0 ..< CaptureChart.chartCount).map { chart in
            guard let image = CaptureChart.cgImage8(CaptureChart.pixels(chart: chart)) else {
                throw CLIError(description: "cannot draw chart \(chart + 1)")
            }
            let name = CaptureKitManifest.chartFileName(chart)
            let url = folder.appendingPathComponent(name)
            try LookTableImport.writePNG(image, to: url)
            let blues = CaptureChart.slices(chart: chart)
            print("wrote \(name)")
            return try CaptureKitManifest.File(
                file: name, role: "chart", chart: chart + 1,
                subject: "colour lattice, blue levels \(blues.lowerBound + 1)–\(blues.upperBound) of \(CaptureChart.lattice)",
                data: Data(contentsOf: url), width: image.width, height: image.height,
            )
        }
    }

    /// A kit photo at the chart's size: a look-dev raw rendered neutrally, or a downloaded
    /// original resized. Nil when the raw isn't downloaded.
    static func photo(
        _ spec: KitPhotoSpec,
        renderer: RecipeRenderer,
    ) async throws -> (CGImage, CaptureKitManifest.Source)? {
        let root = Repository.root
        if let raw = spec.raw {
            let url = LookDevSet.folder(root: root).appendingPathComponent(raw)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let image = try await renderer.render(nil, image: url, maxLongEdge: CaptureChart.side)
            let entry = LookDev.manifest()?.images.first { $0.file == raw }
            return (image, CaptureKitManifest.Source(
                title: entry?.camera, license: entry?.license ?? "CC0-1.0", url: entry?.url ?? "",
                page: entry?.source, raw: raw,
            ))
        }
        guard let remote = spec.url else { return nil }
        let original = try await download(
            remote, sha1: spec.sha1,
            to: root.appendingPathComponent(sourcesFolder).appendingPathComponent("\(spec.name).jpg"),
        )
        guard let image = try PixelImage(ImageFile.read(original), maxLongEdge: CaptureChart.side)?.cgImage() else {
            throw CLIError(description: "cannot read \(original.path)")
        }
        return (image, CaptureKitManifest.Source(
            title: spec.title, author: spec.author, license: spec.license ?? "unknown", url: remote, page: spec.page,
        ))
    }

    /// Fetches a file once, politely, and checks it against the SHA-1 its host publishes. curl
    /// rather than URLSession, so it goes through the same proxy settings as `mise run lookdev`.
    static func download(_ remote: String, sha1: String?, to url: URL) async throws -> URL {
        func matches(_ data: Data) -> Bool {
            sha1.map { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() == $0 } ?? true
        }
        if let data = try? Data(contentsOf: url), matches(data) {
            return url
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.appendingPathExtension("partial")
        print("downloading \(remote)")
        try run("/usr/bin/curl", [
            "-fsSL", "--retry", "2", "-A", "RedlampCaptureKit/1.0 (look development; one request at a time)",
            "-o", partial.path, remote,
        ])
        guard try matches(Data(contentsOf: partial)) else {
            try? FileManager.default.removeItem(at: partial)
            throw CLIError(description: "\(remote) doesn't match its SHA-1")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(description: "\(tool) failed with status \(process.terminationStatus)")
        }
    }

    // MARK: - app-import

    static func importLook(_ context: RecipeCommands.Context) async throws {
        let arguments = context.arguments
        guard let path = arguments.positional.first, let name = arguments.value("--name") else {
            throw CLIError(description: "app-import needs <folder or compact export> --name <Redlamp name>")
        }
        let url = URL(fileURLWithPath: path)
        if let reference = try? BenchFolder.load(url), reference.manifest.look != nil {
            return try await importReference(reference, name: name, context: context)
        }
        let provenance = try provenance(arguments, name: name)
        let session = try Session.load(path: url, kit: arguments.value("--kit").map { URL(fileURLWithPath: $0) })
        let matches = match(session.photos, session.kitPhotos)
        let result = try session.inputs(matches, provenance: provenance).read()

        var recipe = try AppLookRecipe.make(result, name: name)
        let out = Repository.root.appendingPathComponent(outFolder).appendingPathComponent(slug(name))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let recipeURL = out.appendingPathComponent("\(slug(name)).\(Recipe.fileExtension)")
        try RecipeFile.write(recipe, to: recipeURL)
        try encoder.encode(result.report).write(to: out.appendingPathComponent("report.json"), options: .atomic)
        try Data(result.report.summary.utf8).write(to: out.appendingPathComponent("report.txt"), options: .atomic)
        let sheet = try await contactSheet(recipe, result, renderer: context.renderer(), session, matches)
        try ImageFile.write(sheet, to: out.appendingPathComponent("contact-sheet.jpg"))
        print(result.report.summary)
        print("wrote \(recipeURL.path), report.json, report.txt and contact-sheet.jpg")
        if arguments.has("--install") {
            recipe = try context.library.install(contentsOf: recipeURL, reading: InProcessDecoder()).recipe
            print("installed \(recipe.id) (\(recipe.name))")
        }
    }

    /// A look reference made on the iPhone (TON-36): its own kit images are the originals, and its
    /// app, filter, variant and settings the provenance.
    static func importReference(_ reference: BenchFolder, name: String, context: RecipeCommands.Context) async throws {
        let look = try reference.manifest.look.map { look in
            try provenance(name: name, app: look.app, filter: look.filter)
            return look
        }
        let inputs = try BenchCapture.inputs(reference)
        let result = try inputs.read()
        var recipe = try AppLookRecipe.make(result, name: name)
        let out = Repository.root.appendingPathComponent(outFolder).appendingPathComponent(slug(name))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let recipeURL = out.appendingPathComponent("\(slug(name)).\(Recipe.fileExtension)")
        try RecipeFile.write(recipe, to: recipeURL)
        try encoder.encode(result.report).write(to: out.appendingPathComponent("report.json"), options: .atomic)
        try Data(result.report.summary.utf8).write(to: out.appendingPathComponent("report.txt"), options: .atomic)
        let vignette = result.report.vignette?.model
        func preview(_ image: PixelImage) -> CGImage? {
            let small = image.cgImage().flatMap { PixelImage($0, maxLongEdge: 720) } ?? image
            return PhotoPairAnalysis.preview(small, table: result.table, vignette: vignette).cgImage()
        }
        var rows: [[CGImage?]] = []
        if let chart = inputs.charts.first,
           let original = inputs.originals.compact ?? inputs.originals.charts.values.first {
            rows.append([original.cgImage(), chart.image.cgImage(), preview(original)])
        }
        rows += inputs.photos.map { [$0.kitImage.cgImage(), $0.exportImage.cgImage(), preview($0.kitImage)] }
        let sheet = try grid(rows, titles: ["Kit original", "App export", "Redlamp: \(recipe.name)"])
        try ImageFile.write(sheet, to: out.appendingPathComponent("contact-sheet.jpg"))
        print("\(look?.title ?? reference.id): \(result.report.summary)")
        print("wrote \(recipeURL.path), report.json, report.txt and contact-sheet.jpg")
        if context.arguments.has("--install") {
            recipe = try context.library.install(contentsOf: recipeURL).recipe
            print("installed \(recipe.id) (\(recipe.name))")
        }
    }

    /// The app and filter, kept privately; the recipe's name must be Redlamp's own.
    static func provenance(_ arguments: Arguments, name: String) throws -> AppLookReport.Provenance {
        let app = arguments.value("--app")?.lowercased()
        if let app, !apps.contains(app) {
            throw CLIError(description: "--app is prequel or lightroom")
        }
        return try provenance(name: name, app: app, filter: arguments.value("--filter"))
    }

    @discardableResult
    static func provenance(name: String, app: String?, filter: String?) throws -> AppLookReport.Provenance {
        let forbidden = [app, filter].compactMap { $0?.lowercased() } + apps.sorted()
        if forbidden.contains(where: { !$0.isEmpty && name.lowercased().contains($0) }) {
            throw CLIError(description: "--name must be Redlamp's own name, not the app's or the filter's")
        }
        return AppLookReport.Provenance(app: app, filter: filter)
    }

    static func slug(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let words = name.lowercased().map { allowed.contains($0) ? $0 : " " }
        return String(words).split(separator: " ").joined(separator: "-")
    }
}
