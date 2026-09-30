import AppKit
import RedlampCanvas
import SwiftUI

/// Panel widths. The canvas reserves the *nominal* width for each visible panel, never
/// the live width, so resizing a panel (or its content changing size) cannot move the photo.
enum PanelMetrics {
    static let sidebarNominal: CGFloat = 250
    static let sidebarRange: ClosedRange<CGFloat> = 220 ... 380
    static let inspectorNominal: CGFloat = 316
    static let inspectorRange: ClosedRange<CGFloat> = 290 ... 440
}

/// The Develop workspace. The photo's canvas spans the whole area between the toolbar and
/// the filmstrip; the Navigator/Presets/History sidebar and the Develop panels float over
/// it, as in Lightroom and macOS 26's own full-bleed layouts.
public struct EditorView: View {
    @Bindable var model: EditorModel
    @Bindable var theme: ThemeSettings
    let onOpen: () -> Void
    let onExport: () -> Void
    @State private var themeShown = false

    public init(
        model: EditorModel, theme: ThemeSettings,
        onOpen: @escaping () -> Void, onExport: @escaping () -> Void,
    ) {
        self.model = model
        self.theme = theme
        self.onOpen = onOpen
        self.onExport = onExport
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CanvasArea(onOpen: onOpen)

                HStack(spacing: 0) {
                    if model.leftPanelVisible {
                        Group {
                            if DevelopPanels.usesSwiftUI {
                                SidebarView()
                            } else {
                                SidebarColumnHost(model: model)
                            }
                        }
                        // AppKit views take their colors when they are made, so a theme change rebuilds them.
                        .id(theme.selection)
                        .frame(width: model.sidebarWidth)
                        .background(PanelBackground(edge: .trailing))
                        .overlay(alignment: .trailing) {
                            PanelResizeHandle(
                                width: $model.sidebarWidth,
                                range: PanelMetrics.sidebarRange,
                                direction: 1,
                            )
                        }
                        .transition(.move(edge: .leading))
                    }
                    Spacer(minLength: 0)
                    if model.rightPanelVisible {
                        Group {
                            if DevelopPanels.usesSwiftUI {
                                InspectorView()
                            } else {
                                InspectorColumnHost(model: model)
                            }
                        }
                        .id(theme.selection)
                        .frame(width: model.inspectorWidth)
                        .background(PanelBackground(edge: .leading))
                        .overlay(alignment: .leading) {
                            PanelResizeHandle(
                                width: $model.inspectorWidth,
                                range: PanelMetrics.inspectorRange,
                                direction: -1,
                            )
                        }
                        .transition(.move(edge: .trailing))
                    }
                }
                .overlay { LightsOutShade(level: model.lightsOut, stage: model.canvas.stageInsets) }
            }
            if model.filmstripVisible, !model.items.isEmpty {
                Rectangle().fill(Theme.divider).frame(height: 1)
                FilmstripView()
                    .id(theme.selection)
                    .overlay { LightsOutShade(level: model.lightsOut, stage: nil) }
            }
        }
        .overlay {
            if model.showShortcuts {
                ShortcutsSheet()
            }
        }
        .overlay {
            if model.showAdjustmentSearch {
                AdjustmentSearchView()
            }
        }
        .sheet(item: $model.stackWorkspace) { workspace in
            StackWorkspaceView(workspace: workspace, onDone: model.finishStackWorkspace)
                .environment(theme)
        }
        .animation(.easeOut(duration: 0.15), value: model.showShortcuts)
        .animation(.easeOut(duration: 0.12), value: model.showAdjustmentSearch)
        .animation(.easeInOut(duration: 0.3), value: model.lightsOut)
        .onAppear(perform: updateStage)
        .onChange(of: model.leftPanelVisible) { _, _ in updateStage() }
        .onChange(of: model.rightPanelVisible) { _, _ in updateStage() }
        .navigationTitle(model.info?.fileName ?? "Redlamp")
        .navigationSubtitle(model.info?.cameraName ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Toggle(isOn: $model.leftPanelVisible.animation(.snappy(duration: 0.25))) {
                    Label("Sidebar", systemImage: "sidebar.left")
                }
                .help("Show Navigator, Presets and History")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Folder", systemImage: "folder", action: onOpen)
                    .help("Open Folder (⌘O)")
                Button("Export", systemImage: "square.and.arrow.up", action: onExport)
                    .disabled(model.info == nil)
                    .help("Export (⇧⌘E)")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $model.showBefore) {
                    Label("Before / After", systemImage: model.compareLayout.symbol)
                }
                .help("Before / After (\\)")
                Toggle(isOn: $model.filmstripVisible) {
                    Label("Filmstrip", systemImage: "film.stack")
                }
                .help("Show Filmstrip")
                Toggle(isOn: $model.rightPanelVisible.animation(.snappy(duration: 0.25))) {
                    Label("Panels", systemImage: "sidebar.right")
                }
                .help("Show Develop Panels")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Theme", systemImage: "paintpalette") { themeShown.toggle() }
                    .help("Theme")
                    .popover(isPresented: $themeShown, arrowEdge: .bottom) {
                        ThemeControls(theme: $theme.selection)
                            .padding(14)
                            .frame(width: 260)
                    }
            }
        }
        .environment(model)
        .environment(theme)
        .tint(Theme.nativeTint)
        .preferredColorScheme(theme.selection.appearance == .dark ? .dark : .light)
    }

    /// Showing or hiding a panel re-fits the photo to the space left; resizing never does.
    private func updateStage() {
        model.canvas.stageInsets = StageInsets(
            leading: model.leftPanelVisible ? PanelMetrics.sidebarNominal : 0,
            trailing: model.rightPanelVisible ? PanelMetrics.inspectorNominal : 0,
        )
    }
}

/// Lightroom's Lights Out: dims (level 1) or blacks out (level 2) everything but the photo.
/// Over the panel layer the stage is left clear; the canvas darkens its own surround.
private struct LightsOutShade: View {
    let level: Int
    let stage: StageInsets?

    var body: some View {
        if level > 0 {
            let color = Color.black.opacity(level == 1 ? 0.8 : 1)
            GeometryReader { geometry in
                if let stage {
                    HStack(spacing: 0) {
                        color.frame(width: stage.leading)
                        Spacer(minLength: 0)
                        color.frame(width: stage.trailing)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    color
                }
            }
            .allowsHitTesting(level == 2)
        }
    }
}

/// The neutral backing of a floating panel, with a hairline on its inner edge.
private struct PanelBackground: View {
    let edge: HorizontalEdge

    var body: some View {
        Theme.panelBackground
            .overlay(alignment: edge == .leading ? .leading : .trailing) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 8)
    }
}

/// A drag strip on a panel's inner edge. `direction` is +1 when dragging right widens the
/// panel (the sidebar) and -1 when dragging left does (the inspector).
private struct PanelResizeHandle: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let direction: CGFloat

    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { gesture in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(
                            max(start + gesture.translation.width * direction, range.lowerBound),
                            range.upperBound,
                        )
                    }
                    .onEnded { _ in startWidth = nil },
            )
            .onTapGesture(count: 2) {
                width = direction > 0 ? PanelMetrics.sidebarNominal : PanelMetrics.inspectorNominal
            }
            .help("Drag to resize, double-click to reset")
    }
}
