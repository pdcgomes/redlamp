import SwiftUI

/// The Develop workspace: presets, snapshots and history on the left, the photo in the
/// centre with the filmstrip below, and the histogram and panels on the right.
public struct EditorView: View {
    @Bindable var model: EditorModel
    let onOpen: () -> Void
    let onExport: () -> Void

    public init(model: EditorModel, onOpen: @escaping () -> Void, onExport: @escaping () -> Void) {
        self.model = model
        self.onOpen = onOpen
        self.onExport = onExport
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { model.leftPanelVisible ? .all : .detailOnly },
            set: { model.leftPanelVisible = $0 != .detailOnly },
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                CanvasArea(onOpen: onOpen)
                if model.filmstripVisible, !model.items.isEmpty {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    FilmstripView()
                }
            }
            .inspector(isPresented: $model.rightPanelVisible) {
                InspectorView()
                    .inspectorColumnWidth(min: 290, ideal: 316, max: 400)
            }
        }
        .navigationTitle(model.info?.fileName ?? "Redlamp")
        .navigationSubtitle(model.info?.cameraName ?? "")
        .toolbar {
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
                    Label("Before / After", systemImage: "square.split.2x1")
                }
                .help("Before / After (\\)")
                Toggle(isOn: $model.filmstripVisible) {
                    Label("Filmstrip", systemImage: "film.stack")
                }
                .help("Show Filmstrip")
                Toggle(isOn: $model.rightPanelVisible) {
                    Label("Panels", systemImage: "sidebar.right")
                }
                .help("Show Develop Panels")
            }
        }
        .environment(model)
        .preferredColorScheme(.dark)
    }
}
