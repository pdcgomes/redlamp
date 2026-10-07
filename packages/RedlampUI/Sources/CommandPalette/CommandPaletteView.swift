import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

enum PaletteMetrics {
    static let width: CGFloat = 620
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 26
    static let maxListHeight: CGFloat = 372
    /// The palette sits over the photo, not beside it, so it keeps more of the panel color
    /// than the panels do at high transparency, to stay legible over a busy frame.
    static func paneOpacity(_ panelOpacity: Double) -> Double {
        max(panelOpacity, 0.78)
    }
}

/// The palette over a window or a scene: top centre, with nothing dimmed behind it (a dark
/// backdrop changes how tones read), and a click outside closes it.
@_spi(Harness) public struct CommandPaletteOverlay: View {
    let palette: CommandPaletteModel
    let panelOpacity: Double
    let theme: ThemeSelection?
    let onAppAction: (ShortcutAction) -> Void

    /// `theme` is the palette's own theme (`ThemeSettings.paletteSelection`); `nil` draws it
    /// in the app's.
    public init(
        palette: CommandPaletteModel, panelOpacity: Double, theme: ThemeSelection? = nil,
        onAppAction: @escaping (ShortcutAction) -> Void,
    ) {
        self.palette = palette
        self.panelOpacity = panelOpacity
        self.theme = theme
        self.onAppAction = onAppAction
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { palette.editor.closeCommandPalette(.clickOutside) }
            CommandPaletteView(palette: palette, panelOpacity: panelOpacity, theme: theme)
                .padding(.top, 12)
        }
        .task(id: ObjectIdentifier(palette)) { palette.performAppAction = onAppAction }
    }
}

/// The palette itself: the search and its rows, or the slider bar, with key hints.
@_spi(Harness) public struct CommandPaletteView: View {
    let palette: CommandPaletteModel
    let panelOpacity: Double
    let theme: ThemeSelection?
    /// Takes keyboard focus and watches modifier keys; harness specimens don't.
    var isInteractive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modifierMonitor = ModifierMonitor()

    public init(
        palette: CommandPaletteModel, panelOpacity: Double, theme: ThemeSelection? = nil, isInteractive: Bool = true,
    ) {
        self.palette = palette
        self.panelOpacity = panelOpacity
        self.theme = theme
        self.isInteractive = isInteractive
    }

    public var body: some View {
        Group {
            if let parameter = palette.sliderParameter {
                PaletteSliderBar(
                    palette: palette, parameter: parameter, panelOpacity: panelOpacity, isInteractive: isInteractive,
                )
                .transition(.opacity)
            } else {
                PaletteList(palette: palette, panelOpacity: panelOpacity, isInteractive: isInteractive)
                    .transition(.opacity)
            }
        }
        .frame(width: PaletteMetrics.width)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: palette.sliderParameter == nil)
        .environment(\.themeTokens, theme?.tokens)
        // Its own theme may be the other half (light over a dark editor): the glass and the
        // text field follow it.
        .transformEnvironment(\.colorScheme) { scheme in
            if let theme {
                scheme = theme.appearance == .dark ? .dark : .light
            }
        }
        .onAppear {
            if isInteractive {
                modifierMonitor.start { palette.heldModifiers = $0 }
            }
        }
        .onDisappear { modifierMonitor.stop() }
    }
}

/// Tells the palette which of ⇧ and ⌥ are held, to light up their hints.
@MainActor
final class ModifierMonitor {
    private var monitor: Any?

