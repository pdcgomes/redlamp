import CoreGraphics
import RedlampEngineAPI
import RedlampRecipes
import SwiftUI

/// Base Looks sorted into the browser's and menu's sections.
struct BaseLookGroups {
    var sections: [(name: String, looks: [BaseLookPackage])]

    init(_ looks: [BaseLookPackage]) {
        let reproduction = looks.filter { $0.id == BuiltInBaseLook.reproduction.rawValue }
        let builtIn = looks.filter { BuiltInBaseLook(rawValue: $0.id).map { $0 != .reproduction } ?? false }
        let catalogue = FilmLookCatalog.looks.map(\.baseLookID)
        let stocks = looks.filter { catalogue.contains($0.id) }
            .sorted { (catalogue.firstIndex(of: $0.id) ?? 0) < (catalogue.firstIndex(of: $1.id) ?? 0) }
        let film = looks.filter {
            BuiltInBaseLook(rawValue: $0.id) == nil && $0.id.hasPrefix(RecipeNamespace.bundled + "/")
                && !catalogue.contains($0.id)
        }
        let other = looks.filter { !$0.id.hasPrefix(RecipeNamespace.bundled + "/") }
        sections = [
            ("Redlamp", builtIn), ("Film Stocks", stocks), ("Film Styles", film), ("Installed", other),
            ("Reproduction", reproduction),
        ].filter { !$0.1.isEmpty }
    }

    /// The catalogue's current looks, sorted once for each change to it rather than for each
    /// update of a menu that shows them.
    @MainActor static func current(in recipes: RecipeCatalog) -> BaseLookGroups {
        let revision = recipes.revision
        if let last = Cache.last, last.catalog === recipes, last.revision == revision {
            return last.groups
        }
        let groups = BaseLookGroups(recipes.currentBaseLooks)
        Cache.last = Cache(catalog: recipes, revision: revision, groups: groups)
        return groups
    }

    @MainActor private final class Cache {
        static var last: Cache?
        weak var catalog: RecipeCatalog?
        let revision: Int
        let groups: BaseLookGroups

        init(catalog: RecipeCatalog, revision: Int, groups: BaseLookGroups) {
            self.catalog = catalog
            self.revision = revision
            self.groups = groups
        }
    }
}

/// Every Base Look rendered on the current photo, as Lightroom's Profile Browser.
/// Thumbnails render one after another at low priority, so editing stays responsive.
struct BaseLookBrowser: View {
    @Environment(EditorModel.self) private var model
    @State private var thumbnails: [String: CGImage] = [:]

    private static let columns = [GridItem(.adaptive(minimum: 116), spacing: 10)]

    var body: some View {
        let groups = BaseLookGroups.current(in: model.recipes)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups.sections, id: \.name) { section in
                    Text(section.name).font(.headline)
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                        ForEach(section.looks, id: \.self) { look in
                            tile(look)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 420, height: 520)
        .task(id: model.info?.url) { await renderThumbnails(groups.sections.flatMap(\.looks)) }
        .onDisappear { model.previewRecipe(nil) }
    }

    private func key(_ look: BaseLookPackage) -> String {
        "\(look.id)@\(look.version)#\(look.table?.sha256 ?? "")"
    }

    private func tile(_ look: BaseLookPackage) -> some View {
        let selected = look.matches(model.baseLook)
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25))
                if let image = thumbnails[key(look)] {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 78)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .overlay(alignment: .topLeading) {
                if let icon = FilmIconImage.image(for: look.id, points: 22) {
                    Image(nsImage: icon).padding(3)
                }
            }
            Text(look.name).font(.caption).lineLimit(1)
        }
        .help(look.summary ?? look.name)
        .contentShape(Rectangle())
        .onTapGesture { model.setBaseLook(look.reference) }
        .onHover { inside in
            model.previewRecipe(inside ? Self.previewRecipe(for: look) : nil)
        }
    }

    static func previewRecipe(for look: BaseLookPackage) -> Recipe {
        Recipe(
            id: "local/base-look-preview", name: look.name, group: "", includes: [.baseLook],
            settings: RecipeSettings(), baseLook: look.reference, embeddedBaseLooks: look.table == nil ? [] : [look],
        )
    }

    private func renderThumbnails(_ looks: [BaseLookPackage]) async {
        guard model.info != nil else { return }
        let base = model.recipe
        for look in looks where thumbnails[key(look)] == nil {
            if Task.isCancelled {
                return
            }
            var recipe = base
            recipe.baseLook = look.reference.withAmount(100)
            if look.parameters.isMonochrome {
                recipe.treatment = .blackAndWhite
            }
            var request = StillRequest(recipe: recipe)
            request.maxLongEdge = 232
            if let image = try? await model.engine.renderStill(request) {
                thumbnails[key(look)] = image
            }
            await Task.yield()
        }
    }
}

@_spi(Harness) public enum BaseLookPreviews {
    /// The recipe that previews `look` alone, as hovering it in the browser does.
    @MainActor public static func recipe(for look: BaseLookPackage) -> Recipe {
        BaseLookBrowser.previewRecipe(for: look)
    }
}
