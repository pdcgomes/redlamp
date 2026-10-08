import CoreGraphics
import Foundation
import RedlampEngineAPI

/// Every recipe and Base Look available on this machine: bundled, made here, and
/// installed from files.
///
/// On disk, under Application Support/Redlamp:
/// - `Recipes/*.redrecipe`: recipes made here (the `local/` namespace);
/// - `Recipes/Installed/*.redrecipe`: recipes installed from files;
/// - `Recipes/favorites.json`: favorite recipe ids;
/// - `Looks/`: every Base Look ever installed, by content (see `LookStore`).
public final class RecipeLibrary {
    public struct Locations: Sendable {
        public var recipes: URL
        public var installed: URL
        public var favorites: URL
        public var looks: URL

        public init(root: URL) {
            recipes = root.appendingPathComponent("Recipes", isDirectory: true)
            installed = recipes.appendingPathComponent("Installed", isDirectory: true)
            favorites = recipes.appendingPathComponent("favorites.json")
            looks = root.appendingPathComponent("Looks", isDirectory: true)
        }
    }

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Redlamp", isDirectory: true)
    }

    public let locations: Locations
    public let lookStore: LookStore
    private let includeBundled: Bool

    public private(set) var bundled: [Recipe] = []
    public private(set) var userRecipes: [Recipe] = []
    public private(set) var installed: [Recipe] = []
    public private(set) var favorites: Set<String> = []
    public private(set) var storedLooks: [BaseLookPackage] = []
    /// Files that couldn't be read, with the reasons.
    public private(set) var loadIssues: [URL: [RecipeIssue]] = [:]

    public init(root: URL = RecipeLibrary.defaultRoot, includeBundled: Bool = true) {
        locations = Locations(root: root)
        lookStore = LookStore(directory: locations.looks)
        self.includeBundled = includeBundled
        reload()
    }

    public func reload() {
        loadIssues = [:]
        bundled = includeBundled ? BuiltInRecipes.all : []
        userRecipes = readRecipes(in: locations.recipes)
        installed = readRecipes(in: locations.installed)
        storedLooks = lookStore.all()
        if let data = try? Data(contentsOf: locations.favorites),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            favorites = Set(ids)
        } else {
            favorites = []
        }
    }

    private func readRecipes(in directory: URL) -> [Recipe] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == Recipe.fileExtension }
            .compactMap { url in
                do {
                    let (recipe, issues) = try RecipeFile.read(url)
                    if !issues.isEmpty {
                        loadIssues[url] = issues
                    }
                    return recipe
                } catch let error as RecipeValidationError {
                    loadIssues[url] = error.issues
                    return nil
                } catch {
                    loadIssues[url] = [RecipeIssue(.error, "\(error)")]
                    return nil
                }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Recipes

    /// Every recipe: bundled, then made here, then installed.
    public var all: [Recipe] {
        bundled + userRecipes + installed
    }

    public func recipe(id: String) -> Recipe? {
        all.last { $0.id == id }
    }

    public func isFavorite(_ recipe: Recipe) -> Bool {
        favorites.contains(recipe.id)
    }

    public func setFavorite(_ recipe: Recipe, _ favorite: Bool) throws {
        if favorite {
            favorites.insert(recipe.id)
        } else {
            favorites.remove(recipe.id)
        }
        try FileManager.default.createDirectory(at: locations.recipes, withIntermediateDirectories: true)
        try JSONEncoder().encode(favorites.sorted()).write(to: locations.favorites, options: .atomic)
    }

    /// Named sections for a recipe list: Favorites, your recipes in their lists (My Recipes
    /// first, then the others by name), the bundled groups in order, then Installed. A list
    /// of yours named like a bundled group is listed with it.
    public var sections: [(name: String, recipes: [Recipe])] {
        var result: [(String, [Recipe])] = []
        let favorite = all.filter(isFavorite)
        if !favorite.isEmpty {
            result.append(("Favorites", favorite))
        }
        let mine = Dictionary(grouping: userRecipes, by: Self.list(for:))
        var order: [String] = []
        var grouped: [String: [Recipe]] = [:]
        for recipe in bundled {
            if grouped[recipe.group] == nil {
                order.append(recipe.group)
            }
            grouped[recipe.group, default: []].append(recipe)
        }
        let lists = mine.keys.filter { $0 != Self.myRecipes && grouped[$0] == nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for list in [Self.myRecipes] + lists {
            if let recipes = mine[list] {
                result.append((list, recipes))
            }
        }
        result += order.map { ($0, (grouped[$0] ?? []) + (mine[$0] ?? [])) }
        if !installed.isEmpty {
            result.append(("Installed", installed))
        }
        return result
    }

    static let myRecipes = "My Recipes"

    /// The list one of your recipes appears in: its group, or My Recipes when the group is
    /// empty or names one of the other sections.
    static func list(for recipe: Recipe) -> String {
        let group = recipe.group.trimmingCharacters(in: .whitespacesAndNewlines)
        return group.isEmpty || ["Favorites", "Installed"].contains(group) ? myRecipes : group
    }

    /// Recipes matching `query` by name, group, tag or summary. Lightroom's words work as
    /// aliases: "preset" finds every recipe, "profile" the ones with a Base Look, "LUT"
    /// or "cube" the ones built on a look table.
    public func search(_ query: String) -> [Recipe] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return all }
        return all.filter { recipe in
            terms.allSatisfy { term in
                switch term {
                case "preset", "presets", "recipe", "recipes": true
                case "profile", "profiles", "base", "look", "looks": recipe.includes.contains(.baseLook)
                case "lut", "luts", "cube", "clut", "hald": recipe.usesLookTable
                default:
                    ([recipe.name, recipe.group, recipe.summary ?? ""] + recipe.tags)
                        .contains { $0.lowercased().contains(term) }
                }
            }
        }
    }

    /// Saves a recipe made here. Saving an existing one publishes it as a new version,
    /// so edits made with the old version are unaffected.
    @discardableResult
    public func save(_ recipe: Recipe) throws -> Recipe {
        let saved = try storeLocal(recipe)
        reload()
        return saved
    }

    /// Saves a recipe made here without reading the library again. Recipes made here are
    /// kept up to date in memory, so saving one twice before the next reload still publishes
    /// a new version.
    private func storeLocal(_ recipe: Recipe) throws -> Recipe {
        var recipe = recipe
        if !recipe.isLocal {
            recipe.id = RecipeNamespace.newLocalID()
            recipe.version = 1
        } else if let existing = userRecipes.first(where: { $0.id == recipe.id }), existing != recipe {
            recipe.version = max(recipe.version, existing.version + 1)
        }
        let (validated, issues) = RecipeValidator.validate(recipe)
        if issues.contains(where: { $0.severity == .error }) {
            throw RecipeValidationError(issues: issues)
        }
        for package in validated.embeddedBaseLooks {
            try lookStore.save(package)
        }
        try FileManager.default.createDirectory(at: locations.recipes, withIntermediateDirectories: true)
        try RecipeFile.write(validated, to: fileURL(forLocal: validated))
        userRecipes.removeAll { $0.id == validated.id }
        userRecipes.append(validated)
        return validated
    }

    private func fileURL(forLocal recipe: Recipe) -> URL {
        let slug = recipe.id.split(separator: "/").dropFirst().joined(separator: "-")
        return locations.recipes.appendingPathComponent("\(slug).\(Recipe.fileExtension)")
    }

    private func fileURL(forInstalled recipe: Recipe) -> URL {
        let slug = recipe.id.replacingOccurrences(of: "/", with: "~")
        return locations.installed.appendingPathComponent("\(slug)@\(recipe.version).\(Recipe.fileExtension)")
    }

    // MARK: - Importing

    /// Installs a file as `read(importing:)` reads it: a `.redrecipe`, a Lightroom develop
    /// preset, or a `.cube`, `.3dl` or HaldCLUT look table made for `tableSpace`. For a
    /// preset's report, install what `read(importing:)` returns.
    @discardableResult
    public func install(
        contentsOf url: URL,
        tableSpace: ImportedTableSpace = .sRGB,
        reading files: any FileInspecting,
    ) throws -> (recipe: Recipe, issues: [RecipeIssue]) {
        let installed = try install(Self.read(importing: url, tableSpace: tableSpace, reading: files))
        return (installed.recipe, installed.issues)
    }

    /// Installs a file `read(importing:)` read. Recipes made or converted here (look tables
    /// and presets) join yours; other recipe files are installed as they are. Returns the
    /// recipe as installed, with the file's issues and a preset's report.
    @discardableResult
    public func install(_ imported: RecipeImport) throws -> RecipeImport {
        var installed = imported
        installed.recipe = try store(imported)
        reload()
        return installed
    }

    /// Installs the files `read(importing:)` read, reading the library again once at the end.
    /// A file that can't be installed is listed with the reason, and the rest still install.
    public func install(_ summary: RecipeImportSummary) -> RecipeImportSummary {
        var summary = summary
        for index in summary.items.indices {
            guard case let .imported(imported) = summary.items[index].outcome else { continue }
            do {
                var installed = imported
                installed.recipe = try store(imported)
                summary.items[index].outcome = .imported(installed)
            } catch {
                summary.items[index].outcome = .failed(Self.reason(error))
            }
        }
        reload()
        return summary
    }

    /// Installs files, and the Lightroom presets in folders, as `install(_:)` does, reading
    /// the library again once at the end; what came in and what didn't.
    public func install(
        contentsOf urls: [URL],
        tableSpace: ImportedTableSpace = .sRGB,
        reading files: any FileInspecting,
    ) -> RecipeImportSummary {
        install(Self.read(importing: urls, tableSpace: tableSpace, reading: files))
    }

    private func store(_ imported: RecipeImport) throws -> Recipe {
        let recipe = imported.recipe
        if recipe.isLocal || imported.report != nil {
            return try storeLocal(recipe)
        }
        for package in recipe.embeddedBaseLooks {
            try lookStore.save(package)
        }
        try FileManager.default.createDirectory(at: locations.installed, withIntermediateDirectories: true)
        try RecipeFile.write(recipe, to: fileURL(forInstalled: recipe))
        return recipe
    }

    /// Reads a file to import as a recipe, without installing it: a `.redrecipe`, a Lightroom
    /// develop preset, or a `.cube`, `.3dl` or HaldCLUT look table made for `tableSpace`. A
    /// preset is recognised by its content (`LightroomPreset.isPreset`), so a photo's `.xmp`
    /// sidecar isn't taken for one. A look table or preset is named `name`, or by its own
    /// name, or the file's. `files` decodes a HaldCLUT image.
    public static func read(
        importing url: URL,
        tableSpace: ImportedTableSpace = .sRGB,
        name: String? = nil,
        reading files: any FileInspecting,
    ) throws -> RecipeImport {
        if let imported = try lookTable(contentsOf: url, tableSpace: tableSpace, reading: files) {
            let name = name ?? imported.title ?? url.deletingPathExtension().lastPathComponent
            return RecipeImport(recipe: LookTableImport.recipe(for: imported.table, name: name))
        }
        let kind = url.pathExtension.lowercased()
        if kind != Recipe.fileExtension {
            let data = try contents(of: url)
            if LightroomPreset.isPreset(data) {
                return try RecipeImport(LightroomPreset.convert(data, name: name), file: url)
            }
            if kind == "xmp" {
                throw LightroomPresetError.notAPreset
            }
        }
        let (recipe, issues) = try RecipeFile.read(url)
        return RecipeImport(recipe: recipe, issues: issues)
    }

    /// Reads files, and the Lightroom presets in folders and their subfolders, as
    /// `read(importing:)` reads each. A file that can't be read, or a folder without presets,
    /// is listed with the reason.
    public static func read(
        importing urls: [URL],
        tableSpace: ImportedTableSpace = .sRGB,
        reading files: any FileInspecting,
    ) -> RecipeImportSummary {
        var items: [RecipeImportSummary.Item] = []
        var seen = Set<String>()
        for url in urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            let found = isFolder.boolValue ? presets(in: url) : [url]
            if found.isEmpty {
                items.append(.init(file: url, outcome: .failed("There are no Lightroom presets in this folder")))
            }
            for file in found where seen.insert(file.standardizedFileURL.path).inserted {
                do {
                    try items.append(.init(
                        file: file,
                        outcome: .imported(read(importing: file, tableSpace: tableSpace, reading: files)),
                    ))
                } catch {
                    items.append(.init(file: file, outcome: .failed(reason(error))))
                }
            }
        }
        return RecipeImportSummary(items: items)
    }

    /// The Lightroom develop presets in a folder and its subfolders, in path order: the
    /// `.xmp` files `LightroomPreset.isPreset` accepts, so photos' sidecars are left out.
    public static func presets(in folder: URL) -> [URL] {
        let files = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        )
        var found: [URL] = []
        while let url = files?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "xmp", let data = try? contents(of: url),
               LightroomPreset.isPreset(data) {
                found.append(url)
            }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// A file's bytes, refused past the size a recipe file may have.
    private static func contents(of url: URL) throws -> Data {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > RecipeValidator.maximumFileSize {
            throw RecipeValidationError(issues: [RecipeIssue(.error, "the file is larger than 16 MB")])
        }
        return try Data(contentsOf: url)
    }

    /// Why a file didn't come in, as a sentence.
    static func reason(_ error: any Error) -> String {
        let text = error is CocoaError ? error.localizedDescription : "\(error)"
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The look table in a `.cube` or `.3dl` file or a HaldCLUT image made for `tableSpace`,
    /// with the title a `.cube` may give it; nil for any other file. `files` decodes the image.
    public static func lookTable(
        contentsOf url: URL,
        tableSpace: ImportedTableSpace = .sRGB,
        reading files: any FileInspecting,
    ) throws -> (table: LookTable, title: String?)? {
        switch url.pathExtension.lowercased() {
        case "cube":
            let cube = try LookTableImport.parseCube(String(contentsOf: url, encoding: .utf8), space: tableSpace)
            return (cube.table, cube.title)
        case "3dl":
            return try (LookTableImport.parse3DL(String(contentsOf: url, encoding: .utf8), space: tableSpace), nil)
        case "png", "tif", "tiff":
            guard let image = files.haldImage(of: url) else { throw LookTableImportError.unreadableImage }
            return try (LookTableImport.parseHald(image, space: tableSpace), nil)
        default:
            return nil
        }
    }

    /// Removes a recipe made here or installed. Its Base Looks stay, so edits made with
    /// it keep rendering.
    public func delete(_ recipe: Recipe) throws {
        if userRecipes.contains(where: { $0.id == recipe.id }) {
            try? FileManager.default.removeItem(at: fileURL(forLocal: recipe))
        }
        for candidate in installed where candidate.id == recipe.id {
            try? FileManager.default.removeItem(at: fileURL(forInstalled: candidate))
        }
        if favorites.contains(recipe.id) {
            try setFavorite(recipe, false)
        }
        reload()
    }

    /// A self-contained copy for sharing: the Base Look travels inside the file, unless it
    /// came from a photo's camera profile, whose maker's terms Redlamp doesn't pass on.
    public func exportable(_ recipe: Recipe) -> Recipe {
        var recipe = recipe
        if let look = recipe.baseLook, !recipe.embeddedBaseLooks.contains(where: { $0.matches(look) }),
           BuiltInBaseLook(reference: look) == nil, !look.isEmbedded,
           let package = package(for: look) {
            recipe.embeddedBaseLooks.append(package)
        }
        return recipe
    }

    public func export(_ recipe: Recipe, to url: URL) throws {
        try RecipeFile.write(exportable(recipe), to: url)
    }

    // MARK: - Base Looks

    /// Every Base Look: bundled, then installed ones not already listed.
    public var baseLooks: [BaseLookPackage] {
        var seen = Set<String>()
        var result: [BaseLookPackage] = []
        let embedded = all.flatMap(\.embeddedBaseLooks)
        for package in BuiltInBaseLooks.all + storedLooks + embedded {
            let key = "\(package.id)@\(package.version)#\(package.table?.sha256 ?? "")"
            if seen.insert(key).inserted {
                result.append(package)
            }
        }
        return result
    }

    public func package(for reference: BaseLookReference) -> BaseLookPackage? {
        baseLooks.first { $0.matches(reference) }
    }

    /// What the engine needs to render `reference`, if it's available here.
    public func definition(for reference: BaseLookReference) -> BaseLookDefinition? {
        if let builtIn = BuiltInBaseLook(reference: reference) {
            return builtIn.definition
        }
        return try? package(for: reference)?.definition()
    }

    /// Whether an edit's Base Look can be rendered exactly on this machine.
    public func isAvailable(_ reference: BaseLookReference) -> Bool {
        definition(for: reference) != nil
    }

    /// Every look the engine should know about, for registering at launch.
    public func definitions() -> [BaseLookDefinition] {
        baseLooks.compactMap { try? $0.definition() }
    }
}

