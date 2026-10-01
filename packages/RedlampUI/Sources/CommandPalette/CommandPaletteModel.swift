import AppKit
import Foundation
import Observation
import RedlampEngineAPI
import RedlampRecipes

/// The command palette (⌘K) while it's open: a stack of levels (the search, a picker, the
/// slider bar), what's highlighted, and everything its keys do. `EditorModel.commandPalette`
/// owns it; the views and the harness only call its methods.
@_spi(Harness) @MainActor @Observable
public final class CommandPaletteModel {
    /// How long the highlight must rest on a choice before it previews on the photo.
    public static var previewDelay: Duration = .milliseconds(150)
    /// Arrow presses closer together than this make one history step, as ⌘-scroll does.
    public static var burstGap: Duration = .milliseconds(500)

    @ObservationIgnored public unowned let editor: EditorModel
    public private(set) var scope: PaletteScope
    public private(set) var levels: [PaletteLevel]
    /// The rows of the topmost list level.
    public private(set) var sections: [PaletteSection] = []
    public private(set) var rows: [PaletteItem] = []
    /// ⇧ and ⌥ light up their hints in the slider bar.
    public var heldModifiers: PaletteModifiers = []
    /// The tip shown at the top level, an index into `PaletteTips.all`.
    public var tip: Int
    /// What the slider bar's value field holds doesn't parse.
    public internal(set) var typedIsInvalid = false
    /// Bumped when the text changes other than by typing, so the field resets its selection:
    /// all of it when going back, the end after a letter typed in the slider bar.
    public private(set) var textRevision = 0
    public private(set) var selectsTextOnRevision = true
    /// The choice previewing on the photo.
    public internal(set) var previewing: PaletteItemKind?
    /// Runs what only the app can: Open Folder, Export and Film Looks.
    @ObservationIgnored public var performAppAction: (ShortcutAction) -> Void = { _ in }

    /// Harness specimens: they don't preview, report events or move the editor's focus.
    @ObservationIgnored let isSpecimen: Bool
    var burstParameter: ParameterID?
    @ObservationIgnored var burstEnd: Task<Void, Never>?
    @ObservationIgnored var previewTask: Task<Void, Never>?

    public init(editor: EditorModel, scope: PaletteScope, tip: Int, isSpecimen: Bool = false) {
        self.editor = editor
        self.scope = scope
        self.tip = tip
        self.isSpecimen = isSpecimen
        levels = [.list(page: nil, query: "", selection: 0)]
        refresh()
    }

    // MARK: - State

    public var level: PaletteLevel {
        levels[levels.count - 1]
    }

    public var isNested: Bool {
        levels.count > 1
    }

    /// Arrow presses are being gathered into one history step.
    public var hasOpenStep: Bool {
        burstParameter != nil
    }

    public var page: PalettePage? {
        if case let .list(page, _, _) = level {
            return page
        }
        return nil
    }

    /// The slider bar's slider.
    public var sliderParameter: ParameterID? {
        if case let .slider(parameter, _) = level {
            return parameter
        }
        return nil
    }

    /// The search text, or what's typed into the slider bar.
    public var text: String {
        switch level {
        case let .list(_, query, _): query
        case let .slider(_, typed): typed
        }
    }

    public var selectionIndex: Int? {
        if case let .list(_, _, selection) = level, rows.indices.contains(selection) {
            return selection
        }
        return nil
    }

    public var selectedItem: PaletteItem? {
        selectionIndex.map { rows[$0] }
    }

    /// Whether ↵ on the row would do something now.
    public func isEnabled(_ item: PaletteItem) -> Bool {
        switch item.kind {
        case let .action(action): editor.canPerform(action)
        case let .slider(parameter), let .setValue(parameter, _): isLive(parameter)
        case let .page(page): PaletteCatalog.isAvailable(page, editor: editor)
        case .whiteBalance: editor.info?.supportsWhiteBalance == true
        default: editor.info != nil
        }
    }

    /// Whether the slider can move on this photo (Temp and Tint need white balance).
    public func isLive(_ parameter: ParameterID) -> Bool {
        guard editor.info != nil, parameter.spec.availability.isLive else { return false }
        if parameter == .temperature || parameter == .tint {
            return editor.info?.supportsWhiteBalance == true
        }
        return true
    }

    /// The sliders ↑ and ↓ move to: the previous and next live ones in the same panel.
    public func neighbours(of parameter: ParameterID) -> (previous: ParameterID?, next: ParameterID?) {
        guard let panel = PanelID.allCases.first(where: { $0.parameters.contains(parameter) })
        else { return (nil, nil) }
        let cycle = panel.parameters.filter { $0 == parameter || isLive($0) }
        guard let index = cycle.firstIndex(of: parameter) else { return (nil, nil) }
        return (index > 0 ? cycle[index - 1] : nil, index + 1 < cycle.count ? cycle[index + 1] : nil)
    }

    // MARK: - Typing

    public func setText(_ text: String) {
        switch level {
        case let .list(page, query, _):
            guard text != query else { return }
            replaceTop(.list(page: page, query: text, selection: 0))
            refresh()
            highlightChanged()
        case let .slider(parameter, typed):
            guard text != typed else { return }
            // A name instead of a value: back to the search to find another slider.
            if typed.isEmpty, let first = text.first, first.isLetter, first.lowercased() != "x" {
                endBurst()
                levels.removeLast()
                if case let .list(page, _, _) = level {
                    replaceTop(.list(page: page, query: text, selection: 0))
                }
                refresh()
                revealText(selectAll: false)
                report(.searchedFromSlider(text))
                highlightChanged()
                return
            }
            typedIsInvalid = false
            replaceTop(.slider(parameter, typed: text))
        }
    }

