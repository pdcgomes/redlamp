import Foundation
import RedlampDocument
import RedlampEngine
import RedlampEngineAPI
import RedlampLibrary
import RedlampRecipes
import RedlampServices

/// `redlamp export`: photos exported at once, each with its own edit, as the Export dialog exports the photos
/// selected (EDT-16, `docs/plans/2026-10-01-export-design.md`): named by a naming template (LIB-25), with the rule
/// for files already there, by `ExportNames`, and written by `ImageExporter` as the app writes them. One photo at a
/// time is opened, rendered, written and let go, since a downscaled export still renders at full resolution. A
/// photo that fails is named with why, and the rest go on.
enum ExportCommand {
    static let usage = """
    usage: redlamp export <photos or folders…> --to <folder> [options]

    Exports each photo with its own edit, read from its .redlamp sidecar (a photo without one exports as shot), as
    the app's Export dialog does. A folder gives the photos in it, in name order. Prints each file written and each
    photo that wasn't exported, with why, and exits 1 if one wasn't.

      --to <folder>            where the files go, made if it isn't there
      --name <template>        the files' names, a naming template as Rename Photos takes, such as
                               "{date:yyyyMMdd}-{text}-{sequence:3}" (default {name}-redlamp)
      --text [<name>=]<text>   what {text}, or {text:<name>}, gives; repeat for each
      --start <n>              the first number {sequence} gives (default 1)
      --existing number|overwrite|skip
                               an earlier export with the name is kept and the new file numbered (the default),
                               replaced, or kept and the photo skipped. A photo is never replaced.
      --format jpeg|heic|avif|jxl|png|tiff|jxl-lossless   (default jpeg)
      --quality <0…100>        for jpeg, heic, avif and jxl (default 90)
      --limit <KB>             for those, the highest quality that keeps each file within the limit instead
      --compression none|lzw|zip   for tiff (default zip)
      --bit-depth 8|10|16      bits per channel: 10 for heic and avif, 16 for jxl, png, tiff and jxl-lossless
                               (default 8, and 16 for tiff)
      --color-space srgb|p3    (default srgb)
      --long-edge <px>         the size: by the long edge, the short edge, within a width and height, in
      --short-edge <px>        megapixels or as a percentage of the photo's, never larger than the photo
      --fit <width>x<height>   (default: full size)
      --megapixels <n>
      --percent <n>
      --ppi <n>                the resolution print layouts read (default 300)
      --sharpen off|low|standard|high
                               sharpening for the screen, as Lightroom's Screen, on each photo a size reduces;
                               a photo exported at full size is left as it is (default off)
      --metadata all|no-location|none   what the files carry of the photos' metadata; all and no-location also
                               embed the edit (default all)
      --border as-edited|none|<recipe id>
                               each photo's own border (the default), none, or a border recipe's, such as
                               redlamp/border/white-4x5, on every photo; sizes include the border
    """

    private static let valued: Set<String> = [
        "--to", "--name", "--text", "--start", "--existing", "--format", "--quality", "--limit", "--compression",
        "--bit-depth", "--color-space", "--long-edge", "--short-edge", "--fit", "--megapixels", "--percent",
        "--ppi", "--metadata", "--border", "--sharpen",
    ]

    private static let sharpenings: [(String, OutputSharpening)] = OutputSharpening.allCases.map { ($0.rawValue, $0) }
    private static let existingFiles: [(String, ExistingFilePolicy)] = [
        ("number", .addNumber), ("overwrite", .overwrite), ("skip", .skip),
    ]
    private static let metadata: [(String, ExportMetadataPolicy)] = [
        ("all", .all), ("no-location", .allExceptLocation), ("none", .none),
    ]
    private static let colorSpaces: [(String, OutputColorSpace)] = [("srgb", .sRGB), ("p3", .displayP3)]
    private static let formats: [(String, ExportFormat)] = [
        ("jpeg", .jpeg), ("heic", .heic), ("avif", .avif), ("jxl", .jxl), ("png", .png), ("tiff", .tiff),
        ("jxl-lossless", .jxlLossless),
    ]
    private static let compressions: [(String, TIFFCompression)] = [("none", .none), ("lzw", .lzw), ("zip", .zip)]
    private static let sizes: [(String, ExportSizing.Mode)] = [
        ("--long-edge", .longEdge), ("--short-edge", .shortEdge), ("--fit", .dimensions),
        ("--megapixels", .megapixels), ("--percent", .percentage),
    ]