/// A file brought in as a recipe: a `.redrecipe`, a Lightroom develop preset, or a look table.
public struct RecipeImport: Sendable, Equatable {
    public var recipe: Recipe
    /// What the file's checks found that didn't stop it coming in, such as a value brought
    /// into range.
    public var issues: [RecipeIssue]
    /// For a Lightroom preset, how each of its settings was carried over.
    public var report: LightroomImportReport?

    public init(recipe: Recipe, issues: [RecipeIssue] = [], report: LightroomImportReport? = nil) {
        self.recipe = recipe
        self.issues = issues
        self.report = report
    }

    /// A converted Lightroom preset as a recipe made here: named after its file when the
    /// preset has no name, and listed in the preset's own group, or "Lightroom".
    public init(_ converted: LightroomPresetImport, file: URL) throws {
        var recipe = converted.recipe
        if !recipe.isLocal {
            recipe.id = RecipeNamespace.newLocalID()
            recipe.version = 1
        }
        if recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recipe.name = file.deletingPathExtension().lastPathComponent
        }
        if Self.defaultGroups.contains(recipe.group.trimmingCharacters(in: .whitespacesAndNewlines)) {
            recipe.group = "Lightroom"
        }
        let (validated, issues) = RecipeValidator.validate(recipe)
        if issues.contains(where: { $0.severity == .error }) {
            throw RecipeValidationError(issues: issues)
        }
        self.init(recipe: validated, issues: issues, report: converted.report)
    }

    /// Groups a new recipe gets from Redlamp rather than from the preset.
    private static let defaultGroups: Set<String> = ["", "My Recipes", "Recipes", "Imported"]
}

