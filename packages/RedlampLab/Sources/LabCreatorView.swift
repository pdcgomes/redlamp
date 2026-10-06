import AppKit
import RedlampRecipes
@_spi(Harness) import RedlampUI
import SwiftUI
import UniformTypeIdentifiers

/// The basics of making a recipe: start new, from a camera card or by duplicating; edit
/// with the real Develop panels or the card; pick a Base Look or import a LUT; preview and
/// lint; save to My Recipes or export a `.redrecipe`.
struct LabCreatorView: View {
    @Bindable var model: RecipeLabModel
    @State private var preview: CGImage?
    @State private var lint: [RecipeLint.Result] = []
    @State private var showDevelop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("New Recipe") { model.newDraft() }
                    Button("New Camera Card") { model.newCardDraft() }
                    Button("Duplicate Selected") { model.selected.map(model.duplicate) }
                        .disabled(model.selected == nil)
                    Button("Import .cube, .3dl or HaldCLUT…") { importTable() }
                }
                .controlSize(.small)

                if let draft = model.draft {
                    details(draft)
                    if let card = model.draftCard {
                        section("Camera card") {
                            CameraCardEditor(card: card) { model.updateCard($0) }
                        }
                    }
                    section("Develop") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(
                                "Apply the draft to the editor's photo, adjust it with the real panels, then capture the chosen groups back.",
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Edit in Develop") {
                                    model.editDraftInDevelop()
                                    showDevelop = true
                                }
                                Button("Capture from Develop") { model.captureFromDevelop() }
                                Toggle("Show panels", isOn: $showDevelop).toggleStyle(.checkbox)
                            }
                            .controlSize(.small)
                            if showDevelop {
                                DevelopPanelsHost(model: model.editor).frame(height: 620)
                            }
                        }
                    }
                    section("Preview on \(model.selectedImage?.name ?? "")") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let preview {
                                Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 360)
                            } else {
                                ProgressView()
                            }
                            ForEach(lint, id: \.check) { result in
                                HStack {
                                    LintBadge(status: result.status)
                                    Text("\(result.check.title): \(result.detail)").font(.caption2)
                                }
                            }
                        }
                    }
                    HStack {
                        Button("Save to My Recipes") { model.saveDraft() }.keyboardShortcut("s", modifiers: .command)
                        Button("Export…") { export(draft) }
                        Button("Discard", role: .destructive) { model.draft = nil }
                        Spacer()
                        if let message = model.creatorMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                } else {
                    ContentUnavailableView(
                        "No draft", systemImage: "wand.and.stars",
                        description: Text("Start a recipe, duplicate one from the gallery, or import a look table."),
                    )
                }
            }
            .padding(14)
        }
        .task(id: "\(model.draft.map { "\($0.hashValue)" } ?? "")|\(model.selectedImage?.id ?? "")") {
            preview = nil
            preview = await model.renderDraft()
            lint = await model.lintDraft()
        }
    }

    private func details(_ draft: Recipe) -> some View {
        section("Recipe") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: Binding(get: { draft.name }, set: { model.draft?.name = $0 }))
                TextField("List", text: Binding(get: { draft.group }, set: { model.draft?.group = $0 }))
                TextField(
                    "Summary",
                    text: Binding(get: { draft.summary ?? "" }, set: { model.draft?.summary = $0.isEmpty ? nil : $0 }),
                )
                Picker("Base Look", selection: Binding(
                    get: { draft.baseLook.flatMap { model.catalog.package(for: $0)?.id } ?? "" },
                    set: { id in model.setDraftBaseLook(model.catalog.currentBaseLooks.first { $0.id == id }) },
                )) {
                    Text("None (keep the photo's)").tag("")
                    ForEach(model.catalog.currentBaseLooks, id: \.id) { Text($0.name).tag($0.id) }
                }
                Text("Settings to include").font(.caption.weight(.semibold))
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                    alignment: .leading,
                    spacing: 4,
                ) {
                    ForEach(RecipeSettingGroup.allCases, id: \.self) { group in
                        Toggle(group.name, isOn: Binding(
                            get: { model.draftIncludes.contains(group) },
                            set: { on in
                                if on {
                                    model.draftIncludes.insert(group)
                                } else {
                                    model.draftIncludes.remove(group)
                                }
                                model.draft?.includes = model.draftIncludes
                            },
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func importTable() {
        guard let chosen = RecipeActions.chooseImports(
            RecipeActions.lookTableTypes,
            message: "Choose a .cube or .3dl look table, or a graded HaldCLUT image",
        ), let url = chosen.urls.first else { return }
        if model.draft == nil {
            model.newDraft()
        }
        model.importTable(url, space: chosen.tableSpace)
    }

    private func export(_ draft: Recipe) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [RecipeActions.recipeType]
        panel.nameFieldStringValue = RecipeFile.fileName(for: draft)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportDraft(to: url)
    }
}

/// Every field of a camera recipe card, in the camera's own steps.
struct CameraCardEditor: View {
    let card: CameraRecipeCard
    let update: (CameraRecipeCard) -> Void

    private func binding<T>(_ keyPath: WritableKeyPath<CameraRecipeCard, T>) -> Binding<T> {
        Binding(get: { card[keyPath: keyPath] }, set: { value in
            var next = card
            next[keyPath: keyPath] = value
            update(next.clamped)
        })
    }

    var body: some View {
        Form {
            Picker("Film", selection: binding(\.filmSimulation)) {
                ForEach(FilmSlot.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
            }
            Picker("Dynamic range", selection: binding(\.dynamicRange)) {
                ForEach(CameraRecipeCard.DynamicRange.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            Stepper(
                "Highlight \(String(format: "%+.1f", card.highlight))",
                value: binding(\.highlight),
                in: -2 ... 4,
                step: 0.5,
            )
            Stepper("Shadow \(String(format: "%+.1f", card.shadow))", value: binding(\.shadow), in: -2 ... 4, step: 0.5)
            Stepper("Color \(card.color)", value: binding(\.color), in: -4 ... 4)
            Picker("Color Chrome", selection: binding(\.colorChrome)) {
                ForEach(CameraRecipeCard.Strength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Chrome FX Blue", selection: binding(\.chromeFxBlue)) {
                ForEach(CameraRecipeCard.Strength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("White balance", selection: binding(\.whiteBalance.mode)) {
                ForEach(
                    ["auto", "asShot", "daylight", "cloudy", "shade", "tungsten", "fluorescent", "flash", "kelvin"],
                    id: \.self,
                ) { Text($0).tag($0) }
            }
            if card.whiteBalance.mode == "kelvin" {
                Stepper("Kelvin \(Int(card.whiteBalance.kelvin ?? 5500))", value: Binding(
                    get: { card.whiteBalance.kelvin ?? 5500 },
                    set: { value in
                        var next = card
                        next.whiteBalance.kelvin = value
                        update(next.clamped)
                    },
                ), in: 2500 ... 10000, step: 100)
            }
            Stepper("WB shift red \(card.whiteBalance.shiftRed)", value: binding(\.whiteBalance.shiftRed), in: -9 ... 9)
            Stepper(
                "WB shift blue \(card.whiteBalance.shiftBlue)",
                value: binding(\.whiteBalance.shiftBlue),
                in: -9 ... 9,
            )
            Picker("Grain", selection: binding(\.grain.strength)) {
                ForEach(CameraRecipeCard.Strength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Grain size", selection: binding(\.grain.size)) {
                ForEach(CameraRecipeCard.GrainSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Stepper("Clarity \(card.clarity)", value: binding(\.clarity), in: -5 ... 5)
            Stepper("Sharpness \(card.sharpness)", value: binding(\.sharpness), in: -4 ... 4)
            Stepper("Noise reduction \(card.noiseReduction)", value: binding(\.noiseReduction), in: -4 ... 4)
            Stepper(
                "Exposure \(String(format: "%+.1f", card.exposure)) EV",
                value: binding(\.exposure),
                in: -3 ... 3,
                step: 0.3,
            )
            if card.slot?.isMonochrome == true {
                Stepper(
                    "Toning warm/cool \(card.monochromeWarmCool)",
                    value: binding(\.monochromeWarmCool),
                    in: -9 ... 9,
                )
                Stepper(
                    "Toning magenta/green \(card.monochromeMagentaGreen)",
                    value: binding(\.monochromeMagentaGreen),
                    in: -9 ... 9,
                )
            }
        }
        .controlSize(.small)
    }
}

/// The editor's real Develop column, hosted in the creator.
struct DevelopPanelsHost: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context _: Context) -> NSView {
        // The column scrolls its own panels.
        InspectorColumnViews.make(model: model)
    }

    func updateNSView(_: NSView, context _: Context) {}
}
