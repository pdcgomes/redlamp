import RedlampCanvas
import RedlampDocument
import SwiftUI

/// Left column: Navigator, Presets, Snapshots and History, as in Lightroom Classic.
@_spi(Harness) public struct SidebarView: View {
    @State private var navigatorController = CanvasController()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            NavigatorView(controller: navigatorController)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            SidebarLists()
        }
    }
}

/// Presets, Snapshots and History.
@_spi(Harness) public struct SidebarLists: View {
    @Environment(EditorModel.self) private var model
    @State private var presetsExpanded: Set<String> = ["Essentials"]

    public init() {}

    public var body: some View {
        List {
            Section("Presets") {
                ForEach(BuiltInPresets.groups, id: \.name) { group in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { presetsExpanded.contains(group.name) },
                            set: { expanded in
                                if expanded {
                                    presetsExpanded.insert(group.name)
                                } else {
                                    presetsExpanded.remove(group.name)
                                }
                            },
                        ),
                    ) {
                        ForEach(group.presets) { preset in
                            PresetRow(preset: preset)
                        }
                    } label: {
                        Label(group.name, systemImage: "folder")
                    }
                }
            }

            Section {
                if model.snapshots.isEmpty {
                    Text("No snapshots")
                        .foregroundStyle(Theme.tertiaryLabel)
                }
                ForEach(model.snapshots) { snapshot in
                    Button {
                        model.applySnapshot(snapshot)
                    } label: {
                        Label(snapshot.name, systemImage: "camera.viewfinder")
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Snapshot", role: .destructive) { model.deleteSnapshot(snapshot) }
                    }
                }
            } header: {
                HStack {
                    Text("Snapshots")
                    Spacer()
                    Button {
                        model.createSnapshot()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.info == nil)
                    .help("Create Snapshot (⌘N)")
                }
            }

            Section {
                ForEach(Array(model.history.enumerated()).reversed(), id: \.element.id) { index, step in
                    HistoryRow(
                        step: step,
                        isCurrent: index == model.historyIndex,
                        isFuture: index > model.historyIndex,
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.goToHistory(index) }
                }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    Button {
                        model.clearHistory()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.history.count <= 1)
                    .help("Clear History")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .font(Theme.labelFont)
    }
}

private struct PresetRow: View {
    let preset: Preset
    @Environment(EditorModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Text(preset.name)
            .foregroundStyle(hovering ? Theme.labelHover : Theme.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                guard model.info != nil else { return }
                model.previewPreset(inside ? preset : nil)
            }
            .onTapGesture { model.applyPreset(preset) }
            .help("Hover to preview, click to apply")
    }
}

private struct HistoryRow: View {
    let step: HistoryStep
    let isCurrent: Bool
    let isFuture: Bool

    var body: some View {
        HStack {
            Text(step.name)
                .foregroundStyle(isFuture ? Theme.tertiaryLabel : (isCurrent ? Theme.labelHover : Theme.label))
                .lineLimit(1)
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }
}

/// A live, fitted view of the current render, with the zoomed viewport outlined (drag it,
/// or click, to move around the photo) and Lightroom's FIT / FILL / 1:1 / ratio zoom buttons.
@_spi(Harness) public struct NavigatorView: View {
    let controller: CanvasController
    @Environment(EditorModel.self) private var model
    /// Where the viewport was grabbed, relative to its centre, while dragging.
    @State private var grab: CGPoint?

    public init(controller: CanvasController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text("NAVIGATOR")
                    .font(Theme.sectionFont)
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondaryLabel)
                Spacer()
                zoomButton("Fit", .fit)
                zoomButton("Fill", .fill)
                zoomButton("1:1", .oneToOne)
                NavigatorRatioMenu()
            }
            GeometryReader { geometry in
                CanvasView(feed: model.frames, controller: controller, clickAction: .none, interactive: false)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // The Metal view draws over overlays attached to it directly and over
                    // ZStack siblings; an overlay on a containing view renders above it.
                    .containerized()
                    .overlay {
                        if model.canvas.isZoomedIn, model.info != nil {
                            let image = controller.imageRect(in: geometry.size)
                            let visible = model.canvas.visibleImageRect
                            Rectangle()
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                                .frame(width: visible.width * image.width, height: visible.height * image.height)
                                .position(
                                    x: image.minX + visible.midX * image.width,
                                    y: image.minY + visible.midY * image.height,
                                )
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(viewportDrag(in: geometry.size))
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
            .aspectRatio(1.5, contentMode: .fit)
        }
        .onAppear { controller.imageSize = model.canvas.imageSize }
        .onChange(of: model.canvas.imageSize) { _, size in controller.imageSize = size }
    }

    private func zoomButton(_ title: String, _ zoom: CanvasController.Zoom) -> some View {
        Button(title) {
            model.canvas.zoom = zoom
        }
        .buttonStyle(.plain)
        .font(Theme.captionFont)
        .foregroundStyle(model.canvas.zoom == zoom ? Theme.labelHover : Theme.secondaryLabel)
    }

    /// Dragging the outline moves it from where it was grabbed; clicking elsewhere centres
    /// the view on that point, as in Lightroom.
    private func viewportDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let image = controller.imageRect(in: size)
                guard model.canvas.isZoomedIn, model.info != nil, image.width > 0, image.height > 0 else { return }
                func normalized(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: (point.x - image.minX) / image.width, y: (point.y - image.minY) / image.height)
                }
                let offset = grab ?? {
                    let visible = model.canvas.visibleImageRect
                    let start = normalized(value.startLocation)
                    guard visible.contains(start) else { return .zero }
                    return CGPoint(x: start.x - visible.midX, y: start.y - visible.midY)
                }()
                grab = offset
                let point = normalized(value.location)
                model.canvas.centerOn(CGPoint(x: point.x - offset.x, y: point.y - offset.y))
            }
            .onEnded { _ in grab = nil }
    }
}

/// The Navigator's fourth zoom button: a ratio chosen from its menu, as in Lightroom.
/// Shared by the SwiftUI Navigator and its AppKit port.
struct NavigatorRatioMenu: View {
    @Environment(EditorModel.self) private var model
    @State private var ratio = 2.0

    var body: some View {
        Menu {
            ForEach(CanvasController.zoomRatios, id: \.self) { choice in
                Button(CanvasController.ratioLabel(choice)) {
                    ratio = choice
                    model.canvas.zoom = .scale(choice)
                }
            }
        } label: {
            Text(CanvasController.ratioLabel(ratio))
        } primaryAction: {
            model.canvas.zoom = .scale(ratio)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .font(Theme.captionFont)
        .foregroundStyle(model.canvas.zoom == .scale(ratio) ? Theme.labelHover : Theme.secondaryLabel)
        .help("Zoom ratio")
    }
}