/// What importing files brought in and what didn't, as the Recipes panel's import summary
/// and `redlamp recipe import` show it.
public struct RecipeImportSummary: Sendable {
    public enum Outcome: Sendable {
        /// The file as a recipe; installed, when the summary comes from installing.
        case imported(RecipeImport)
        /// Why the file didn't come in.
        case failed(String)
    }

    public struct Item: Sendable {
        public var file: URL
        public var outcome: Outcome

        public init(file: URL, outcome: Outcome) {
            self.file = file
            self.outcome = outcome
        }
    }

    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    public var imported: [RecipeImport] {
        items.compactMap { item -> RecipeImport? in
            if case let .imported(imported) = item.outcome {
                imported
            } else {
                nil
            }
        }
    }

    /// Each file that didn't come in, with the reason: "Old.xmp: Lightroom process version …".
    public var failures: [String] {
        items.compactMap { item -> String? in
            if case let .failed(reason) = item.outcome {
                "\(item.file.lastPathComponent): \(reason)"
            } else {
                nil
            }
        }
    }

    /// What came in: "Imported 3 Lightroom presets", or "Imported 3 recipes, 2 of them from
    /// Lightroom presets".
    public var headline: String {
        let imported = imported
        guard !imported.isEmpty else { return "Nothing was imported" }
        let presets = imported.filter { $0.report != nil }.count
        if presets == imported.count {
            return "Imported \(Self.count(presets, "Lightroom preset"))"
        }
        let recipes = "Imported \(Self.count(imported.count, "recipe"))"
        return presets == 0 ? recipes : "\(recipes), \(presets) of them from Lightroom presets"
    }

