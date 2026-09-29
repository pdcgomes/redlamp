import RedlampCanvas
import SwiftUI
import UniformTypeIdentifiers

struct CanvasArea: View {
    let onOpen: () -> Void
    @Environment(EditorModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Color(white: 0.12)

            if model.selection != nil {
                CanvasView(
                    frame: model.frame,
                    controller: model.canvas,
                    clickAction: model.eyedropperActive ? .sample : .zoom,
                    onSample: { model.sampleWhiteBalance(at: $0) },
                )
            }

            if model.frame == nil, let selection = model.selection, let thumbnail = model.thumbnails[selection] {
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
        .overlay(alignment: .top) {
            if model.showBefore || model.previewingPreset != nil || model.eyedropperActive {
                StatusPill(text: statusText)
                    .padding(.top, 14)
            }
        }
        .overlay(alignment: .bottom) {
            if model.info != nil {
                CanvasControls()
                    .padding(.bottom, 14)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(12)
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

    private var statusText: String {
        if model.eyedropperActive {
            return "Click a neutral area to set white balance  ·  Esc to cancel"
        }
        if let preset = model.previewingPreset {
            return "Preview: \(preset.name)"
        }
        return "Before"
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
                    iconToggle("square.split.2x1", isOn: $model.showBefore, help: "Before / After (\\)")
                    iconToggle("exclamationmark.triangle", isOn: $model.showClipping, help: "Show Clipping (J)")
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
