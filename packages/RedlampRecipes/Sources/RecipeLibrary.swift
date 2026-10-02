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

    /// Named sections for a recipe list: Favorites, My Recipes, the bundled groups in
    /// order, then Installed.
    public var sections: [(name: String, recipes: [Recipe])] {
        var result: [(String, [Recipe])] = []
        let favorite = all.filter(isFavorite)
        if !favorite.isEmpty {
            result.append(("Favorites", favorite))
        }
        if !userRecipes.isEmpty {
            result.append(("My Recipes", userRecipes))
        }
        var order: [String] = []
        var grouped: [String: [Recipe]] = [:]
        for recipe in bundled {
            if grouped[recipe.group] == nil {
                order.append(recipe.group)
            }
            grouped[recipe.group, default: []].append(recipe)
        }
        result += order.map { ($0, grouped[$0] ?? []) }
        if !installed.isEmpty {
            result.append(("Installed", installed))
        }
        return result
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
        reload()
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

    /// Installs a `.redrecipe`, `.cube` or HaldCLUT image. Look tables become a recipe
    /// with an embedded Base Look.
    @discardableResult
    public func install(
        contentsOf url: URL,
        tableSpace: ImportedTableSpace = .sRGB,
    ) throws -> (recipe: Recipe, issues: [RecipeIssue]) {
        let name = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "cube":
            let cube = try LookTableImport.parseCube(String(contentsOf: url, encoding: .utf8), space: tableSpace)
            let recipe = LookTableImport.recipe(for: cube.table, name: cube.title ?? name)
            return try (save(recipe), [])
        case "png", "tif", "tiff":
            let table = try LookTableImport.parseHald(LookTableImport.readImage(url), space: tableSpace)
            return try (save(LookTableImport.recipe(for: table, name: name)), [])
        default:
            let (recipe, issues) = try RecipeFile.read(url)
            if recipe.isLocal {
                return try (save(recipe), issues)
            }
            for package in recipe.embeddedBaseLooks {
                try lookStore.save(package)
            }
            try FileManager.default.createDirectory(at: locations.installed, withIntermediateDirectories: true)
            try RecipeFile.write(recipe, to: fileURL(forInstalled: recipe))
            reload()
            return (recipe, issues)
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