    /// The Recipes panel's lists the installed recipes appear in, in import order.
    public var lists: [String] {
        var lists: [String] = []
        for recipe in imported.map(\.recipe) {
            let list = recipe.isLocal ? RecipeLibrary.list(for: recipe) : "Installed"
            if !lists.contains(list) {
                lists.append(list)
            }
        }
        return lists
    }

    /// Where the installed recipes are listed: "In the Recipes panel under Lightroom".
    public var placement: String? {
        let lists = lists
        return lists.isEmpty ? nil : "In the Recipes panel under \(Self.joined(lists))"
    }

    /// A title for the files that didn't come in.
    public var failureTitle: String {
        if imported.isEmpty {
            "Nothing was imported"
        } else if failures.count == 1 {
            "A file couldn't be imported"
        } else {
            "Some files couldn't be imported"
        }
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// "A", "A and B", "A, B and C".
    static func joined(_ words: [String]) -> String {
        guard let last = words.last, words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + last
    }
}

public extension RecipeImportSummary.Item {
    /// The item as `redlamp recipe import` prints it: what the file became, then its issues
    /// and a preset's report, indented; or why it didn't come in.
    var text: String {
        switch outcome {
        case let .failed(reason):
            return "\(file.lastPathComponent): \(reason)"
        case let .imported(imported):
            let heading = "\(file.lastPathComponent) → \(imported.recipe.group) / \(imported.recipe.name)"
            let report = imported.report.map { LightroomReportSummary($0).lines } ?? []
            return ([heading] + (imported.issues.map(\.description) + report).map { "  " + $0 })
                .joined(separator: "\n")
        }
    }
}

/// A Lightroom preset's report in words, as the Recipes panel's import summary and
/// `redlamp recipe import` show it: a tally, then each setting with its note under what
/// happened to it.
public struct LightroomReportSummary: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        public var outcome: LightroomImportReport.Outcome
        /// One line a setting: its name, then its note.
        public var lines: [String]

