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
    /// The filmstrip's height, its header and its photos.
    static let filmstripHeight: CGFloat = 110

    /// The stage the photo is fitted to (`CanvasController.stageInsets`): clear of the toolbar, of
    /// both panels' nominal widths, and of the filmstrip while the photo makes room for it
    /// (`EditorModel.makesRoomForFilmstrip`), with the gap the panels keep. Presenting gives the
    /// photo the whole window.
    static func stageInsets(toolbarHeight: CGFloat, presenting: Bool, filmstrip: Bool) -> StageInsets {
        guard !presenting else { return .zero }
        return StageInsets(
            leading: inset + sidebarNominal + inset,
            trailing: inspectorNominal + inset,
            top: toolbarHeight,
            bottom: inset + (filmstrip ? filmstripHeight + inset : 0),
        )
    }
}

/// The canvas layer of the editor window (see `EditorWindowController`): the photo spans the
/// whole window, under the toolbar and both panels, which float over it. The photo is
/// fitted to a fixed stage that keeps clear of the panels' nominal widths whether they are
/// showing or not, so showing, hiding or resizing a panel never moves it. The filmstrip
/// floats too, unless Hide Automatically is off: then it stays up and the photo is fitted
/// above it, and hiding it gives the photo that room back, as hiding the toolbar does. Only
/// presenting (full screen with every panel hidden) gives it the whole window.
struct EditorContentView: View {
    @Bindable var model: EditorModel
    @Bindable var theme: ThemeSettings
    let onOpen: () -> Void
    @State private var toolbarHeight: CGFloat = 0
    @State private var layoutHeight: CGFloat = 0

    var body: some View {
        CanvasArea(onOpen: onOpen)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                if model.filmstripVisible, model.library.count > 0 || model.library.isOpenFolderUnavailable,
                   model.lightsOut == 0 {
                    FloatingFilmstrip()
                        .id(theme.selection)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { toolbarHeight = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { layoutHeight = $0 }
            .sheet(item: $model.stackWorkspace) { workspace in
                StackWorkspaceView(workspace: workspace, onDone: model.finishStackWorkspace)
                    .environment(theme)
            }
            .sheet(item: $model.settingsChooser) { chooser in
                CopySettingsSheet(chooser: chooser)
                    .frame(maxHeight: NSWindow.sheetHeight(fitting: .infinity, below: layoutHeight))
                    .environment(model)
                    .environment(theme)
            }
            .onAppear(perform: updateStage)
            .onChange(of: toolbarHeight) { _, _ in updateStage() }
            .onChange(of: model.isPresenting) { _, _ in updateStage() }
            .onChange(of: model.makesRoomForFilmstrip) { _, _ in updateStage() }
            .environment(model)
            .environment(theme)
            .tint(Theme.nativeTint)
            .focusEffectDisabled()
    }

    private func updateStage() {
        model.canvas.stageInsets = PanelMetrics.stageInsets(
            toolbarHeight: toolbarHeight, presenting: model.isPresenting, filmstrip: model.makesRoomForFilmstrip,
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
/// found, so its banner is seen. With Hide Automatically off it stays up, and the photo is
/// fitted above it. Its own menu, everywhere on it but its photos, has Hide Automatically.
private struct FloatingFilmstrip: View {
    @Environment(EditorModel.self) private var model
    @Environment(ThemeSettings.self) private var theme
    @State private var revealed = false
    @State private var overEdge = false
    @State private var overStrip = false
    @State private var hiding: Task<Void, Never>?

    private var shown: Bool {
        #if DEBUG || REDLAMP_PROFILING
            if model.keepsFilmstripShown {
                return true
            }
        #endif
        return !model.filmstripHidesAutomatically || revealed || model.selection == nil
    }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(height: PanelMetrics.filmstripTrigger)
                .contentShape(Rectangle())
                .onHover { inside in
                    overEdge = inside
                    hoverChanged()
                }
            FilmstripView()
                .modifier(FloatingPane(opacity: theme.panelOpacity))
                // On the pane, so its empty parts take it too; a photo's cell has its own.
                .contextMenu {
                    Toggle("Hide Automatically", isOn: $model.filmstripHidesAutomatically)
                }
                .onHover { inside in
                    overStrip = inside
                    hoverChanged()
                }
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.bottom, PanelMetrics.inset)
                // Slid out of the window rather than removed: a new strip starts at the first photo.
                .offset(y: shown ? 0 : PanelMetrics.filmstripHeight + PanelMetrics.inset)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
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