    // MARK: - Keys

    /// Handles a key; `false` leaves it to the text field (←, → and ⌫ edit the search).
    @discardableResult
    public func handle(_ key: PaletteKey) -> Bool {
        switch level {
        case .list: handleList(key)
        case let .slider(parameter, typed): handleSlider(key, parameter: parameter, typed: typed)
        }
    }

    private func handleList(_ key: PaletteKey) -> Bool {
        switch key {
        case .up:
            moveSelection(by: -1)
        case .down:
            moveSelection(by: 1)
        case .submit:
            if let item = selectedItem {
                activate(item)
            }
        case .escape:
            back(.escape)
        case .deleteBackward:
            if isNested {
                back(.delete)
            } else if scope == .sliders {
                scope = .all
                refresh()
                report(.scopeRemoved)
            } else {
                return false
            }
        case .left, .right, .reset:
            return false
        }
        return true
    }

    private func handleSlider(_ key: PaletteKey, parameter: ParameterID, typed: String) -> Bool {
        switch key {
        case let .left(modifiers): nudge(parameter, by: -1, modifiers)
        case let .right(modifiers): nudge(parameter, by: 1, modifiers)
        case .up: step(from: parameter, by: -1)
        case .down: step(from: parameter, by: 1)
        case .submit:
            if typed.isEmpty {
                close(.done)
            } else {
                commitTyped(typed, to: parameter)
            }
        case .escape: back(.escape)
        case .deleteBackward: back(.delete)
        case .reset:
            endBurst()
            recordingStep { editor.resetSlider(parameter) }
            report(.reset(parameter))
        }
        return true
    }

    /// Highlights a row (a click does this before activating it).
    public func select(_ item: PaletteItem) {
        guard case let .list(page, query, selection) = level, let index = rows.firstIndex(of: item),
              index != selection
        else { return }
        replaceTop(.list(page: page, query: query, selection: index))
        report(.highlighted(item.kind))
        highlightChanged()
    }

    private func moveSelection(by offset: Int) {
        guard case let .list(page, query, selection) = level, !rows.isEmpty else { return }
        let next = min(max(selection + offset, 0), rows.count - 1)
        guard next != selection else { return }
        replaceTop(.list(page: page, query: query, selection: next))
        report(.highlighted(rows[next].kind))
        highlightChanged()
    }

    // MARK: - Activating rows

    /// ↵ on a row, or a click.
    public func activate(_ item: PaletteItem) {
        guard isEnabled(item) else {
            report(.unavailable(item.kind))
            if !isSpecimen {
                NSSound.beep()
            }
            return
        }
        switch item.kind {
        case let .action(action):
            run(action)
        case let .slider(parameter):
            openSlider(parameter)
        case let .page(page):
            push(page)
        case let .setValue(parameter, value):
            endBurst()
            recordingStep { editor.setSliderValue(parameter, value) }
            report(.applied(item.kind))
            close(.applied)
        default:
            clearPreview()
            recordingStep { apply(item.kind) }
            report(.applied(item.kind))
            close(.applied)
        }
    }

    private static let appActions: Set<ShortcutAction> = [.openFolder, .export, .exportWithPrevious, .filmLooks]

    private func run(_ action: ShortcutAction) {
        report(.ran(action))
        let performAppAction = performAppAction
        close(.ran)
        if Self.appActions.contains(action) {
            performAppAction(action)
        } else {
            editor.perform(action)
        }
    }

    private func push(_ page: PalettePage) {
        endBurst()
        clearPreview()
        levels.append(.list(page: page, query: "", selection: 0))
        refresh()
        revealText(selectAll: true)
        report(.pushed(page))
        highlightChanged()
    }

    public func openSlider(_ parameter: ParameterID) {
        endBurst()
        clearPreview()
        levels.append(.slider(parameter, typed: ""))
        typedIsInvalid = false
        if !isSpecimen {
            editor.focusedParameter = parameter
        }
        revealText(selectAll: false)
        report(.openedSlider(parameter))
    }

    private func back(_ key: PaletteBackKey) {
        guard isNested else {
            if key == .escape {
                close(.escape)
            }
            return
        }
        endBurst()
        clearPreview()
        levels.removeLast()
        refresh()
        revealText(selectAll: true)
        report(.wentBack(key))
        highlightChanged()
    }

    private func close(_ reason: PaletteCloseReason) {
        guard !isSpecimen else { return }
        editor.closeCommandPalette(reason)
    }

    /// Ends what's in progress before the palette goes away: a burst of arrow presses and
    /// any preview.
    func finish() {
        endBurst()
        clearPreview()
        previewTask?.cancel()
    }

    // MARK: - Helpers

    func replaceTop(_ level: PaletteLevel) {
        levels[levels.count - 1] = level
    }

    func refresh() {
        guard case let .list(page, query, _) = level else { return }
        sections = PaletteCatalog.sections(page: page, scope: scope, query: query, editor: editor)
        rows = sections.flatMap(\.items)
    }

    func revealText(selectAll: Bool) {
        selectsTextOnRevision = selectAll
        textRevision &+= 1
    }

    /// Runs `change` and reports the history step it recorded, if any.
    func recordingStep(_ change: () -> Void) {
        let last = editor.history.last?.id
        change()
        if let step = editor.history.last, step.id != last {
            report(.historyStep(step.name))
        }
    }

    func report(_ event: PaletteEvent) {
        guard !isSpecimen else { return }
        editor.onCommandPaletteEvent?(event)
    }
}
