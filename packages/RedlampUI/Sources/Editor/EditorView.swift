import AppKit
import RedlampCanvas
import SwiftUI

/// Panel widths and spacing.
enum PanelMetrics {
    static let sidebarNominal: CGFloat = 250
    static let sidebarRange: ClosedRange<CGFloat> = 220 ... 380
    static let inspectorNominal: CGFloat = 316
    static let inspectorRange: ClosedRange<CGFloat> = 290 ... 440
    /// The gap macOS 26 leaves around a floating sidebar, kept around the filmstrip too.
    static let inset: CGFloat = 8
    /// How close to the bottom edge the pointer brings the filmstrip in.
    static let filmstripTrigger: CGFloat = 14
}

/// The canvas layer of the editor window (see `EditorWindowController`): the photo spans the
/// whole window, under the toolbar and both panels, which float over it. The photo is
/// fitted to a fixed stage that keeps clear of the panels' nominal widths whether they are
/// showing or not, so showing, hiding or resizing a panel never moves it. Only presenting
/// (full screen with every panel hidden) gives it the whole window.
struct EditorContentView: View {
    @Bindable var model: EditorModel
    @Bindable var theme: ThemeSettings
    let onOpen: () -> Void
    @State private var toolbarHeight: CGFloat = 0

    var body: some View {
        CanvasArea(onOpen: onOpen)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                if model.filmstripVisible, !model.items.isEmpty, model.lightsOut == 0 {
                    FloatingFilmstrip()
                        .id(theme.selection)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { toolbarHeight = $0 }
            .sheet(item: $model.stackWorkspace) { workspace in
                StackWorkspaceView(workspace: workspace, onDone: model.finishStackWorkspace)
                    .environment(theme)
            }
            .onAppear(perform: updateStage)
            .onChange(of: toolbarHeight) { _, _ in updateStage() }
            .onChange(of: model.isPresenting) { _, _ in updateStage() }
            .environment(model)
            .environment(theme)
            .tint(Theme.nativeTint)
            .focusEffectDisabled()
    }

    private func updateStage() {
        model.canvas.stageInsets = model.isPresenting ? .zero : StageInsets(
            leading: PanelMetrics.inset + PanelMetrics.sidebarNominal + PanelMetrics.inset,
            trailing: PanelMetrics.inspectorNominal + PanelMetrics.inset,
            top: toolbarHeight,
            bottom: PanelMetrics.inset,
        )
    }
}

/// The ⌘/ shortcuts and the ⌘K command palette, laid over the whole window, panels included.
struct EditorOverlays: View {
    @Bindable var model: EditorModel
    @Bindable var theme: ThemeSettings
    let onOpen: () -> Void
    let onExport: () -> Void
    let onExportWithPrevious: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            if model.showShortcuts {
                ShortcutsSheet()
            }
            if let palette = model.commandPalette {
                CommandPaletteOverlay(
                    palette: palette, panelOpacity: theme.panelOpacity, theme: theme.paletteSelection, onAppAction: run,
                )
            }
        }
        .environment(model)
        .environment(theme)
        .tint(Theme.nativeTint)
        .focusEffectDisabled()
    }

    /// The palette's actions that the app, not the editor, performs.
    private func run(_ action: ShortcutAction) {
        switch action {
        case .openFolder: onOpen()
        case .export: onExport()
        case .exportWithPrevious: onExportWithPrevious()
        case .filmLooks: openWindow(id: FilmCatalogView.windowID)
        default: model.perform(action)
        }
    }
}

/// The filmstrip floats at the bottom between the panels, in the same kind of pane, and
/// keeps out of the way of editing: it slides in while the pointer is at the bottom edge or
/// over it, and away shortly after the pointer leaves. With nothing selected it stays, as
/// it is the way to pick a photo. It also comes up for a few seconds when a focus stack is
/// found, so its banner is seen.
private struct FloatingFilmstrip: View {
    @Environment(EditorModel.self) private var model
    @Environment(ThemeSettings.self) private var theme
    @State private var revealed = false
    @State private var overEdge = false
    @State private var overStrip = false
    @State private var hiding: Task<Void, Never>?

    var body: some View {
        let shown = revealed || model.selection == nil
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(height: PanelMetrics.filmstripTrigger)
                .contentShape(Rectangle())
                .onHover { inside in
                    overEdge = inside
                    hoverChanged()
                }
            if shown {
                FilmstripView()
                    .modifier(FloatingPane(opacity: theme.panelOpacity))
                    .onHover { inside in
                        overStrip = inside
                        hoverChanged()
                    }
                    .padding(.horizontal, PanelMetrics.inset)
                    .padding(.bottom, PanelMetrics.inset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .animation(.snappy(duration: 0.25), value: shown)
        .onChange(of: model.stackSuggestions) { old, new in
            if new.contains(where: { !old.contains($0) }) {
                reveal()
                scheduleHide(after: .seconds(5))
            }
        }
    }

    private func hoverChanged() {
        if overEdge || overStrip {
            reveal()
        } else {
            scheduleHide()
        }
    }

    private func reveal() {
        hiding?.cancel()
        hiding = nil
        revealed = true
    }

    private func scheduleHide(after delay: Duration = .milliseconds(600)) {
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !overEdge, !overStrip else { return }
            revealed = false
        }
    }
}

/// A floating pane matching macOS 26's sidebar: Liquid Glass with corners concentric with
/// the window's, washed with the theme's panel color (`ThemeSettings.panelOpacity`) as the
/// panels are.
struct FloatingPane: ViewModifier {
    let opacity: Double
    @Environment(\.themeTokens) private var themeTokens

    private var shape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(18)), isUniform: true)
    }

    func body(content: Content) -> some View {
        content
            .clipShape(shape)
            .background(ThemeColors(themeTokens).panelBackground.opacity(opacity), in: shape)
            .glassEffect(.regular, in: shape)
    }
}
