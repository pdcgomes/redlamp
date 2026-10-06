import Foundation
import RedlampEngineAPI
import RedlampRecipes

/// The palette's rows: what each level lists, and how a query ranks them.
@MainActor
enum PaletteCatalog {
    /// The sections a level shows for `query`: browsable sections when it's empty, one
    /// ranked list otherwise.
    static func sections(
        page: PalettePage?, scope: PaletteScope, query: String, editor: EditorModel,
    ) -> [PaletteSection] {
        if let page {
            return pageSections(page, query: query, editor: editor)
        }
        let words = SearchMatcher.words(query)
        guard !words.isEmpty else {
            return browsingSections(scope: scope, editor: editor)
        }
        var candidates = scope == .sliders ? sliderItems : searchableItems(editor: editor)
        candidates = rank(candidates, query: query, words: words)
        return [PaletteSection(title: nil, items: typedValues(query, editor: editor) + candidates)]
    }

    private struct Match {
        let item: PaletteItem
        let score: Int
        let isExactTitle: Bool
        let order: Int

        func ranks(before other: Match) -> Bool {
            if score != other.score {
                return score > other.score
            }
            if isExactTitle != other.isExactTitle {
                return isExactTitle
            }
            if item.kind.rank != other.item.kind.rank {
                return item.kind.rank < other.item.kind.rank
            }
            return order < other.order
        }
    }

    /// Orders `items` by match strength, then exact titles, then kind, then catalogue order.
    static func rank(_ items: [PaletteItem], query: String, words: [String]) -> [PaletteItem] {
        let exact = SearchMatcher.normalized(query)
        let matches = items.enumerated().compactMap { offset, item -> Match? in
            let terms = [item.title, item.context] + item.keywords
            guard let score = SearchMatcher.score(words, terms: terms) else { return nil }
            return Match(
                item: item,
                score: score,
                isExactTitle: SearchMatcher.normalized(item.title) == exact,
                order: offset,
            )
        }
        return matches.sorted { $0.ranks(before: $1) }.prefix(60).map(\.item)
    }

    // MARK: - Browsing

    private static func browsingSections(scope: PaletteScope, editor: EditorModel) -> [PaletteSection] {
        let sliders = PanelID.allCases.compactMap { panel -> PaletteSection? in
            let items = sliderItems.filter { item in
                if case let .slider(parameter) = item.kind {
                    return panel.parameters.contains(parameter)
                }
                return false
            }
            return items.isEmpty ? nil : PaletteSection(title: panel.title, items: items)
        }
        guard scope == .all else { return sliders }
        let actions = ShortcutCategory.allCases.compactMap { category -> PaletteSection? in
            let items = actionItems.filter { item in
                if case let .action(action) = item.kind {
                    return action.category == category
                }
                return false
            }
            return items.isEmpty ? nil : PaletteSection(title: category.rawValue, items: items)
        }
        let pickers = PaletteSection(title: "Pickers", items: pageItems(editor: editor))
        return [pickers].filter { !$0.items.isEmpty } + sliders.prefix(1) + actions + sliders.dropFirst()
    }

    /// Everything the top-level search reaches.
    private static func searchableItems(editor: EditorModel) -> [PaletteItem] {
        pageItems(editor: editor) + sliderItems + actionItems + deepChoiceItems(editor: editor)
    }

    // MARK: - Sliders

    /// Every live Develop slider, in panel order.
    static let sliderItems: [PaletteItem] = AdjustmentSearch.searchable.map { result in
        PaletteItem(
            kind: .slider(result.parameter),
            title: result.parameter.displayName,
            context: result.context,
            symbol: result.panel.symbol,
            keywords: AdjustmentSearch.searchTerms(result),
        )
    }

    // MARK: - Actions

    /// Actions that only make sense as keys, so the palette leaves them out: the palette's
    /// own keys among them.
    static let keyOnlyActions: Set<ShortcutAction> = [
        .cancel, .previousSetting, .nextSetting, .increaseSetting, .decreaseSetting, .findAdjustment,
        .commandPalette,
    ]

    static let actionItems: [PaletteItem] = ShortcutAction.allCases
        .filter { !keyOnlyActions.contains($0) }
        .map { action in
            PaletteItem(
                kind: .action(action),
                title: action.title,
                context: action.category.rawValue,
                symbol: action.paletteSymbol,
                keywords: ShortcutAction.paletteKeywords[action] ?? [],
            )
        }

    // MARK: - Typed values