    func start(_ update: @escaping @MainActor (PaletteModifiers) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            var modifiers: PaletteModifiers = []
            if event.modifierFlags.contains(.shift) {
                modifiers.insert(.shift)
            }
            if event.modifierFlags.contains(.option) {
                modifiers.insert(.option)
            }
            MainActor.assumeIsolated { update(modifiers) }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

// MARK: - The list

private struct PaletteList: View {
    let palette: CommandPaletteModel
    let panelOpacity: Double
    let isInteractive: Bool
    @Environment(\.themeTokens) private var themeTokens
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = ThemeColors(themeTokens)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: fieldSymbol)
                    .font(.system(size: 15))
                    .foregroundStyle(colors.secondaryLabel)
                    .frame(width: 20)
                if let page = palette.page {
                    Text(page.title)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(colors.selection))
                        .foregroundStyle(colors.value)
                }
                PaletteQueryField(
                    text: palette.text,
                    placeholder: placeholder,
                    textColor: colors.tokens.value.nsColor,
                    placeholderColor: colors.tokens.tertiaryLabel.nsColor,
                    colorScheme: colorScheme,
                    revision: palette.textRevision,
                    selectsAll: palette.selectsTextOnRevision,
                    focuses: isInteractive,
                    onChange: { palette.setText($0) },
                    onKey: { palette.handle($0) },
                )
            }
            .padding(.horizontal, 14)
            .frame(height: 50)

            Rectangle().fill(colors.divider).frame(height: 1)

            PaletteResults(palette: palette)
        }
        .modifier(FloatingPane(opacity: PaletteMetrics.paneOpacity(panelOpacity)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private var fieldSymbol: String {
        if palette.page != nil {
            return "chevron.left"
        }
        return palette.scope == .sliders ? "slider.horizontal.3" : "magnifyingglass"
    }

    private var placeholder: String {
        if let page = palette.page {
            return "Search \(page.title)…"
        }
        return palette.scope == .sliders ? "Find a slider (for example “haze”)" : "Search commands, sliders and looks…"
    }
}

private struct PaletteResults: View {
    let palette: CommandPaletteModel
    @Environment(\.themeTokens) private var themeTokens

    var body: some View {
        let colors = ThemeColors(themeTokens)
        let sections = palette.sections
        let selected = palette.selectedItem?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sections.allSatisfy(\.items.isEmpty) {
                        Text(palette.nothingFound)
                            .font(.system(size: 12))
                            .foregroundStyle(colors.secondaryLabel)
                            .padding(.horizontal, 10)
                            .frame(height: PaletteMetrics.rowHeight)
                    }
                    ForEach(sections) { section in
                        if let title = section.title, !section.items.isEmpty {
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(colors.tertiaryLabel)
                                .padding(.horizontal, 10)
                                .frame(height: PaletteMetrics.headerHeight, alignment: .bottomLeading)
                        }
                        ForEach(section.items) { item in
                            PaletteRow(palette: palette, item: item)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    palette.select(item)
                                    palette.activate(item)
                                }
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            // An inset rather than an overlay: the list still scrolls under the bar, but
            // scrolling to the highlighted row keeps it clear of the bar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PaletteListHintBar(palette: palette)
            }
            .frame(height: height(sections))
            .onChange(of: selected) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func height(_ sections: [PaletteSection]) -> CGFloat {
        let rows = sections.reduce(0) { $0 + $1.items.count }
        let headers = sections.count(where: { $0.title != nil && !$0.items.isEmpty })
        let content = CGFloat(max(rows, 1)) * PaletteMetrics.rowHeight + CGFloat(headers) * PaletteMetrics.headerHeight
        return min(content + 52, PaletteMetrics.maxListHeight)
    }
}

extension CommandPaletteModel {
    /// What the list says when nothing matches: while the library opens, that its labels are still to come.
    var nothingFound: String {
        switch (text.isEmpty, editor.library.libraryWaiting) {
        case let (true, waiting?): "\(waiting)…"
        case let (false, waiting?): "No matches for “\(text)” yet. \(waiting)…"
        case (true, nil): "Nothing here yet."
        case (false, nil): "No matches for “\(text)”."
        }
    }
}

/// The hint bar under the list, fading the rows that scroll beneath it.
private struct PaletteListHintBar: View {
    let palette: CommandPaletteModel
    @Environment(\.themeTokens) private var themeTokens

    var body: some View {
        let colors = ThemeColors(themeTokens)
        PaletteHintBar(hints: palette.hints, leading: palette.leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: colors.panelBackground.opacity(0), location: 0),
                        .init(color: colors.panelBackground.opacity(0.96), location: 0.3),
                        .init(color: colors.panelBackground.opacity(0.98), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom,
                )
                .padding(.top, -12)
                .allowsHitTesting(false),
            )
    }
}

private struct PaletteRow: View {
    let palette: CommandPaletteModel
    let item: PaletteItem
    @Environment(\.themeTokens) private var themeTokens

    var body: some View {
        let colors = ThemeColors(themeTokens)
        // Read here rather than passed in: a lazy list keeps the rows it has made, so a
        // value handed down from the list can go stale.
        let selected = palette.selectedItem?.id == item.id
        let enabled = palette.isEnabled(item)
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? colors.value : colors.secondaryLabel)
                .frame(width: 20)
            Text(item.title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(colors.value)
                .lineLimit(1)
                .layoutPriority(1)
            Text(item.context)
                .font(.system(size: 12))
                .foregroundStyle(colors.tertiaryLabel)
                .lineLimit(1)
            Spacer(minLength: 8)
            PaletteRowTrailing(palette: palette, kind: item.kind)
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? colors.selection : .clear))
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(selected ? palette.hints.map { "\($0.title): \($0.keys.joined(separator: " "))" }
            .joined(separator: ", ") : "")
    }
}

