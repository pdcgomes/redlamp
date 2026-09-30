import CoreGraphics
import Foundation
import Observation
import RedlampEngineAPI
import RedlampRecipes

/// One thing the Lab can show: a recipe, or a Base Look on its own.
public struct LabItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case recipe = "Recipes"
        case baseLook = "Base Looks"
        case imported = "Imported LUTs"
    }

    public var id: String
    public var title: String
    public var group: String
    public var kind: Kind
    /// What gets rendered: the recipe itself, or a one-look recipe for a Base Look.
    public var recipe: Recipe
    public var package: BaseLookPackage?

    var tags: [String] {
        recipe.tags
    }
}

/// An image the Lab renders on.
public struct LabImage: Identifiable, Hashable, Sendable {
    public var id: String {
        url.path
    }

    public var url: URL
    public var name: String
    public var categories: [String]
}

public enum LabCompareMode: String, CaseIterable, Identifiable, Sendable {
    /// One photo, original and recipe either side of a draggable divider.
    case split = "Split"
    case beforeAfter = "Before / After"
    case sideBySide = "A | B"
    case flicker = "Flicker A/B"
    case acrossSet = "Across the set"

    public var id: String {
        rawValue
    }
}

/// The Recipe Lab's state: what to show, on which image, and every render and lint result.
///
/// It renders through its own engine, so it never disturbs the editor's photo. The creator
/// works on a draft recipe; "Edit in Develop" applies the draft to the editor so its real
/// panels can change it, and "Capture" brings the editor's settings back.
@MainActor
@Observable
public final class RecipeLabModel {
    @ObservationIgnored public let catalog: RecipeCatalog
    @ObservationIgnored public let editor: EditorModel
    @ObservationIgnored let renderer: RecipeRenderer
    @ObservationIgnored public let root: URL?

    public private(set) var images: [LabImage]
    public var selectedImage: LabImage? {
        didSet {
            if oldValue != selectedImage {
                scheduleGallery()
            }
        }
    }

    // Filters
    public var kind: LabItem.Kind?
    public var group: String?
    public var tag: String?
    public var lintFilter: RecipeLint.Status?
    public var search = ""

    // Selection and comparison
    public var selectedID: String?
    public var compareID: String?
    public var compareMode: LabCompareMode = .split

    public private(set) var thumbnails: [String: CGImage] = [:]
    public private(set) var large: [String: CGImage] = [:]
    public private(set) var lint: [String: [RecipeLint.Result]] = [:]
    public private(set) var status = ""
    public private(set) var isRendering = false

    // Creator
    public var draft: Recipe?
    public var draftCard: CameraRecipeCard?
    public var draftIncludes: Set<RecipeSettingGroup> = RecipeSettingGroup.captureDefaults
    public private(set) var creatorMessage: String?

    @ObservationIgnored private var galleryTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [(key: String, work: () async -> Void)] = []

    public static let thumbnailSize = 360
    /// Compare renders fill a full window on a Retina display.
    public static let largeSize = 2400
    /// "Across the set" tiles go up to 720 points wide.
    public static let setSize = 900

    public init(engine: any EditingEngine, editor: EditorModel, root: URL?, images: [LabImage]? = nil) {
        self.editor = editor
        catalog = editor.recipes
        self.root = root
        renderer = RecipeRenderer(engine: engine, library: editor.recipes.library)
        var all = images ?? Self.defaultImages(root: root)
        if let chart = try? RecipeChart.fileURL() {
            all.append(LabImage(url: chart, name: "Lint chart", categories: ["chart"]))
        }
        self.images = all
        selectedImage = all.first
        scheduleGallery()
    }

