import Foundation
import Observation
import RedlampEngineAPI
import RedlampRecipes

/// The recipe library as the UI sees it: observable, and kept in step with the engine so
/// every Base Look it lists can render.
@MainActor
@Observable
public final class RecipeCatalog {
    @ObservationIgnored public let library: RecipeLibrary
    @ObservationIgnored private let engine: any EditingEngine
    /// Bumped on every change; list views observe it through the accessors below.
    public private(set) var revision = 0
    public private(set) var lastError: String?
    /// The Recipes panel's lists imports have added to since the panel last took them.
    @ObservationIgnored private var importedLists: Set<String> = []
    /// The looks given to the engine, by id, version and table hash.
    @ObservationIgnored private var registered: Set<String> = []

    public init(engine: any EditingEngine, library: RecipeLibrary = RecipeLibrary()) {
        self.engine = engine
        self.library = library
        engine.registerBaseLooks { BuiltInBaseLooks.all.compactMap { try? $0.definition() } }
        registerLooks()
    }

    private static func key(_ package: BaseLookPackage) -> String {
        "\(package.id)@\(package.version)#\(package.table?.sha256 ?? "")"
    }

    /// Registers the installed and embedded looks the engine doesn't have yet; the bundled
    /// ones never change, and are registered once at launch.
    private func registerLooks() {
        let added = (library.storedLooks + library.all.flatMap(\.embeddedBaseLooks))
            .filter { registered.insert(Self.key($0)).inserted }
        guard !added.isEmpty else { return }
        engine.registerBaseLooks { added.compactMap { try? $0.definition() } }
    }

    private func changed() {
        registerLooks()
        revision &+= 1
    }

    public func reload() {
        library.reload()
        changed()
    }

    // MARK: - Reading

    public var sections: [(name: String, recipes: [Recipe])] {
        _ = revision
        return library.sections
    }

    public var all: [Recipe] {
        _ = revision
        return library.all
    }

    /// Every Base Look version, including older ones edits have pinned.
    public var baseLooks: [BaseLookPackage] {
        _ = revision
        return library.baseLooks
    }

    /// Each look once, at its newest version: what menus and the browser offer. Looks
    /// embedded in photos are offered only with their photo.
    public var currentBaseLooks: [BaseLookPackage] {
        BuiltInBaseLooks.newest(baseLooks).filter { !$0.reference.isEmbedded }
    }

    /// The lists imports have added to since the last call, for the panel to open once.
    public func takeImportedLists() -> Set<String> {
        defer { importedLists = [] }
        return importedLists
    }

    public func recipe(id: String) -> Recipe? {
        _ = revision
        return library.recipe(id: id)
    }

    public func search(_ query: String) -> [Recipe] {
        _ = revision
        return library.search(query)
    }

    public func isFavorite(_ recipe: Recipe) -> Bool {
        _ = revision
        return library.isFavorite(recipe)
    }

    public func package(for reference: BaseLookReference) -> BaseLookPackage? {
        library.package(for: reference)
    }

    public func isUserRecipe(_ recipe: Recipe) -> Bool {
        library.userRecipes.contains { $0.id == recipe.id } || library.installed.contains { $0.id == recipe.id }
    }

    /// Whether an edit's Base Look can render exactly here.
    public func isAvailable(_ reference: BaseLookReference) -> Bool {
        engine.canRender(reference) || library.isAvailable(reference)
    }

    /// Makes a recipe's embedded looks renderable before it is previewed or applied.
    public func prepare(_ recipe: Recipe) {
        for package in recipe.embeddedBaseLooks where registered.insert(Self.key(package)).inserted {
            if let definition = try? package.definition() {
                engine.registerBaseLook(definition)
            }
        }
    }

    // MARK: - Changing

    /// Keeps a look with the installed ones, so edits that use it render without its source,
    /// such as a photo's embedded camera profile look.
    public func remember(_ look: BaseLookDefinition) {
        guard package(for: look.reference) == nil else { return }
        perform {
            try library.lookStore.save(BaseLookPackage(
                id: look.id, version: look.version, name: look.name, parameters: look.parameters, table: look.table,
            ))
            library.reload()
        }
    }

    @discardableResult
    public func save(_ recipe: Recipe) -> Recipe? {
        perform { try library.save(recipe) }
    }

    /// Installs the files `RecipeLibrary.read(importing:)` read, reading the library once; what
    /// came in, with each preset's report, and what didn't, with the reasons.
    @discardableResult
    public func install(_ read: RecipeImportSummary) -> RecipeImportSummary {
        let summary = library.install(read)
        importedLists.formUnion(summary.lists)
        lastError = nil
        changed()
        return summary
    }

    public func delete(_ recipe: Recipe) {
        perform { try library.delete(recipe) }
    }

    public func setFavorite(_ recipe: Recipe, _ favorite: Bool) {
        perform { try library.setFavorite(recipe, favorite) }
    }

    public func export(_ recipe: Recipe, to url: URL) {
        perform { try library.export(recipe, to: url) }
    }

    @discardableResult
    private func perform<T>(_ work: () throws -> T) -> T? {
        do {
            let result = try work()
            lastError = nil
            changed()
            return result
        } catch {
            lastError = "\(error)"
            revision &+= 1
            return nil
        }
    }
}
