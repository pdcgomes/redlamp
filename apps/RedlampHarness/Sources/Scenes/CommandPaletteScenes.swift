import AppKit
import Observation
import RedlampCanvas
import RedlampDesign
import RedlampEngineAPI
@_spi(Harness) import RedlampUI
import SwiftUI

extension HarnessScene {
    static var commandPalette: HarnessScene {
        var scene = HarnessScene(
            id: "command-palette",
            title: "Live",
            symbol: "command",
            synopsis: "The palette over the sample photo on the real editor: ⌘K or ⌘F to open, "
                + "and the checklist ticks each interaction as you try it",
            section: .palette,
        ) {
            PaletteLiveScene()
        } inspector: {
            PaletteInspector()
        }
        scene.fillsStage = true
        return scene
    }

    static var commandPaletteStates: HarnessScene {
        HarnessScene(
            id: "command-palette-states",
            title: "States",
            symbol: "square.grid.2x2",
            synopsis: "Every state of the palette as a still specimen, for review in every theme",
            section: .palette,
        ) {
            PaletteStatesScene()
        }
    }
}

// MARK: - The session

/// What the Live scene has seen: a log of the palette's events and the editor's history,
/// and which interactions have been tried.
@MainActor @Observable
final class PaletteSession {
    static let shared = PaletteSession()

    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
        let isHistory: Bool
    }

    private(set) var log: [LogEntry] = []
    private(set) var ticked: Set<PaletteCheck> = []
    var photo = HarnessEditor.Photo.raw
    var panelTransparency = 0.6
    /// The palette's own theme, as Settings ▸ Appearance ▸ Command Palette sets it; `nil`
    /// follows the harness's theme.
    var paletteTheme: ThemeSelection?
    var showsPanels = false
    var previewDelay = 150.0 {
        didSet { CommandPaletteModel.previewDelay = .milliseconds(Int(previewDelay)) }
    }

    var burstGap = 500.0 {
        didSet { CommandPaletteModel.burstGap = .milliseconds(Int(burstGap)) }
    }

    private(set) var isPlaying = false
    /// ⌘K and ⌘F (harness menu items) open the palette only where it's drawn.
    var isLiveSceneShown = false
    @ObservationIgnored private var trackers: [Tracker] = []
    @ObservationIgnored private var lastHistoryID: UUID?
    @ObservationIgnored private var opens = 0
    /// The last palette event was an arrow press, so a history step or ⌘Z ends a burst.
    @ObservationIgnored private var lastWasNudge = false

    private init() {
        let model = HarnessEditor.model
        model.onCommandPaletteEvent = { [weak self] event in self?.record(event) }
        lastHistoryID = model.history.last?.id
        trackers = [
            Tracker { [weak self] in
                guard let self, let step = model.history.last, step.id != lastHistoryID else { return }
                lastHistoryID = step.id
                append("History: \(step.name)", isHistory: true)
            },
            Tracker { [weak self] in
                guard let self, let palette = model.commandPalette, palette.sliderParameter != nil,
                      !palette.heldModifiers.isEmpty
                else { return }
                ticked.insert(.modifierLit)
            },
        ]
    }

    var model: EditorModel {
        HarnessEditor.model
    }

    func toggle(_ scope: PaletteScope) {
        guard isLiveSceneShown else {
            append("⌘K and ⌘F open the palette in the Live scene", isHistory: false)
            return
        }
        if let palette = model.commandPalette, palette.scope != scope, scope == .sliders {
            model.openCommandPalette(scope: scope)
        } else {
            model.toggleCommandPalette(scope: scope)
        }
    }

    func undo() {
        if lastWasNudge, model.commandPalette?.hasOpenStep == true {
            ticked.insert(.undoBurst)
        }
        model.undo()
        append("⌘Z", isHistory: true)
    }

    func redo() {
        model.redo()
        append("⇧⌘Z", isHistory: true)
    }

    func clearLog() {
        log.removeAll()
    }

    func resetChecklist() {
        ticked.removeAll()
        opens = 0
    }

    /// Actions only the app can run.
    func appAction(_ action: ShortcutAction) {
        append("App would run: \(action.title)", isHistory: false)
    }

    /// `--palette-log <file>`: the log also goes to a file, for scripted runs.
    @ObservationIgnored private let logFile: FileHandle? = HarnessLaunch.value(after: "--palette-log").flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    private func append(_ text: String, isHistory: Bool) {
        log.append(LogEntry(text: text, isHistory: isHistory))
        if log.count > 400 {
            log.removeFirst(log.count - 400)
        }
        logFile?.write(Data((text + "\n").utf8))
    }

    // MARK: Events

    private func record(_ event: PaletteEvent) {
        append(describe(event), isHistory: false)
        if case .opened = event {
            opens += 1
            if opens >= 2 {
                ticked.insert(.newTip)
            }
        }
        if case .historyStep = event, lastWasNudge {
            ticked.insert(.burstStep)
        }
        for check in PaletteCheck.allCases where check.matches(event, palette: model.commandPalette) {
            ticked.insert(check)
        }
        if case .nudged = event {
            lastWasNudge = true
        } else if case .historyStep = event {
            // A step ends a burst, but ⌘Z right after it still undoes the burst.
        } else {
            lastWasNudge = false
        }
    }

    private func describe(_ event: PaletteEvent) -> String {
        switch event {
        case let .opened(scope): scope == .all ? "Opened (⌘K)" : "Opened for sliders (⌘F)"
        case let .closed(reason): "Closed (\(reason.rawValue))"
        case .scopeRemoved: "⌫: searching everything"
        case let .highlighted(kind): "Highlighted \(name(kind))"
        case let .ran(action): "Ran \(action.title)"
        case let .unavailable(kind): "Not available now: \(name(kind))"
        case let .pushed(page): "Opened \(page.title)"
        case let .openedSlider(parameter): "Slider bar: \(parameter.displayName)"
        case let .wentBack(key): "Back (\(key.rawValue))"
        case let .nudged(parameter, value, modifiers):
            "\(parameter.displayName) → \(parameter.spec.formatted(value))"
                + (modifiers.contains(.shift) ? " (⇧ ×10)" : modifiers.contains(.option) ? " (⌥ fine)" : "")
        case let .steppedSlider(parameter): "Moved to \(parameter.displayName)"
        case let .setValue(parameter, value): "Set \(parameter.displayName) to \(parameter.spec.formatted(value))"
        case let .invalidValue(text): "Couldn't read “\(text)”"
        case let .reset(parameter): "Reset \(parameter.displayName)"
        case let .searchedFromSlider(text): "Typed “\(text)”: back to the search"
        case let .applied(kind): "Applied \(name(kind))"
        case let .previewed(kind?): "Previewing \(name(kind))"
        case .previewed(nil): "Preview cleared"
        case let .historyStep(name): "Recorded “\(name)”"
        }
    }

    private func name(_ kind: PaletteItemKind) -> String {
        switch kind {
        case let .action(action): action.title
        case let .slider(parameter): parameter.displayName
        case let .page(page): page.title
        case let .setValue(parameter, value): "\(parameter.displayName) = \(parameter.spec.formatted(value))"
        case let .whiteBalance(mode): "White Balance \(mode.name)"
        case let .treatment(treatment): treatment.name
        case let .baseLook(id): model.recipes.currentBaseLooks.first { $0.id == id }?.name ?? id
        case let .recipe(id): model.recipes.recipe(id: id)?.name ?? id
        case let .compareLayout(layout): layout?.title ?? "Before / After off"
        case let .snapshot(id): model.snapshots.first { $0.id == id }?.name ?? "Snapshot"
        case let .historyStep(index): model.history.indices.contains(index) ? model.history[index].name : "Step"
        case let .filterPreset(id): model.libraryFilters?.presets.first { $0.id == id }?.name ?? id
        case let .customLabel(name): name
        }
    }

    // MARK: Launch steps

    /// For scripted screenshots: `--palette-steps "open;type:white;down"` drives the palette
    /// once a photo is open. Steps: `open`, `sliders`, `type:<text>` (`_` for a space), `up`, `down`, `left`,
    /// `right`, `shift-right`, `enter`, `esc`, `delete`, `panels`, `shift`, `play`, and
    /// `theme:<family>:<dark|light>` for the palette's own theme.
    func runLaunchSteps() async {
        guard let script = HarnessLaunch.value(after: "--palette-steps") else { return }
        for _ in 0 ..< 100 where model.info == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for step in script.split(separator: ";").map(String.init) {
            let palette = model.commandPalette
            switch step {
            case "open": model.openCommandPalette()
            case "sliders": model.openCommandPalette(scope: .sliders)
            case "up": palette?.handle(.up)
            case "down": palette?.handle(.down)
            case "left": palette?.handle(.left([]))
            case "right": palette?.handle(.right([]))
            case "shift-right": palette?.handle(.right(.shift))
            case "enter": palette?.handle(.submit)
            case "esc": palette?.handle(.escape)
            case "delete": palette?.handle(.deleteBackward)
            case "panels": showsPanels = true
            case "shift": palette?.heldModifiers = .shift
            case "play": await play()
            default:
                if step.hasPrefix("type:") {
                    // Launch arguments split on spaces, so `_` stands for one.
                    palette?.setText(step.dropFirst(5).replacingOccurrences(of: "_", with: " "))
                } else if step.hasPrefix("theme:") {
                    let parts = step.split(separator: ":").map(String.init)
                    paletteTheme = ThemeSelection(
                        familyID: parts.count > 1 ? parts[1] : ThemeCatalog.defaultID,
                        appearance: parts.count > 2 ? ThemeAppearance(rawValue: parts[2]) ?? .dark : .dark,
                    )
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Walkthrough

    /// The plan's keyboard walkthrough, one step at a time, to watch each land on the photo.
    func play() async {
        guard !isPlaying else { return }
        isPlaying = true
        defer { isPlaying = false }
        let pause = Duration.milliseconds(450)
        model.closeCommandPalette(.toggle)
        model.openCommandPalette()
        try? await Task.sleep(for: pause)
        for text in ["e", "ex", "exp", "expo"] {
            model.commandPalette?.setText(text)
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: pause)
        model.commandPalette?.handle(.submit)
        try? await Task.sleep(for: pause)
        for _ in 0 ..< 4 {
            model.commandPalette?.handle(.right([]))
            try? await Task.sleep(for: .milliseconds(140))
        }
        try? await Task.sleep(for: pause)
        for text in ["c", "co", "con"] {
            model.commandPalette?.setText(text)
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: pause)
        model.commandPalette?.handle(.submit)
        try? await Task.sleep(for: pause)
        for _ in 0 ..< 2 {
            model.commandPalette?.handle(.right(.shift))
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: pause)
        model.commandPalette?.handle(.escape)
        try? await Task.sleep(for: pause)
        model.commandPalette?.setText("portra")
        try? await Task.sleep(for: pause)
        model.commandPalette?.handle(.down)
        try? await Task.sleep(for: pause * 2)
        model.commandPalette?.handle(.up)
        try? await Task.sleep(for: pause * 2)
        model.commandPalette?.handle(.submit)
        try? await Task.sleep(for: pause * 2)
        undo()
    }
}

/// Every interaction worth trying, ticked when the session sees it happen.
enum PaletteCheck: String, CaseIterable, Identifiable {
    case openAll = "Open with ⌘K"
    case openSliders = "Open with ⌘F, for sliders only"
    case removeScope = "After ⌘F, ⌫ on the empty field to search everything"
    case highlight = "Move the highlight with ↑ ↓"
    case runAction = "Run an action with ↵"
    case tryUnavailable = "Try a dimmed row (nothing happens)"
    case closeEscape = "Close with Esc"
    case closeToggle = "Close with ⌘K"
    case closeClick = "Close by clicking outside"
    case newTip = "Reopen and see the next tip"
    case openSlider = "Open a slider with ↵"
    case nudge = "Step it with ← →"
    case nudgeShift = "Step ×10 with ⇧"
    case nudgeOption = "Step finer with ⌥"
    case modifierLit = "Hold ⇧ or ⌥ and see its hint light up"
    case burstStep = "Make one history step from a run of presses"
    case undoBurst = "⌘Z straight after a burst"
    case stepSlider = "Move to the next slider with ↑ ↓"
    case typeValue = "Type a value in the slider bar, then ↵"
    case invalidValue = "Type something that isn't a value"
    case reset = "Reset with ⌘⌫"
    case nameFromSlider = "Type a name in the slider bar to search again"
    case backDelete = "Go back with ⌫"
    case backEscape = "Go back with Esc"
    case done = "Finish with ↵ on an empty value"
    case typedFromSearch = "Set a value from the search (exposure 0.7)"
    case openPicker = "Open a picker"
    case preview = "Preview a choice by moving the highlight"
    case revertPreview = "Leave with Esc, so the preview reverts"
    case applyChoice = "Apply a choice with ↵"
    case deepSearch = "Apply a look or recipe straight from the top-level search"
    case sliderFromPicker = "Open Temp from White Balance"

    var id: String {
        rawValue
    }

    @MainActor
    func matches(_ event: PaletteEvent, palette: CommandPaletteModel?) -> Bool {
        switch (self, event) {
        case (.openAll, .opened(.all)), (.openSliders, .opened(.sliders)), (.removeScope, .scopeRemoved),
             (.highlight, .highlighted), (.runAction, .ran), (.tryUnavailable, .unavailable),
             (.closeEscape, .closed(.escape)), (.closeToggle, .closed(.toggle)),
             (.closeClick, .closed(.clickOutside)), (.openSlider, .openedSlider), (.stepSlider, .steppedSlider),
             (.typeValue, .setValue), (.invalidValue, .invalidValue), (.reset, .reset),
             (.nameFromSlider, .searchedFromSlider), (.backDelete, .wentBack(.delete)),
             (.backEscape, .wentBack(.escape)), (.done, .closed(.done)), (.typedFromSearch, .applied(.setValue)),
             (.openPicker, .pushed), (.preview, .previewed(.some(_))), (.revertPreview, .previewed(.none)):
            return true
        case let (.nudge, .nudged(_, _, modifiers)): return modifiers.isEmpty
        case let (.nudgeShift, .nudged(_, _, modifiers)): return modifiers.contains(.shift)
        case let (.nudgeOption, .nudged(_, _, modifiers)): return modifiers.contains(.option)
        case let (.applyChoice, .applied(kind)): return Self.isChoice(kind)
        case let (.deepSearch, .applied(kind)):
            guard palette?.page == nil else { return false }
            switch kind {
            case .baseLook, .recipe: return true
            default: return false
            }
        case (.sliderFromPicker, .openedSlider(.temperature)), (.sliderFromPicker, .openedSlider(.tint)):
            return palette?.levels.dropLast().contains { level in
                if case .list(page: .whiteBalance, _, _) = level {
                    return true
                }
                return false
            } == true
        default:
            return false
        }
    }

    private static func isChoice(_ kind: PaletteItemKind) -> Bool {
        switch kind {
        case .action, .slider, .page, .setValue: false
        default: true
        }
    }
}

// MARK: - Live scene

private struct PaletteLiveScene: View {
    private var session: PaletteSession {
        PaletteSession.shared
    }

    var body: some View {
        let model = HarnessEditor.model
        HStack(spacing: 0) {
            CanvasView(feed: model.frames, controller: model.canvas)
                .overlay {
                    // Above the Metal view, as the editor draws its chrome.
                    if let palette = model.commandPalette {
                        CommandPaletteOverlay(
                            palette: palette,
                            panelOpacity: 1 - session.panelTransparency,
                            theme: session.paletteTheme,
                            onAppAction: { session.appAction($0) },
                        )
                    } else {
                        ClosedHint()
                    }
                }
            if session.showsPanels {
                InspectorColumn(model: model)
                    .frame(width: 316)
            }
        }
        .task { await PaletteSession.shared.runLaunchSteps() }
        .onAppear { session.isLiveSceneShown = true }
        .onDisappear {
            session.isLiveSceneShown = false
            model.closeCommandPalette(.toggle)
        }
    }
}

/// What the scene shows while the palette is closed.
private struct ClosedHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Open the palette")
            KeyCaps(["⌘", "K"])
            Text("or, for sliders only,")
            KeyCaps(["⌘", "F"])
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 16)
        .allowsHitTesting(false)
    }
}