    /// The look-development set when downloaded, otherwise the decode fixtures.
    public static func defaultImages(root: URL?) -> [LabImage] {
        guard let root else { return [] }
        if let set = LookDevSet.load(root: root) {
            let available = set.available(root: root)
            if !available.isEmpty {
                return available.map { LabImage(url: $0.url, name: $0.image.camera, categories: $0.image.categories) }
            }
        }
        let fixtures = root.appendingPathComponent("tests/fixtures/raw")
        let files = (try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? []
        return files.filter(SupportedFormats.isSupported).sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { LabImage(url: $0, name: $0.deletingPathExtension().lastPathComponent, categories: []) }
    }

    // MARK: - Items

    public var allItems: [LabItem] {
        let recipes = catalog.all.map { recipe in
            LabItem(
                id: "recipe:\(recipe.id)@\(recipe.version)", title: recipe.name, group: recipe.group,
                kind: recipe.group == "Imported" ? .imported : .recipe, recipe: recipe,
            )
        }
        let looks = catalog.baseLooks.map { package in
            LabItem(
                id: "look:\(package.id)@\(package.version)#\(package.table?.sha256.prefix(12) ?? "")",
                // Every version is listed, so a slot's measured look can be compared with the one it replaced.
                title: package.version > 1 ? "\(package.name) v\(package.version)" : package.name,
                group: package.slot
                    .map { _ in "Film Styles" } ??
                    (BuiltInBaseLook(rawValue: package.id) != nil ? "Redlamp" : "Installed"),
                kind: .baseLook, recipe: BaseLookBrowser.previewRecipe(for: package), package: package,
            )
        }
        return recipes + looks
    }

    public var items: [LabItem] {
        let query = search.lowercased().trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty ? nil : Set(catalog.search(query).map(\.id))
        return allItems.filter { item in
            (kind == nil || item.kind == kind)
                && (group == nil || item.group == group)
                && (tag == nil || item.tags.contains(tag!))
                && (lintFilter == nil || lint[item.id].map(RecipeLint.overall) == lintFilter)
                && (matches == nil || matches!.contains(item.recipe.id) || item.title.lowercased().contains(query))
        }
    }

    public var groups: [String] {
        var seen: [String] = []
        for item in allItems where !seen.contains(item.group) {
            seen.append(item.group)
        }
        return seen
    }

    public var tags: [String] {
        Array(Set(allItems.flatMap(\.tags))).sorted()
    }

    public func item(_ id: String?) -> LabItem? {
        guard let id else { return nil }
        return allItems.first { $0.id == id }
    }

    public var selected: LabItem? {
        item(selectedID)
    }

    // MARK: - Rendering

    private func key(_ id: String, _ image: LabImage, _ size: Int) -> String {
        "\(id)|\(image.id)|\(size)"
    }

    public func thumbnail(_ item: LabItem) -> CGImage? {
        guard let image = selectedImage else { return nil }
        return thumbnails[key(item.id, image, Self.thumbnailSize)]
    }

    public func largeRender(_ id: String?, image: LabImage? = nil) -> CGImage? {
        guard let image = image ?? selectedImage else { return nil }
        return large[key(id ?? "original", image, Self.largeSize)]
    }

    /// Renders every visible item's thumbnail on the selected image, one at a time.
    public func scheduleGallery() {
        galleryTask?.cancel()
        guard let image = selectedImage else { return }
        let pending = items.filter { thumbnails[key($0.id, image, Self.thumbnailSize)] == nil }
        galleryTask = Task { [weak self] in
            guard let self else { return }
            isRendering = true
            defer { isRendering = false }
            for (index, item) in pending.enumerated() {
                if Task.isCancelled {
                    return
                }
                status = "Rendering \(index + 1) of \(pending.count) on \(image.name)…"
                await renderThumbnail(item, on: image)
            }
            status = "\(items.count) items on \(image.name)"
        }
    }

    private func renderThumbnail(_ item: LabItem, on image: LabImage) async {
        let key = key(item.id, image, Self.thumbnailSize)
        guard thumbnails[key] == nil else { return }
        if let rendered = try? await renderer.render(item.recipe, image: image.url, maxLongEdge: Self.thumbnailSize) {
            thumbnails[key] = rendered
        }
    }

    /// Makes sure the large renders the compare view needs exist.
    public func prepareCompare() async {
        guard let image = selectedImage else { return }
        var wanted: [(String?, LabImage)] = [(nil, image)]
        if let selected = selectedID {
            wanted.append((selected, image))
        }
        if let compare = compareID {
            wanted.append((compare, image))
        }
        let size = compareMode == .acrossSet ? Self.setSize : Self.largeSize
        if compareMode == .acrossSet, let selected = selectedID {
            wanted = images.filter { !$0.categories.contains("chart") }.prefix(12).map { (selected, $0) }
        }
        let keys = wanted.map { key($0.0 ?? "original", $0.1, size) }
        // Big renders are about 15 MB each: keep only what this comparison shows.
        large = large.filter { keys.contains($0.key) }
        for ((id, target), cacheKey) in zip(wanted, keys) where large[cacheKey] == nil {
            let recipe = id.flatMap(item)?.recipe
            status = "Rendering \(recipe?.name ?? "original") on \(target.name)…"
            guard let rendered = try? await renderer.render(recipe, image: target.url, maxLongEdge: size)
            else { continue }
            large[cacheKey] = rendered
        }
        status = ""
    }

    public func acrossSetRender(_ id: String, image: LabImage) -> CGImage? {
        large[key(id, image, Self.setSize)]
    }

    // MARK: - Lint

    public func runLint(_ ids: [String]? = nil) async {
        let targets = (ids ?? items.map(\.id)).compactMap(item)
        for (index, target) in targets.enumerated() {
            status = "Linting \(index + 1) of \(targets.count)…"
            if let results = try? await renderer.lint(target.recipe) {
                lint[target.id] = results
            }
        }
        status = ""
    }

    public func lintStatus(_ item: LabItem) -> RecipeLint.Status? {
        lint[item.id].map(RecipeLint.overall)
    }

    // MARK: - Library changes

    public func refresh() {
        catalog.reload()
        thumbnails = thumbnails.filter { key, _ in allItems.contains { key.hasPrefix($0.id + "|") } }
        scheduleGallery()
    }

    // MARK: - Creator

    public func newDraft() {
        draft = Recipe(
            id: RecipeNamespace.newLocalID(), name: "New Recipe", group: "My Recipes",
            includes: RecipeSettingGroup.captureDefaults, settings: RecipeSettings(), created: Date(),
        )
        draftCard = nil
        draftIncludes = RecipeSettingGroup.captureDefaults
        creatorMessage = nil
    }

    public func duplicate(_ item: LabItem) {
        var copy = catalog.library.exportable(item.recipe)
        copy.id = RecipeNamespace.newLocalID()
        copy.version = 1
        copy.name = "\(item.title) Copy"
        copy.group = "My Recipes"
        draft = copy
        draftCard = copy.cameraCard
        draftIncludes = copy.includes
        creatorMessage = nil
    }

    public func newCardDraft() {
        let card = CameraRecipeCard()
        draftCard = card
        draft = card.recipe(id: RecipeNamespace.newLocalID(), name: "New Camera Recipe", group: "My Recipes")
        draftIncludes = CameraRecipeCard.includes
        creatorMessage = nil
    }

    /// Re-resolves the draft from its edited card.
    public func updateCard(_ card: CameraRecipeCard) {
        draftCard = card
        guard let draft else { return }
        self.draft = draft.updatingCard(card)
        draftIncludes = CameraRecipeCard.includes
    }

    /// Applies the draft to the editor's photo, so the real Develop panels can edit it.
    public func editDraftInDevelop() {
        guard let draft else { return }
        editor.applyRecipe(draft)
    }

    /// Takes the editor's current settings into the draft, for the chosen groups.
    public func captureFromDevelop() {
        guard var draft else { return }
        let looks = catalog.package(for: editor.recipe.baseLook).map { [$0] } ?? []
        let captured = Recipe.capture(
            editor.recipe,
            id: draft.id,
            name: draft.name,
            group: draft.group,
            includes: draftIncludes,
            embedding: looks,
        )
        draft.settings = captured.settings
        draft.includes = draftIncludes
        draft.baseLook = captured.baseLook
        draft.embeddedBaseLooks = captured.embeddedBaseLooks
        draft.source = nil
        draftCard = nil
        self.draft = draft
        creatorMessage = "Captured \(draftIncludes.count) setting groups from Develop"
    }

    public func setDraftBaseLook(_ package: BaseLookPackage?) {
        guard var draft else { return }
        draft.baseLook = package?.reference
        draft.embeddedBaseLooks = package.flatMap { $0.table == nil || $0.id.hasPrefix("redlamp/") ? nil : [$0] } ?? []
        if package != nil {
            draft.includes.insert(.baseLook)
            draftIncludes.insert(.baseLook)
        }
        self.draft = draft
    }

    public func importTable(_ url: URL, space: ImportedTableSpace = .sRGB) {
        do {
            let table: LookTable = if url.pathExtension.lowercased() == "cube" {
                try LookTableImport.parseCube(String(contentsOf: url, encoding: .utf8), space: space).table
            } else {
                try LookTableImport.parseHald(LookTableImport.readImage(url), space: space)
            }
            let id = draft?.id ?? RecipeNamespace.newLocalID()
            var recipe = LookTableImport.recipe(for: table, name: url.deletingPathExtension().lastPathComponent, id: id)
            if let draft {
                recipe.name = draft.name
                recipe.group = draft.group
                recipe.settings = draft.settings
                recipe.includes = draft.includes.union([.baseLook])
            }
            draft = recipe
            draftIncludes = recipe.includes
            creatorMessage = "Imported a \(table.size)-point table"
        } catch {
            creatorMessage = "Couldn't import: \(error)"
        }
    }

    @discardableResult
    public func saveDraft() -> Recipe? {
        guard var draft else { return nil }
        draft.includes = draftIncludes
        guard let saved = catalog.save(draft) else {
            creatorMessage = catalog.lastError
            return nil
        }
        self.draft = saved
        creatorMessage = "Saved “\(saved.name)” to My Recipes (version \(saved.version))"
        refresh()
        return saved
    }

    public func exportDraft(to url: URL) {
        guard let draft else { return }
        catalog.export(draft, to: url)
        creatorMessage = catalog.lastError ?? "Exported \(url.lastPathComponent)"
    }

    /// Renders the draft on the selected image, bypassing the cache (it changes as you edit).
    public func renderDraft() async -> CGImage? {
        guard let draft, let image = selectedImage else { return nil }
        return try? await renderer.render(draft, image: image.url, maxLongEdge: 900)
    }

    public func lintDraft() async -> [RecipeLint.Result] {
        guard let draft else { return [] }
        return await (try? renderer.lint(draft)) ?? []
    }
}
