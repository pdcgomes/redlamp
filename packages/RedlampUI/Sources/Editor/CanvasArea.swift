import RedlampCanvas
import RedlampEngineAPI
import SwiftUI
import UniformTypeIdentifiers

struct CanvasArea: View {
    let onOpen: () -> Void
    @Environment(EditorModel.self) private var model
    @Environment(ThemeSettings.self) private var theme
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Color(white: 0.12)

            if model.selection != nil {
                CanvasView(
                    feed: model.frames,
                    controller: model.canvas,
                    clickAction: model.activeTool == .masking ? .none : (model.eyedropperActive ? .sample : .zoom),
                    surround: model.colorAssessment
                        ? CanvasMetalView.assessmentSurround
                        : [CanvasMetalView.defaultSurround, 0.003, 0][min(model.lightsOut, 2)],
                    whiteFrame: model.colorAssessment ? CanvasMetalView.assessmentFrame : 0,
                    onSample: { model.sampleWhiteBalance(at: $0) },
                )
            }
        }
        // Everything drawn over the photo lives in overlays: they render above the Metal
        // layer, whereas ZStack siblings of the canvas would be hidden beneath it.
        // The chrome over the photo is rebuilt for a new theme; the Metal canvas is not.
        .overlay {
            statusLayer
                .padding(stagePadding)
                .id(theme.selection)
        }
        .overlay {
            // Full canvas: mask geometry uses the same coordinates as the Metal view.
            if model.activeTool == .masking, model.info != nil, !model.isShowingOriginal {
                MaskOverlayView()
            }
        }
        .overlay {
            if model.isComparing, model.hasFrame {
                CompareOverlay()
            }
        }
        .overlay(alignment: .topLeading) {
            if model.infoOverlay > 0, model.lightsOut == 0, let info = model.info {
                InfoOverlay(info: info, detailed: model.infoOverlay == 2)
                    .padding(16)
                    .padding(stagePadding)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            // The command palette says what it's previewing beside its own hint bar.
            if model.lightsOut == 0, model.commandPalette == nil,
               model.isShowingOriginal || model.previewingRecipe != nil || model.previewingEdit != nil
               || model.eyedropperActive || model.drawingKind != nil || model.isReadOnly
               || (model.info != nil && model.isBaseLookMissing) {
                StatusPill(text: statusText)
                    .padding(.top, 14)
                    .padding(stagePadding)
                    .id(theme.selection)
            }
        }
        .overlay(alignment: .bottom) {
            if model.info != nil, model.lightsOut == 0, !model.isPresenting {
                CanvasControls()
                    .padding(.bottom, 14)
                    .padding(stagePadding)
                    .id(theme.selection)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(12)
                    .padding(stagePadding)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(fileURL)
                    }
                }
                model.open(urls)
            }
            return true
        }
    }

    /// Chrome over the photo is laid out on the stage (the canvas minus the panels' space).
    private var stagePadding: EdgeInsets {
        let insets = model.canvas.stageInsets
        return EdgeInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing)
    }

    private var statusLayer: some View {
        ZStack {
            if !model.hasFrame, let selection = model.selection, let thumbnail = model.thumbnails[selection] {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
                    .opacity(0.85)
                    .allowsHitTesting(false)
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .glassEffect(.regular, in: .circle)
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
            }

            if model.items.isEmpty, model.selection == nil {
                EmptyStateView(onOpen: onOpen)
            }
        }
    }

    private var statusText: String {
        if let kind = model.drawingKind {
            return "Drag on the photo to draw a \(kind.name)  ·  Esc to cancel"
        }
        if model.eyedropperActive {
            return "Click a neutral area to set white balance  ·  Esc to cancel"
        }
        if let recipe = model.previewingRecipe {
            return "Preview: \(recipe.name)"
        }
        if model.previewingEdit != nil {
            return "Preview"
        }
        if model.isShowingOriginal {
            return "Before"
        }
        if model.isReadOnly {
            return "Edited in a newer version of Redlamp  ·  Changes won't be saved"
        }
        return "Base Look “\(model.baseLook.name)” isn't installed  ·  Showing the photo without it"
    }
}