/// The right side of a row: an action's keys, a slider's value, a picker's chevron, or a
/// check on the current choice.
private struct PaletteRowTrailing: View {
    let palette: CommandPaletteModel
    let kind: PaletteItemKind
    @Environment(\.themeTokens) private var themeTokens

    var body: some View {
        let colors = ThemeColors(themeTokens)
        let editor = palette.editor
        switch kind {
        case let .action(action):
            HStack(spacing: 6) {
                if let phase = action.plannedPhase {
                    Text(phase).font(.system(size: 10)).foregroundStyle(colors.tertiaryLabel)
                }
                if let combo = action.combos.first {
                    KeyCaps(combo.keys)
                }
            }
        case let .slider(parameter):
            HStack(spacing: 5) {
                if editor.info != nil {
                    Text(parameter.spec.formatted(editor.sliderValue(parameter)))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(colors.value)
                }
                Circle()
                    .fill(colors.editedDot)
                    .frame(width: 5, height: 5)
                    .opacity(editor.info != nil && editor.isEdited(parameter) ? 1 : 0)
            }
        case .page:
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(colors.tertiaryLabel)
        case let .setValue(parameter, value):
            Text("\(parameter.spec.formatted(editor.sliderValue(parameter))) → \(parameter.spec.formatted(value))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(colors.value)
        default:
            HStack(spacing: 6) {
                if let action = Self.relatedAction(kind), let combo = action.combos.first {
                    KeyCaps(combo.keys)
                }
                if isCurrent(kind, editor: editor) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.accent)
                }
            }
        }
    }

    /// A shortcut that makes the same choice without the palette.
    private static func relatedAction(_ kind: PaletteItemKind) -> ShortcutAction? {
        switch kind {
        case .whiteBalance(.auto): .autoWhiteBalance
        case .treatment(.blackAndWhite): .toggleBlackAndWhite
        default: nil
        }
    }

    private func isCurrent(_ kind: PaletteItemKind, editor: EditorModel) -> Bool {
        switch kind {
        case let .whiteBalance(mode): editor.whiteBalanceMode == mode
        case let .treatment(treatment): editor.treatment == treatment
        case let .baseLook(id): editor.baseLook.id == id
        case let .recipe(id): editor.appliedRecipe?.id == id
        case let .compareLayout(layout?): editor.showBefore && editor.compareLayout == layout
        case .compareLayout(nil): !editor.showBefore
        case let .historyStep(index): index == editor.historyIndex
        case let .filterPreset(id): editor.libraryFilters?.preset?.id == id
        default: false
        }
    }
}