        /// "Approximated", "Ignored" or "Mapped".
        public var title: String {
            switch outcome {
            case .mapped: "Mapped"
            case .approximated: "Approximated"
            case .ignored: "Ignored"
            }
        }
    }

    /// How many settings had each outcome: "12 mapped, 2 approximated, 3 ignored".
    public var tally: String
    /// What was approximated, then ignored, then mapped: only outcomes some setting had.
    public var sections: [Section]
    /// The preset's `crs:ProcessVersion`, if it has one.
    public var processVersion: String?

    public init(_ report: LightroomImportReport) {
        let outcomes: [LightroomImportReport.Outcome] = [.approximated, .ignored, .mapped]
        sections = outcomes.compactMap { outcome in
            let entries = report.entries(outcome)
            return entries.isEmpty ? nil : Section(outcome: outcome, lines: entries.map(Self.line))
        }
        let counts = LightroomImportReport.Outcome.allCases.compactMap { outcome in
            let count = report.entries(outcome).count
            return count == 0 ? nil : "\(count) \(Section(outcome: outcome, lines: []).title.lowercased())"
        }
        tally = counts.isEmpty ? "No settings" : counts.joined(separator: ", ")
        processVersion = report.processVersion
    }

    private static func line(_ entry: LightroomImportReport.Entry) -> String {
        guard let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return entry.setting
        }
        return "\(entry.setting): \(note)"
    }

    /// The report as plain text: the tally with the preset's process version, then each
    /// section's settings, indented under its title.
    public var lines: [String] {
        let version = processVersion.map { " (Lightroom process version \($0))" } ?? ""
        return ["\(tally)\(version)"] + sections.flatMap { section in
            ["\(section.title):"] + section.lines.map { "  " + $0 }
        }
    }
}