    static func run(_ arguments: [String]) async throws {
        guard !arguments.isEmpty, !arguments.contains("--help") else {
            print(usage)
            return
        }
        var remaining = arguments.makeIterator()
        while let argument = remaining.next() {
            if valued.contains(argument) {
                _ = remaining.next()
            } else if argument.hasPrefix("-") {
                throw CLIError(description: "unknown option \(argument)\n\n\(usage)")
            }
        }
        let options = try Arguments(arguments, valued: valued)
        guard let destination = options.value("--to") else {
            throw CLIError(description: "export needs --to <folder>\n\n\(usage)")
        }
        guard !options.positional.isEmpty else {
            throw CLIError(description: "export needs photos or folders\n\n\(usage)")
        }
        var settings = try Self.settings(options)
        let template: NamingTemplate
        do {
            template = try NamingTemplate(parsing: settings.naming.template)
        } catch {
            throw CLIError(description: pointing(at: error.range, in: settings.naming.template, error.message))
        }
        for name in template.textNames where settings.naming.texts[name] == nil {
            let flag = name.isEmpty ? "--text <text>" : "--text \(name)=<text>"
            FileHandle.standardError.write(Data("\(template) uses a text the job is given: pass \(flag)\n".utf8))
        }

        let batch = Self.batch(options.positional)
        for (path, reason) in batch.failures + batch.folders {
            fail(path, reason)
        }
        let folder = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL
        var report = Report(failed: batch.failures.count + batch.folders.count)
        if !batch.photos.isEmpty {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw CLIError(description: "\(folder.path) can't hold the files: \(error.localizedDescription)")
            }
            settings.destinationFolder = folder
            let photos = batch.photos.map { ExportNames.Photo(url: $0, fields: fields(of: $0)) }
            let names = try ExportNames(photos, settings: settings, reading: InProcessDecoder())
            try await export(names.targets, settings: settings, report: &report)
        }
        print(report.summary(total: batch.photos.count + batch.failures.count, folder: folder))
        if report.failed > 0 {
            throw ExitCode(1)
        }
    }

    // MARK: - The settings

    /// The Export dialog's settings the options give, from its defaults, with numbers added to the names of files
    /// already there; throws when an option doesn't read or does nothing for the format.
    static func settings(_ options: Arguments) throws -> ExportSettings {
        var settings = ExportSettings()
        settings.existingFiles = try choice("--existing", options, existingFiles) ?? .addNumber
        settings.metadata = try choice("--metadata", options, metadata) ?? .all
        settings.colorSpace = try choice("--color-space", options, colorSpaces) ?? .sRGB
        if let format = try choice("--format", options, formats) {
            settings.setFormat(format)
        }
        let format = settings.format
        let lossy = "jpeg, heic, avif and jxl"
        if let quality = try options.int("--quality") {
            guard (0 ... 100).contains(quality) else { throw CLIError(description: "--quality takes 0 to 100") }
            guard !format.isLossless else { throw CLIError(description: "--quality is for \(lossy)") }
            settings.quality = quality
        }
        if let limit = try options.int("--limit") {
            guard limit >= 1 else { throw CLIError(description: "--limit takes a size in KB, 1 or more") }
            guard !format.isLossless else { throw CLIError(description: "--limit is for \(lossy)") }
            guard options.value("--quality") == nil else {
                throw CLIError(description: "--limit chooses the quality: give --quality or --limit")
            }
            settings.limitsFileSize = true
            settings.fileSizeLimitKB = limit
        }
        if let compression = try choice("--compression", options, compressions) {
            guard format == .tiff else { throw CLIError(description: "--compression is for tiff") }
            settings.tiffCompression = compression
        }
        if let depth = try options.int("--bit-depth") {
            guard format.bitDepths.contains(depth) else {
                let depths = format.bitDepths.map(String.init).joined(separator: " or ")
                throw CLIError(description: "\(format.name) holds \(depths) bits per channel")
            }
            settings.bitDepth = depth
        }
        settings.sizing = try sizing(options)
        settings.sharpening = try choice("--sharpen", options, sharpenings) ?? .off
        guard settings.sharpening == .off || settings.sizing.mode != .full else {
            throw CLIError(description: "--sharpen sharpens a photo the size reduces: give a size too")
        }
        settings.border = try border(options)
        settings.naming.template = options.value("--name") ?? ExportNaming.standard
        for text in options.values("--text") {
            if let equals = text.firstIndex(of: "=") {
                settings.naming.texts[String(text[..<equals])] = String(text[text.index(after: equals)...])
            } else {
                settings.naming.texts[""] = text
            }
        }
        if let start = try options.int("--start") {
            guard start >= 0 else { throw CLIError(description: "--start needs a whole number, 0 or more") }
            settings.naming.sequenceStart = start
        }
        return settings
    }

    /// The size one of the sizing options gives, and the resolution; full size without one.
    private static func sizing(_ options: Arguments) throws -> ExportSizing {
        var sizing = ExportSizing()
        let given = sizes.filter { options.value($0.0) != nil }
        guard given.count <= 1 else {
            throw CLIError(description: "give one of \(sizes.map(\.0).joined(separator: ", ")), not several")
        }
        if let size = given.first, let text = options.value(size.0) {
            let (name, mode) = size
            sizing.mode = mode
            switch mode {
            case .full: break
            case .longEdge: sizing.longEdge = try options.int(name) ?? 0
            case .shortEdge: sizing.shortEdge = try options.int(name) ?? 0
            case .dimensions:
                let sides = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
                guard sides.count == 2, let width = Int(sides[0]), let height = Int(sides[1]) else {
                    throw CLIError(description: "--fit takes <width>x<height>, such as 1920x1080")
                }
                (sizing.width, sizing.height) = (width, height)
            case .megapixels: sizing.megapixels = try options.double(name) ?? 0
            case .percentage: sizing.percentage = try options.double(name) ?? 0
            }
            guard sizing.isValid else {
                throw CLIError(description: "\(name) needs a size above 0\(mode == .percentage ? ", up to 100" : "")")
            }
        }
        if let ppi = try options.int("--ppi") {
            guard ppi >= 1 else { throw CLIError(description: "--ppi needs a whole number, 1 or more") }
            sizing.ppi = ppi
        }
        return sizing
    }

    /// The border `--border` asks for: as edited, none, or a border recipe's from the library.
    private static func border(_ options: Arguments) throws -> ExportBorder {
        guard let text = options.value("--border") else { return .asEdited }
        switch text.lowercased() {
        case "as-edited": return .asEdited
        case "none": return .none
        default:
            guard let recipe = RecipeLibrary().all.first(where: { $0.id == text }), recipe.isBorderOnly else {
                throw CLIError(
                    description: "--border takes as-edited, none or a border recipe's id, such as redlamp/border/white-4x5",
                )
            }
            return ExportBorder(recipeID: recipe.id, name: recipe.name, values: recipe.settings.values)
        }
    }

    /// The value `name` gives, by its name in `choices`; nil when it isn't given.
    private static func choice<Value>(
        _ name: String, _ options: Arguments, _ choices: [(String, Value)],
    ) throws -> Value? {
        guard let text = options.value(name) else { return nil }
        guard let value = choices.first(where: { $0.0 == text.lowercased() })?.1 else {
            throw CLIError(description: "\(name) takes \(choices.map(\.0).joined(separator: ", "))")
        }
        return value
    }

    // MARK: - The photos

    /// The photos the paths name, in their order and each once: a folder's are the photos in it Redlamp opens, in
    /// name order. A path that isn't there or isn't a photo Redlamp opens is one of `failures`, and a folder
    /// without such a photo, or one that can't be read, one of `folders`.
    private struct Batch {
        var photos: [URL] = []
        var failures: [(path: URL, reason: String)] = []
        var folders: [(path: URL, reason: String)] = []
    }

    private static func batch(_ paths: [String]) -> Batch {
        var batch = Batch()
        var named: Set<String> = []
        func add(_ photo: URL) {
            if named.insert(photo.path).inserted {
                batch.photos.append(photo)
            }
        }
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isFolder: ObjCBool = false
            if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) {
                batch.failures.append((url, "There's no file or folder there."))
            } else if isFolder.boolValue, !SupportedFormats.isStack(url) {
                do {
                    let photos = try FolderScanner.list(url).photos.map(\.url)
                    if photos.isEmpty {
                        batch.folders.append((url, "It holds no photos Redlamp opens."))
                    }
                    for photo in photos {
                        add(photo)
                    }
                } catch {
                    batch.folders.append((url, "It couldn't be read: \(error.localizedDescription)"))
                }
            } else if SupportedFormats.isSupported(url) {
                add(url)
            } else {
                batch.failures.append((url, "Redlamp doesn't open this kind of file."))
            }
        }
        return batch
    }

    /// What a photo's name is made from, as the app reads it for a photo the library doesn't have: what its file
    /// says, with the rating, label and fields its sidecar holds.
    private static func fields(of photo: URL) -> NamingFields {
        let name = photo.lastPathComponent, folder = photo.deletingLastPathComponent().path
        let modified = (try? photo.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var fields = PhotoMetadataReader.read(url: photo).map {
            NamingFields(name: name, folder: folder, metadata: $0, modified: modified)
        } ?? NamingFields(name: name, folder: folder, modified: modified)
        if let metadata = SidecarStore().load(for: photo)?.metadata {
            fields.apply(metadata)
        }
        return fields
    }

    // MARK: - Exporting

    /// How a batch went.
    private struct Report {
        var written = 0
        var skipped = 0
        var failed = 0

        /// "Exported 12 photos to /Exports", or "Exported 10 of 12 photos to /Exports; 2 skipped, as their files
        /// were there".
        func summary(total: Int, folder: URL) -> String {
            let photos = total == 1 ? "photo" : "photos"
            var line = written == total ? "Exported \(written) \(photos)" : "Exported \(written) of \(total) \(photos)"
            line += " to \(folder.path)"
            if skipped > 0 {
                line += "; \(skipped) skipped, as \(skipped == 1 ? "its file was" : "their files were") there"
            }
            return line
        }
    }

    /// Exports each target's photo with its own edit, in an engine of the batch's own, one at a time.
    private static func export(
        _ targets: [ExportNames.Target], settings: ExportSettings, report: inout Report,
    ) async throws {
        let engine = try RedlampEngine(decoder: InProcessDecoder(), lensProfiles: .user)
        let looks = RecipeLibrary()
        for target in targets {
            if target.existing == .skipped {
                report.skipped += 1
                say("\(target.photo.path): skipped, since \(target.url.path) is there")
                continue
            }
            do {
                try await export(target, settings: settings, engine: engine, looks: looks)
                report.written += 1
                say("\(target.photo.path) → \(target.url.path)")
            } catch {
                report.failed += 1
                fail(target.photo, reason(error))
            }
            await engine.releaseResources()
        }
    }

    /// Opens `target`'s photo, renders it with the edit its sidecar holds, as shot without one, and writes it.
    private static func export(
        _ target: ExportNames.Target, settings: ExportSettings, engine: RedlampEngine, looks: RecipeLibrary,
    ) async throws {
        let url = target.photo
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "It isn't there any more: it was moved, renamed or deleted while it waited.")
        }
        let recipe: EditRecipe
        do {
            recipe = try SidecarStore().loadThrowing(for: url)?.recipe ?? EditRecipe()
        } catch {
            throw CLIError(description: "Its edit couldn't be read.")
        }
        guard !recipe.maskBitmaps.contains(where: { $0.png == nil }) else {
            throw CLIError(description: "Its masks couldn't be read from its sidecar.")
        }
        engine.expect(recipe.rawRevision, for: url)
        let info = try await engine.open(url)
        if !engine.canRender(recipe.baseLook), let look = looks.definition(for: recipe.baseLook) {
            engine.registerBaseLook(look)
        }
        guard engine.canRender(recipe.baseLook) else {
            throw CLIError(description: "Its Base Look, “\(recipe.baseLook.name)”, isn't installed.")
        }
        let request = settings.stillRequest(recipe: asShot(recipe, info), source: url, size: info.pixelSize)
        let image = try await engine.renderStill(request)
        let metadata = ExportMetadata.properties(
            from: url, reading: engine.files, policy: settings.metadata, recipe: request.recipe,
        )
        try ImageExporter.write(
            image, to: target.url, settings: settings, metadata: metadata, source: url, reading: engine.files,
        )
    }

    /// `recipe` with the camera's white balance when it's as shot, as the editor gives it.
    private static func asShot(_ recipe: EditRecipe, _ info: ImageInfo) -> EditRecipe {
        var recipe = recipe
        if recipe.whiteBalanceMode == .asShot, let wb = info.asShotWhiteBalance {
            recipe[.temperature] = wb.temperature
            recipe[.tint] = wb.tint
        }
        return recipe
    }

    // MARK: - Printing

    /// A line on standard output, shown as soon as it's printed, wherever the output goes.
    private static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private static func fail(_ path: URL, _ reason: String) {
        FileHandle.standardError.write(Data("\(path.path): \(reason)\n".utf8))
    }

    private static func reason(_ error: any Error) -> String {
        if let error = error as? CLIError {
            return error.description
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func pointing(at range: Range<Int>, in text: String, _ message: String) -> String {
        let caret = String(repeating: " ", count: range.lowerBound) + String(repeating: "^", count: max(range.count, 1))
        return "\(text)\n\(caret)\n\(message)"
    }
}
