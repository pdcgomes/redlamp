import AppKit
import Combine
import RedlampEngineAPI
import RedlampRecipes
@_spi(Harness) import RedlampUI
import SwiftUI
import UniformTypeIdentifiers

/// The Recipe Lab: every recipe, Base Look and imported LUT on the look-development set
/// and the lint chart, with comparison, inspection, lint, a creator and the agent runs.
/// Built in RedlampUI so the harness, the app and a companion app can all host it.
public struct RecipeLabView: View {
    @Bindable var model: RecipeLabModel
    @State private var tab: Tab
    @State private var showGallery: Bool

    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case compare = "Compare"
        case inspect = "Inspect"
        case create = "Create"
        case runs = "Runs"

        public var id: String {
            rawValue
        }
    }

    public init(model: RecipeLabModel, tab: Tab = .compare, showsGallery: Bool = true) {
        self.model = model
        _tab = State(initialValue: tab)
        _showGallery = State(initialValue: showsGallery)
    }

    public var body: some View {
        HSplitView {
            if showGallery {
                VStack(spacing: 0) {
                    LabFilterBar(model: model)
                    Divider()
                    LabGallery(model: model)
                }
                .frame(minWidth: 300, idealWidth: 420, maxWidth: 720, maxHeight: .infinity)
            }
            VStack(spacing: 0) {
                HStack {
                    Button {
                        showGallery.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(.borderless)
                    .help(showGallery ? "Hide the gallery (or double-click a comparison)" : "Show the gallery")
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if !showGallery, let selected = model.selected {
                        Text(selected.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                Divider()
                switch tab {
                case .compare: LabCompareView(model: model, showGallery: $showGallery)
                case .inspect: LabInspectorView(model: model)
                case .create: LabCreatorView(model: model)
                case .runs: RecipeRunsView(model: model)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.compareRequest) { tab = .compare }
    }
}

// MARK: - Filters

struct LabFilterBar: View {
    @Bindable var model: RecipeLabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Image", selection: $model.selectedImage) {
                    ForEach(model.images) { image in
                        Text(image.categories.isEmpty ? image
                            .name : "\(image.name) · \(image.categories.prefix(2).joined(separator: ", "))")
                            .tag(Optional(image))
                    }
                }
                .frame(maxWidth: 320)
                Spacer()
                Button("Lint All") { Task { await model.runLint() } }
                Button("Reload") { model.refresh() }
            }
            HStack {
                Picker("Show", selection: $model.kind) {
                    Text("Everything").tag(LabItem.Kind?.none)
                    ForEach(LabItem.Kind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                .frame(maxWidth: 200)
                Picker("Group", selection: $model.group) {
                    Text("All groups").tag(String?.none)
                    ForEach(model.groups, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .frame(maxWidth: 200)
                Picker("Tag", selection: $model.tag) {
                    Text("Any tag").tag(String?.none)
                    ForEach(model.tags, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .frame(maxWidth: 160)
                Picker("Lint", selection: $model.lintFilter) {
                    Text("Any lint").tag(RecipeLint.Status?.none)
                    ForEach([RecipeLint.Status.pass, .warn, .fail, .waived], id: \.self) {
                        Text($0.rawValue).tag(Optional($0))
                    }
                }
                .frame(maxWidth: 140)
            }
            .labelsHidden()
            HStack {
                TextField("Search (preset, profile, LUT work too)", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .controlSize(.small)
        .padding(10)
        .onChange(of: model.kind) { model.scheduleGallery() }
        .onChange(of: model.group) { model.scheduleGallery() }
        .onChange(of: model.tag) { model.scheduleGallery() }
        .onChange(of: model.search) { model.scheduleGallery() }
    }
}

// MARK: - Gallery

struct LabGallery: View {
    @Bindable var model: RecipeLabModel
    private static let columns = [GridItem(.adaptive(minimum: 168), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(model.items) { item in
                    LabTile(model: model, item: item)
                }
            }
            .padding(10)
        }
    }
}

struct LabTile: View {
    let model: RecipeLabModel
    let item: LabItem

    var body: some View {
        let selected = model.selectedID == item.id
        let comparing = model.compareID == item.id
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3))
                if let image = model.thumbnail(item) {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let status = model.lintStatus(item) {
                    LintBadge(status: status).padding(4)
                }
            }
            .frame(height: 112)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                selected ? Color.accentColor : (comparing ? .orange : .clear),
                lineWidth: 2,
            ))
            Text(item.title).font(.caption.weight(.medium)).lineLimit(1)
            Text("\(item.group) · \(item.kind == .recipe ? "v\(item.recipe.version)" : item.kind.rawValue)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = item.id }
        .contextMenu {
            Button("Select as A") { model.selectedID = item.id }
            Button("Compare as B") { model.compareID = item.id }
            Button("Lint") { Task { await model.runLint([item.id]) } }
            Button("Duplicate into Creator") { model.duplicate(item) }
        }
        .help(item.recipe.summary ?? item.package?.summary ?? item.title)
    }
}

struct LintBadge: View {
    let status: RecipeLint.Status

    var body: some View {
        Text(status.rawValue.uppercased())
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(color))
            .foregroundStyle(.white)
    }

    var color: Color {
        switch status {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        case .waived: .gray
        }
    }
}

// MARK: - Compare

struct LabCompareView: View {
    @Bindable var model: RecipeLabModel
    @Binding var showGallery: Bool
    @State private var flickerOn = false
    /// Where the Split divider sits, 0...1 from the left.
    @State private var split = 0.5
    @State private var setTileSize = 320.0
    private let timer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Mode", selection: $model.compareMode) {
                    ForEach(LabCompareMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 260)
                Picker("B", selection: $model.compareID) {
                    Text("B: none").tag(String?.none)
                    ForEach(model.allItems) { Text("B: \($0.title)").tag(Optional($0.id)) }
                }
                .frame(maxWidth: 260)
                if model.compareMode == .acrossSet {
                    Slider(value: $setTileSize, in: 180 ... 720) { Text("Size") }
                        .frame(maxWidth: 180)
                        .help("Tile size")
                }
                Spacer()
                Text("Double-click to \(showGallery ? "hide" : "show") the gallery")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 10)

            Group {
                if model.selected == nil {
                    ContentUnavailableView(
                        "Select a recipe",
                        systemImage: "square.grid.2x2",
                        description: Text("Click a tile to compare it."),
                    )
                } else {
                    switch model.compareMode {
                    case .split:
                        splitView(before: nil, after: model.selectedID, afterTitle: model.selected?.title ?? "")
                    case .beforeAfter:
                        pair(
                            left: nil,
                            leftTitle: "Original",
                            right: model.selectedID,
                            rightTitle: model.selected?.title ?? "",
                        )
                    case .sideBySide:
                        pair(
                            left: model.selectedID,
                            leftTitle: "A: \(model.selected?.title ?? "")",
                            right: model.compareID,
                            rightTitle: "B: \(model.item(model.compareID)?.title ?? "pick one")",
                        )
                    case .flicker:
                        render(
                            flickerOn ? model.compareID : model.selectedID,
                            title: flickerOn ? "B: \(model.item(model.compareID)?.title ?? "original")" :
                                "A: \(model.selected?.title ?? "")",
                        )
                        .onReceive(timer) { _ in flickerOn.toggle() }
                    case .acrossSet:
                        acrossSet
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { showGallery.toggle() }
        }
        .task(
            id: "\(model.selectedID ?? "")|\(model.compareID ?? "")|\(model.compareMode.rawValue)|\(model.selectedImage?.id ?? "")",
        ) {
            await model.prepareCompare()
        }
    }

    /// The photo's width over height, from whichever render has arrived.
    private func aspect(_ ids: [String?]) -> CGFloat {
        for id in ids {
            if let image = model.largeRender(id) {
                return CGFloat(image.width) / CGFloat(max(image.height, 1))
            }
        }
        return 1.5
    }

    /// Two renders side by side, or stacked when that makes each one bigger (landscape
    /// photos in a tall pane).
    private func pair(left: String?, leftTitle: String, right: String?, rightTitle: String) -> some View {
        GeometryReader { proxy in
            let ratio = aspect([right, left])
            let labels: CGFloat = 20, gap: CGFloat = 8
            let size = proxy.size
            let sideBySide = min((size.width - gap) / 2, (size.height - labels) * ratio)
            let stacked = min(size.width, ((size.height - gap) / 2 - labels) * ratio)
            let layout = stacked > sideBySide
                ? AnyLayout(VStackLayout(spacing: gap))
                : AnyLayout(HStackLayout(spacing: gap))
            layout {
                render(left, title: leftTitle)
                render(right, title: rightTitle)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func render(_ id: String?, title: String) -> some View {
        VStack(spacing: 4) {
            if let image = model.largeRender(id) {
                Image(decorative: image, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(title).font(.caption)
        }
    }

    /// One photo at full size, the original left of the divider and the recipe right of it.
    private func splitView(before: String?, after: String?, afterTitle: String) -> some View {
        GeometryReader { proxy in
            let ratio = aspect([after, before])
            let size = proxy.size
            let width = min(size.width, size.height * ratio)
            let height = width / ratio
            let frame = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
            ZStack(alignment: .topLeading) {
                if let original = model.largeRender(before), let looked = model.largeRender(after) {
                    Image(decorative: original, scale: 2).resizable().interpolation(.high)
                        .frame(width: width, height: height)
                    Image(decorative: looked, scale: 2).resizable().interpolation(.high)
                        .frame(width: width, height: height)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: width * (1 - split))
                        }
                    Rectangle().fill(.white.opacity(0.9)).frame(width: 1.5, height: height)
                        .offset(x: width * split)
                    Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 2)
                        .offset(x: width * split - 9, y: height / 2 - 9)
                    HStack {
                        caption("Original")
                        Spacer()
                        caption(afterTitle)
                    }
                    .padding(8)
                    .frame(width: width)
                } else {
                    ProgressView().frame(width: width, height: height)
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            // A small minimum distance leaves double-clicks to toggle the gallery.
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                split = min(max(value.location.x / width, 0), 1)
            })
            .position(x: frame.midX, y: frame.midY)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
            .foregroundStyle(.white)
    }

    private var acrossSet: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: setTileSize), spacing: 8)], spacing: 8) {
                ForEach(model.images.filter { !$0.categories.contains("chart") }.prefix(12)) { image in
                    VStack(spacing: 2) {
                        if let id = model.selectedID, let rendered = model.acrossSetRender(id, image: image) {
                            Image(decorative: rendered, scale: 2).resizable().interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView().frame(height: setTileSize * 0.6)
                        }
                        Text(image.categories.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - Inspector

struct LabInspectorView: View {
    @Bindable var model: RecipeLabModel

    var body: some View {
        ScrollView {
            if let item = model.selected {
                VStack(alignment: .leading, spacing: 14) {
                    header(item)
                    settings(item.recipe)
                    if let card = item.recipe.cameraCard {
                        section("Camera card (mapping v\(CameraRecipeCard.mappingVersion))") {
                            CameraCardSummary(card: card)
                        }
                    }
                    lookSection(item)
                    lintSection(item)
                    section("File") {
                        Text(Self.json(model.catalog.library.exportable(item.recipe)))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "info.circle")
            }
        }
    }

    private func header(_ item: LabItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.title3.weight(.semibold))
            Text("\(item.recipe.id)@\(item.recipe.version)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if let summary = item.recipe.summary ?? item.package?.summary {
                Text(summary).font(.callout)
            }
            let meta = [
                item.recipe.author?.name,
                item.recipe.license,
                item.recipe.tags.isEmpty ? nil : item.recipe.tags.joined(separator: ", "),
            ]
            .compactMap(\.self).joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func settings(_ recipe: Recipe) -> some View {
        section("Included settings") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(recipe.includes.sorted(), id: \.self) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.caption.weight(.semibold))
                        let values = group.parameters.filter { recipe.settings.values[$0] != nil }
                        if values.isEmpty, !Self.hasFields(group, recipe) {
                            Text("Reset to defaults").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(values, id: \.self) { parameter in
                            HStack {
                                Text(parameter.spec.label).font(.caption2)
                                Text(parameter.rawValue).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                Spacer()
                                Text(parameter.spec.formatted(recipe.settings[parameter]))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                        if group == .treatment, let treatment = recipe.settings.treatment {
                            Text(treatment.name).font(.caption2)
                        }
                        if group == .whiteBalance, let mode = recipe.settings.whiteBalanceMode {
                            Text("Mode: \(mode.name)").font(.caption2)
                        }
                        if group == .toneCurve, let curve = recipe.settings.pointCurve {
                            Text("Point curve: " + curve.map { String(format: "(%.2f, %.2f)", $0.x, $0.y) }
                                .joined(separator: " ")).font(.caption2)
                        }
                        if group == .baseLook, let look = recipe.baseLook {
                            Text("\(look.name) at \(Int(look.amount))%").font(.caption2)
                        }
                    }
                }
            }
        }
    }

    private static func hasFields(_ group: RecipeSettingGroup, _ recipe: Recipe) -> Bool {
        switch group {
        case .treatment: recipe.settings.treatment != nil
        case .whiteBalance: recipe.settings.whiteBalanceMode != nil
        case .toneCurve: recipe.settings.pointCurve != nil
        case .baseLook: recipe.baseLook != nil
        default: false
        }
    }

    @ViewBuilder
    private func lookSection(_ item: LabItem) -> some View {
        let reference = item.recipe.baseLook
        let package = item.package ?? reference.flatMap { model.catalog.package(for: $0) }
        if let package {
            section("Base Look") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(package.name) (\(package.id)@\(package.version))").font(.caption)
                    let p = package.parameters
                    Text(String(
                        format: "contrast ×%.2f  saturation ×%.2f  warmth %+.3f",
                        p.contrast,
                        p.saturation,
                        p.warmth,
                    ) + (p.isMonochrome ? "  monochrome" : ""))
                        .font(.caption2.monospaced())
                    if let table = try? package.definition().table {
                        let stats = LookTableStats(table)
                        Text("Table \(table.size)³ · \(table.space.rawValue) · \(table.contentHash.prefix(16))…")
                            .font(.caption2.monospaced())
                        Text(String(
                            format: "strength %.3f · greys gain %.4f chroma · steepest slope %.2f · %.1f%% out of range",
                            stats.strength,
                            stats.neutralChroma,
                            stats.maxSlope,
                            stats.outOfRange * 100,
                        ))
                        .font(.caption2.monospaced())
                    } else {
                        Text("Parametric (no table)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func lintSection(_ item: LabItem) -> some View {
        section("Lint") {
            VStack(alignment: .leading, spacing: 4) {
                if let results = model.lint[item.id] {
                    ForEach(results, id: \.check) { result in
                        HStack(alignment: .top) {
                            LintBadge(status: result.status)
                            VStack(alignment: .leading) {
                                Text(result.check.title).font(.caption)
                                Text(result.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button(model.lint[item.id] == nil ? "Run Lint" : "Run Again") { Task { await model.runLint([item.id]) }
                }
                .controlSize(.small)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    static func json(_ recipe: Recipe) -> String {
        var trimmed = recipe
        // Table data is thousands of characters of base64; show its size instead.
        for index in trimmed.embeddedBaseLooks.indices {
            if let count = trimmed.embeddedBaseLooks[index].table?.data.count {
                trimmed.embeddedBaseLooks[index].table?.data = "<\(count) base64 characters>"
            }
        }
        return (try? String(decoding: RecipeFile.encode(trimmed), as: UTF8.self)) ?? ""
    }
}

struct CameraCardSummary: View {
    let card: CameraRecipeCard

    var body: some View {
        let rows: [(String, String)] = [
            ("Film", card.slot?.name ?? card.filmSimulation),
            ("Dynamic range", card.dynamicRange.rawValue.uppercased()),
            ("Highlight / Shadow", String(format: "%+.1f / %+.1f", card.highlight, card.shadow)),
            ("Color", String(format: "%+d", card.color)),
            ("Color Chrome / FX Blue", "\(card.colorChrome.rawValue) / \(card.chromeFxBlue.rawValue)"),
            (
                "White balance",
                "\(card.whiteBalance.mode)\(card.whiteBalance.kelvin.map { " \(Int($0)) K" } ?? ""), R\(card.whiteBalance.shiftRed) B\(card.whiteBalance.shiftBlue)",
            ),
            ("Grain", "\(card.grain.strength.rawValue), \(card.grain.size.rawValue)"),
            ("Clarity / Sharpness / NR", "\(card.clarity) / \(card.sharpness) / \(card.noiseReduction)"),
        ]
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).font(.caption2).foregroundStyle(.secondary)
                    Text(row.1).font(.caption2)
                }
            }
        }
    }
}