/// Lightroom's loupe info overlay (`I`): file and camera, then capture details.
private struct InfoOverlay: View {
    let info: ImageInfo
    let detailed: Bool
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.fileName)
                .font(.system(size: 14, weight: .semibold))
            Text([
                "\(info.pixelSize.width) × \(info.pixelSize.height)",
                info.cameraName,
                info.sensorDescription,
            ].compactMap(\.self).joined(separator: "  ·  "))
            if detailed {
                Text(info.exposureSummary.joined(separator: "   "))
                if let lens = info.lens {
                    Text(lens)
                }
                if let date = info.captureDate {
                    Text(date.formatted(date: .abbreviated, time: .standard))
                }
                let metadata = model.currentMetadata
                if metadata.rating > 0 || metadata.flag != nil {
                    Text([
                        metadata.rating > 0 ? String(repeating: "★", count: metadata.rating) : nil,
                        metadata.flag.map { $0 == .pick ? "Pick" : "Rejected" },
                    ].compactMap(\.self).joined(separator: "  "))
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.white.opacity(0.92))
        .shadow(color: .black.opacity(0.8), radius: 2)
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Floating Liquid Glass controls. Glass lives only on floating chrome, never behind
/// the photo's editing surface.
private struct CanvasControls: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    zoomButton("Fit", .fit)
                    zoomButton("Fill", .fill)
                    zoomButton("1:1", .oneToOne)
                    zoomButton("2:1", .twoToOne)
                    Text("\(model.canvas.zoomPercent)%")
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.secondaryLabel)
                        .frame(width: 38)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)

                HStack(spacing: 4) {
                    HStack(spacing: 0) {
                        iconToggle(model.compareLayout.symbol, isOn: $model.showBefore, help: "Before / After (\\)")
                        Menu {
                            CompareLayoutPicker()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.label)
                                .frame(width: 12, height: 22)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Before / After Layout (Y)")
                    }
                    iconToggle("exclamationmark.triangle", isOn: $model.showClipping, help: "Show Clipping (J)")
                    iconToggle("camera.aperture", isOn: $model.showRawClipping, help: "Show Sensor Clipping (⌥J)")
                    iconToggle("square.dashed", isOn: $model.colorAssessment, help: "Color Assessment View (⇧L)")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)

                if let time = model.lastRenderTime {
                    Text(String(
                        format: "%.1f ms",
                        Double(time.components.attoseconds) / 1e15 + Double(time.components.seconds) * 1000,
                    ))
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.secondaryLabel)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .help("GPU render time of the last frame")
                }
            }
        }
    }

    private func zoomButton(_ title: String, _ zoom: CanvasController.Zoom) -> some View {
        Button(title) {
            withAnimation(.snappy) { model.canvas.zoom = zoom }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: model.canvas.zoom == zoom ? .semibold : .regular))
        .foregroundStyle(model.canvas.zoom == zoom ? Theme.labelHover : Theme.label)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(model.canvas.zoom == zoom ? Theme.selection : .clear))
    }

    private func iconToggle(_ symbol: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Theme.label)
                .background(Capsule().fill(isOn.wrappedValue ? Theme.selection : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The Before / After layouts, checked by the current one. Choosing one also shows it.
public struct CompareLayoutPicker: View {
    @Environment(EditorModel.self) private var model

    public init() {}

    public var body: some View {
        Picker("Before / After Layout", selection: Binding(
            get: { model.compareLayout },
            set: { model.showComparison(in: $0) },
        )) {
            ForEach(CompareLayout.allCases) { layout in
                Label(layout.title, systemImage: layout.symbol).tag(layout)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

private struct EmptyStateView: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.secondaryLabel)
            Text("Open a folder of photos to start editing")
                .font(.title3)
                .foregroundStyle(Theme.value)
            Text(
                "RAW from most cameras (ARW, CR3, NEF, RAF, DNG…), plus JPEG, HEIC and TIFF.\nOr drop files and folders here.",
            )
            .multilineTextAlignment(.center)
            .font(.callout)
            .foregroundStyle(Theme.secondaryLabel)
            Button("Open Folder…", action: onOpen)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut("o")
        }
        .padding(40)
    }
}