    /// "exposure 0.7": a row that sets each slider the name matches best.
    static func typedValues(_ query: String, editor: EditorModel) -> [PaletteItem] {
        let tokens = query.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return [] }
        // The value is the longest run of trailing words that parses; the name is the rest.
        for split in 1 ..< tokens.count {
            let name = tokens[..<split].joined(separator: " ")
            let value = tokens[split...].joined()
            guard value.first.map({ $0.isNumber || "+-.(x".contains($0) }) == true else { continue }
            let words = SearchMatcher.words(name)
            let matches = rank(sliderItems, query: name, words: words)
            guard let best = matches.first else { continue }
            let bestScore = SearchMatcher.score(words, terms: [best.title, best.context] + best.keywords)
            let top = matches.prefix(3).filter {
                SearchMatcher.score(words, terms: [$0.title, $0.context] + $0.keywords) == bestScore
            }
            let rows = top.compactMap { item -> PaletteItem? in
                guard case let .slider(parameter) = item.kind,
                      let parsed = parameter.spec.parse(value, current: editor.sliderValue(parameter))
                else { return nil }
                let set = parameter.spec.quantize(parsed)
                return PaletteItem(
                    kind: .setValue(parameter, set),
                    title: "Set \(parameter.displayName) to \(parameter.spec.formatted(set))",
                    context: item.context,
                    symbol: item.symbol,
                )
            }
            if !rows.isEmpty {
                return rows
            }
        }
        return []
    }

    // MARK: - Pages and choices

    static func pageItems(editor: EditorModel) -> [PaletteItem] {
        PalettePage.allCases.filter { isAvailable($0, editor: editor) }.map { page in
            PaletteItem(
                kind: .page(page), title: page.title, context: "Picker", symbol: page.symbol, keywords: page.keywords,
            )
        }
    }

    static func isAvailable(_ page: PalettePage, editor: EditorModel) -> Bool {
        switch page {
        case .whiteBalance: editor.info?.supportsWhiteBalance == true
        case .snapshots, .history, .treatment, .baseLook, .recipes, .compare: editor.info != nil
        case .filterPresets: editor.libraryFilters != nil && editor.folder != nil
        }
    }

    /// Choices the top-level search reaches without opening their page.
    private static func deepChoiceItems(editor: EditorModel) -> [PaletteItem] {
        [PalettePage.whiteBalance, .treatment, .baseLook, .recipes, .compare, .filterPresets]
            .filter { isAvailable($0, editor: editor) }
            .flatMap { choiceItems($0, editor: editor) }
            .filter(\.kind.isChoice)
    }

    private static func pageSections(_ page: PalettePage, query: String, editor: EditorModel) -> [PaletteSection] {
        let words = SearchMatcher.words(query)
        if !words.isEmpty {
            return [PaletteSection(
                title: nil,
                items: rank(choiceItems(page, editor: editor), query: query, words: words),
            )]
        }
        if page == .recipes {
            return editor.recipes.sections.map { section in
                PaletteSection(title: section.name, items: section.recipes.map(recipeItem))
            }
        }
        if page == .baseLook {
            return BaseLookGroups(editor.recipes.currentBaseLooks).sections.map { section in
                PaletteSection(title: section.name, items: section.looks.map(baseLookItem))
            }
        }
        return [PaletteSection(title: nil, items: choiceItems(page, editor: editor))]
    }

    /// Every row of a page, in the page's order.
    static func choiceItems(_ page: PalettePage, editor: EditorModel) -> [PaletteItem] {
        switch page {
        case .whiteBalance:
            let presets = WhiteBalanceMode.allCases.filter { $0 != .custom }.map { mode in
                PaletteItem(
                    kind: .whiteBalance(mode), title: mode.name, context: "White Balance", symbol: "thermometer.medium",
                    keywords: ["wb", "white balance"],
                )
            }
            let sliders = sliderItems.filter { $0.kind == .slider(.temperature) || $0.kind == .slider(.tint) }
            let selector = actionItems.filter { $0.kind == .action(.whiteBalanceSelector) }
            return presets + sliders + selector
        case .treatment:
            return Treatment.allCases.map { treatment in
                PaletteItem(
                    kind: .treatment(treatment), title: treatment == .color ? "Color" : "Black & White",
                    context: "Treatment", symbol: treatment == .color ? "paintpalette" : "circle.lefthalf.filled",
                    keywords: treatment == .color ? ["colour"] : ["b&w", "bw", "monochrome", "mono", "grayscale"],
                )
            }
        case .baseLook:
            return editor.recipes.currentBaseLooks.map(baseLookItem)
        case .recipes:
            return editor.recipes.all.map(recipeItem)
        case .compare:
            let layouts = CompareLayout.allCases.map { layout in
                PaletteItem(
                    kind: .compareLayout(layout), title: layout.title, context: "Before / After",
                    symbol: layout.symbol, keywords: ["compare", "before", "after"],
                )
            }
            let off = PaletteItem(
                kind: .compareLayout(nil), title: "Hide Before / After", context: "Before / After",
                symbol: "rectangle", keywords: ["compare", "off", "edit"],
            )
            return layouts + [off]
        case .snapshots:
            let new = actionItems.filter { $0.kind == .action(.newSnapshot) }
            let snapshots = editor.snapshots.reversed().map { snapshot in
                PaletteItem(kind: .snapshot(snapshot.id), title: snapshot.name, context: "Snapshot", symbol: "camera")
            }
            return new + snapshots
        case .filterPresets:
            return (editor.libraryFilters?.presets ?? []).map { preset in
                PaletteItem(
                    kind: .filterPreset(preset.id), title: preset.name, context: "Filter Preset",
                    symbol: "line.3.horizontal.decrease.circle", keywords: ["filter", "preset", "library"],
                )
            }
        case .history:
            return editor.history.indices.reversed().map { index in
                PaletteItem(
                    kind: .historyStep(index), title: editor.history[index].name,
                    context: index == editor.historyIndex ? "Current" : "Step \(index + 1)",
                    symbol: index == editor.historyIndex ? "smallcircle.filled.circle" : "circle",
                )
            }
        }
    }

    private static func baseLookItem(_ look: BaseLookPackage) -> PaletteItem {
        PaletteItem(
            kind: .baseLook(look.id), title: look.name, context: "Base Look", symbol: "camera.filters",
            keywords: ["base look", "profile"],
        )
    }

    private static func recipeItem(_ recipe: Recipe) -> PaletteItem {
        PaletteItem(
            kind: .recipe(recipe.id), title: recipe.name, context: "Recipe · \(recipe.group)", symbol: "wand.and.stars",
            keywords: ["recipe", "preset", recipe.group] + recipe.tags,
        )
    }
}