/// The AppKit Develop panels, as in the editor's right-hand column.
private struct InspectorColumn: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context _: Context) -> NSView {
        InspectorColumnViews.make(model: model)
    }

    func updateNSView(_: NSView, context _: Context) {}
}

// MARK: - Inspector

private struct PaletteInspector: View {
    @Bindable private var session = PaletteSession.shared

    var body: some View {
        let model = HarnessEditor.model
        let palette = model.commandPalette
        Form {
            Section("State") {
                LabeledContent("Open", value: palette.map { $0.scope == .all ? "Everything" : "Sliders only" } ?? "No")
                LabeledContent("Levels", value: palette.map(levels) ?? "–")
                LabeledContent("Highlighted", value: palette?.selectedItem?.title ?? "–")
                LabeledContent("Text", value: palette.map { "“\($0.text)”" } ?? "–")
                LabeledContent(
                    "Hints",
                    value: palette?.hints.map { "\($0.title) \($0.keys.joined())" }
                        .joined(separator: " · ") ?? "–",
                )
                LabeledContent("Held", value: palette.map(held) ?? "–")
                LabeledContent("History step open", value: palette?.hasOpenStep == true ? "Yes" : "No")
                LabeledContent("Previewing", value: previewing(palette, model: model))
                LabeledContent("Focused slider", value: model.focusedParameter?.displayName ?? "–")
            }

            Section("Conditions") {
                Picker("Photo", selection: $session.photo) {
                    ForEach(HarnessEditor.Photo.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: session.photo) { _, photo in Task { await HarnessEditor.show(photo) } }
                Toggle("Masking tool", isOn: Binding(
                    get: { model.activeTool == .masking },
                    set: { model.activeTool = $0 ? .masking : .edit },
                ))
                Button("Copy Settings") { model.copySettings() }
                    .disabled(model.info == nil)
                Knob("Panel transparency", $session.panelTransparency, 0 ... 1)
                Picker("Palette theme", selection: Binding(
                    get: { session.paletteTheme != nil },
                    set: { own in session.paletteTheme = own ? (session.paletteTheme ?? ThemeSelection()) : nil },
                )) {
                    Text("Same as the harness").tag(false)
                    Text("Its own").tag(true)
                }
                if let paletteTheme = session.paletteTheme {
                    ThemePicker(selection: Binding(get: { paletteTheme }, set: { session.paletteTheme = $0 }))
                    Picker("Palette appearance", selection: Binding(
                        get: { paletteTheme.appearance },
                        set: { session.paletteTheme?.appearance = $0 },
                    )) {
                        Text("Dark").tag(ThemeAppearance.dark)
                        Text("Light").tag(ThemeAppearance.light)
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Next tip", selection: Binding(
                    get: { palette?.tip ?? -1 },
                    set: { index in
                        PaletteTips.setNext(index + 1)
                        palette?.tip = index
                    },
                )) {
                    ForEach(PaletteTips.all.indices, id: \.self) { Text("Tip \($0 + 1)").tag($0) }
                }
                .disabled(palette == nil)
                Toggle("Develop panels beside the photo", isOn: $session.showsPanels)
            }

            Section("Timing") {
                Knob("Preview delay (ms)", $session.previewDelay, 0 ... 600, step: 10)
                Knob("History step gap (ms)", $session.burstGap, 100 ... 1500, step: 50)
            }

            Section("Edit") {
                Button("Reset the Edit") { model.resetAll() }
                Button("Clear History") { model.clearHistory() }
                Button(session.isPlaying ? "Playing…" : "Play the Walkthrough") {
                    Task { await session.play() }
                }
                .disabled(session.isPlaying || model.info == nil)
            }

            Section("Checklist: \(session.ticked.count) of \(PaletteCheck.allCases.count)") {
                ForEach(PaletteCheck.allCases) { check in
                    let done = session.ticked.contains(check)
                    Label(check.rawValue, systemImage: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? .primary : .secondary)
                }
                Button("Start Again") { session.resetChecklist() }
            }

            Section("Log") {
                Button("Clear") { session.clearLog() }
                ForEach(session.log.suffix(150).reversed()) { entry in
                    Text(entry.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(entry.isHistory ? .secondary : .primary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func levels(_ palette: CommandPaletteModel) -> String {
        palette.levels.map { level in
            switch level {
            case let .list(page, _, _): page?.title ?? "Search"
            case let .slider(parameter, _): parameter.displayName
            }
        }
        .joined(separator: " › ")
    }

    private func held(_ palette: CommandPaletteModel) -> String {
        var keys = ""
        if palette.heldModifiers.contains(.shift) {
            keys += "⇧"
        }
        if palette.heldModifiers.contains(.option) {
            keys += "⌥"
        }
        return keys.isEmpty ? "None" : keys
    }

    private func previewing(_ palette: CommandPaletteModel?, model: EditorModel) -> String {
        if let recipe = model.previewingRecipe {
            return recipe.name
        }
        if model.previewingEdit != nil {
            return palette?.previewing.map { "\($0)" } ?? "An edit"
        }
        return "–"
    }
}

// MARK: - States

private struct PaletteStatesScene: View {
    /// Made once the photo is open, since pickers and dimming depend on it.
    @State private var specimens: PaletteSpecimens?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let specimens {
                ForEach(specimens.all) { specimen in
                    SpecimenGroup(title: specimen.title, note: specimen.note) {
                        CommandPaletteView(
                            palette: specimen.palette, panelOpacity: 0.4, theme: specimen.theme, isInteractive: false,
                        )
                    }
                }
            } else {
                ProgressView("Opening the sample photo…")
            }
        }
        .task {
            for _ in 0 ..< 100 where HarnessEditor.model.info == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            specimens = PaletteSpecimens()
        }
    }
}

@MainActor
private struct PaletteSpecimens {
    struct Specimen: Identifiable {
        let title: String
        let note: String
        let palette: CommandPaletteModel
        var theme: ThemeSelection?

        var id: String {
            title
        }
    }

    let all: [Specimen]

    init() {
        let model = HarnessEditor.model
        func make(_ scope: PaletteScope = .all, tip: Int = 0, _ setUp: (CommandPaletteModel) -> Void = { _ in })
            -> CommandPaletteModel {
            let palette = CommandPaletteModel(editor: model, scope: scope, tip: tip, isSpecimen: true)
            setUp(palette)
            return palette
        }
        func open(_ page: PalettePage, in palette: CommandPaletteModel) {
            if let item = palette.rows.first(where: { $0.kind == .page(page) }) {
                palette.activate(item)
            }
        }
        all = [
            Specimen(
                title: "Empty search",
                note: "Sections to browse, a tip beside the hint capsule, and Close Esc. Nothing behind the palette is dimmed.",
                palette: make(),
            ),
            Specimen(
                title: "Results",
                note: "Each kind of row: a picker's chevron, sliders with their values (and the edited dot), actions with their keys. The first hint names what ↵ does.",
                palette: make(tip: 1) { $0.setText("white") },
            ),
            Specimen(
                title: "Dimmed actions",
                note: "Masking actions outside the Masking tool can't run: dimmed, and ↵ only beeps.",
                palette: make(tip: 2) { $0.setText("mask overlay") },
            ),
            Specimen(
                title: "Typed value",
                note: "“exposure 0.7” puts Set Exposure first, with the change it makes.",
                palette: make(tip: 3) { $0.setText("exposure 0.7") },
            ),
            Specimen(
                title: "No results",
                note: "Says what wasn't found; the hint bar still shows how to leave.",
                palette: make(tip: 4) { $0.setText("zzzz") },
            ),
            Specimen(
                title: "Sliders only (⌘F)",
                note: "The slider symbol in the field, and the line beside the capsule says how to search everything.",
                palette: make(.sliders),
            ),
            Specimen(
                title: "Picker",
                note: "The page's name as a chip in the field, Preview ↑ ↓ first in the capsule, and the current choice checked.",
                palette: make { open(.whiteBalance, in: $0) },
            ),
            Specimen(
                title: "Recipes picker",
                note: "Recipes in their sections; in the Live scene the highlighted one previews on the photo.",
                palette: make {
                    open(.recipes, in: $0)
                    $0.handle(.down)
                },
            ),
            Specimen(
                title: "Slider bar",
                note: "← → at the ends of the track, ↑ ↓ beside the neighbouring sliders, and the value field's placeholder says it takes a value or a name.",
                palette: make { $0.openSlider(.exposure) },
            ),
            Specimen(
                title: "Slider bar, typing",
                note: "The typed expression on the right; the capsule's Done becomes Set.",
                palette: make {
                    $0.openSlider(.exposure)
                    $0.setText("x+0.3")
                },
            ),
            Specimen(
                title: "Slider bar, value not understood",
                note: "Red text, and nothing changes until it parses.",
                palette: make {
                    $0.openSlider(.contrast)
                    $0.setText("1..2")
                    $0.handle(.submit)
                },
            ),
            Specimen(
                title: "Slider bar, ⇧ held",
                note: "The ×10 hint lights up in the accent colour while ⇧ is held.",
                palette: make {
                    $0.openSlider(.temperature)
                    $0.heldModifiers = .shift
                },
            ),
            Specimen(
                title: "Its own theme",
                note: "Settings ▸ Appearance ▸ Command Palette: Tokyo Night light over whatever the harness is drawn in. "
                    + "Keycaps, the slider and the glass all take it; nothing else in the window does.",
                palette: make(tip: 5) { $0.setText("exposure") },
                theme: ThemeSelection(familyID: "tokyo-night", appearance: .light),
            ),
            Specimen(
                title: "Its own theme, slider bar",
                note: "The same theme in the slider bar: the track and thumb follow it too.",
                palette: make { $0.openSlider(.exposure) },
                theme: ThemeSelection(familyID: "tokyo-night", appearance: .light),
            ),
        ]
    }
}
