import CoreGraphics
import RedlampEngineAPI
import RedlampRecipes
import SwiftUI

/// The Film Looks window: every film stock look as a card showing the current photo in it.
/// Hover previews a look in the editor; click applies it, with its grain, halation and bloom.
/// Previews render one after another at low priority, so the editor stays responsive.
public struct FilmCatalogView: View {
    public static let windowID = "film-looks"

    @Environment(EditorModel.self) private var model
    @State private var previews: [String: CGImage] = [:]
    @State private var filter = Filter.all
    @State private var hovered: String?

    public init() {}

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case colour = "Colour Negative"
        case cinema = "Cinema"
        case slide = "Slide"
        case monochrome = "Black & White"

        var id: String {
            rawValue
        }

        func includes(_ look: FilmLookDefinition) -> Bool {
            switch self {
            case .all: true
            case .colour: !look.isMonochrome && look.icon.shape == .canister && !look.film.contains("cinestill")
            case .cinema: look.icon.shape == .reel || look.film.contains("cinestill")
            case .slide: look.icon.shape == .slide
            case .monochrome: look.isMonochrome
            }
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)]
    private static let previewEdge = 640

    public var body: some View {
        let entries = FilmLookCatalog.looks.compactMap { look in
            model.recipes.recipe(id: look.recipeID).map { (look, $0) }
        }
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
                    ForEach(entries.filter { filter.includes($0.0) }, id: \.0.id) { look, recipe in
                        card(look, recipe)
                    }
                }
                .padding(16)
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No film looks installed", systemImage: "film",
                        description: Text("This build doesn't bundle the film stock tables."),
                    )
                }
            }
        }
        .task(id: model.info?.url) {
            previews = [:]
            await renderPreviews(entries.map(\.1))
        }
        .onDisappear { model.previewRecipe(nil) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Film Looks").font(.title2.weight(.semibold))
                Text(model.info == nil
                    ? "Open a photo to see it in each film."
                    : "Built from the makers' datasheets. Hover to preview in the editor; click to apply.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let amount = model.recipeAmount, let title = model.recipeAmountTitle,
               FilmLookCatalog.looks.contains(where: { $0.name == title }) {
                HStack(spacing: 8) {
                    Text(title).font(.callout)
                    Slider(
                        value: Binding(get: { amount }, set: { model.setRecipeAmount($0) }), in: 0 ... 200,
                        onEditingChanged: { editing in editing ? model.beginEdit() : model.endEdit() },
                    )
                    .frame(width: 160)
                    Text("\(Int(amount))").monospacedDigit().frame(width: 32, alignment: .trailing)
                }
            }
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func card(_ look: FilmLookDefinition, _ recipe: Recipe) -> some View {
        let applied = model.appliedRecipe?.id == recipe.id
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3))
                if let image = previews[recipe.id] {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
                } else if model.info != nil {
                    ProgressView().controlSize(.small)
                } else if let icon = FilmIconImage.image(for: look, points: 96) {
                    Image(nsImage: icon)
                }
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(applied ? Color.accentColor : hovered == look.id ? Color.secondary : .clear, lineWidth: 2),
            )
            HStack(alignment: .center, spacing: 10) {
                if let icon = FilmIconImage.image(for: look, points: 36) {
                    Image(nsImage: icon)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(look.name).font(.headline)
                    Text("\(look.maker) · \(look.format)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if applied {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        .help("Applied to this photo")
                }
            }
            Text(look.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            Text(effectsLine(look)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovered == look.id ? 0.07 : 0.04)))
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside ? look.id : (hovered == look.id ? nil : hovered)
            guard model.info != nil else { return }
            model.previewRecipe(inside ? recipe : nil)
        }
        .onTapGesture {
            guard model.info != nil else { return }
            model.applyRecipe(recipe)
        }
        .help(model.info == nil ? look.summary : "Click to apply \(look.name)")
    }

    private func effectsLine(_ look: FilmLookDefinition) -> String {
        let parts: [(String, ParameterID)] = [("Grain", .grainAmount), ("Halation", .halationAmount), ("Bloom", .bloomAmount)]
        return parts.compactMap { name, parameter in
            look.effects[parameter].map { "\(name) \(Int($0))" }
        }.joined(separator: " · ")
    }

    private func renderPreviews(_ recipes: [Recipe]) async {
        guard model.info != nil else { return }
        for recipe in recipes where previews[recipe.id] == nil {
            if Task.isCancelled {
                return
            }
            model.recipes.prepare(recipe)
            var request = StillRequest(recipe: model.previewEdit(for: recipe))
            request.maxLongEdge = Self.previewEdge
            if let image = try? await model.engine.renderStill(request) {
                previews[recipe.id] = image
            }
            await Task.yield()
        }
    }
}
