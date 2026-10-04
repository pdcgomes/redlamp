import RedlampEngineAPI
import SwiftUI

/// The Stack workspace: a focus stack's frames, how they are merged, and the result with its
/// depth map. Separate from Develop; Done opens the merged photo there.
struct StackWorkspaceView: View {
    @Bindable var workspace: StackWorkspaceModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if workspace.isRetouching {
                brushBar
                Divider()
            }
            result
            Divider()
            frameStrip
        }
        .frame(minWidth: 960, minHeight: 680)
        .background(Color(white: 0.09))
        .task {
            if workspace.preview == nil {
                await workspace.merge()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(
                workspace.documentURL.deletingPathExtension().lastPathComponent,
                systemImage: "square.stack.3d.down.right",
            )
            .font(.headline)
            Text("\(workspace.included.count) of \(workspace.frames.count) frames")
                .foregroundStyle(Theme.tertiaryLabel)
            Spacer()
            Picker("Method", selection: $workspace.strategy) {
                Text("Auto").tag(FocusStackStrategy.auto)
                Text("Smooth").tag(FocusStackStrategy.smooth)
                Text("Detail").tag(FocusStackStrategy.detail)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .help(
                "Auto: detail from the sharpest frames near the depth map · Smooth: clean surfaces · Detail: hair and bristles, more halos",
            )
            Toggle(isOn: $workspace.isRetouching) {
                Label("Retouch", systemImage: "paintbrush.pointed")
            }
            .toggleStyle(.button)
            .disabled(workspace.preview == nil)
            .help("Paint a frame, or another method's result, over the merge")
            Toggle("Depth", isOn: $workspace.showsDepth)
                .toggleStyle(.button)
                .disabled(workspace.preview == nil)
                .help("Show which frame is sharpest where (dark: first frame, light: last)")
            Button("Merge") { Task { await workspace.merge() } }
                .disabled(workspace.isMerging || !workspace.hasChanges)
                .keyboardShortcut(.return, modifiers: .command)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .disabled(workspace.isMerging || workspace.preview == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var result: some View {
        ZStack {
            if let preview = workspace.preview {
                Image(decorative: workspace.showsDepth ? preview.depth : preview.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .overlay {
                        if workspace.isRetouching, !workspace.isMerging {
                            RetouchCanvas(workspace: workspace)
                        }
                    }
                    .padding(16)
                    .opacity(workspace.isMerging ? 0.4 : 1)
            }
            if let progress = workspace.progress {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 280)
                    Text(progress < 0.5 ? "Aligning frames…" : progress < 0.95 ? "Merging…" : "Developing…")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.secondaryLabel)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.6)))
            } else if let message = workspace.errorMessage {
                Text(message)
                    .foregroundStyle(Theme.secondaryLabel)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                if let report = workspace.preview?.report {
                    Text(summary(report))
                }
                Spacer()
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.tertiaryLabel)
            .padding(.horizontal, 16)
            .frame(height: 22)
        }
    }

    private var frameStrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 6) {
                ForEach(workspace.frames, id: \.self) { frame in
                    StackFrameCell(
                        frame: frame,
                        thumbnail: workspace.thumbnails[frame],
                        isIncluded: !workspace.excluded.contains(frame),
                        isUnreadable: workspace.unreadable.contains(frame),
                        isReference: frame == workspace.referenceFrame,
                        isSource: workspace.isRetouching && workspace.brushSource == .frame(frame),
                    )
                    .onTapGesture {
                        if workspace.isRetouching {
                            if !workspace.unreadable.contains(frame) {
                                workspace.brushSource = .frame(frame)
                            }
                        } else {
                            workspace.toggle(frame)
                        }
                    }
                    .task { await workspace.loadThumbnail(for: frame) }
                }
            }
            .padding(10)
        }
        .frame(height: 96)
        .disabled(workspace.isMerging)
    }

    private var brushBar: some View {
        HStack(spacing: 12) {
            Text("Paint from")
                .foregroundStyle(Theme.tertiaryLabel)
                .fixedSize()
            Picker("Source", selection: $workspace.brushSource) {
                Text("Frame under cursor").tag(StackWorkspaceModel.BrushSource.underCursor)
                Divider()
                ForEach(FocusStackStrategy.allCases.filter { $0 != workspace.strategy }, id: \.self) { method in
                    Text("\(method.rawValue.capitalized) merge").tag(StackWorkspaceModel.BrushSource.strategy(method))
                }
                if case let .frame(frame) = workspace.brushSource {
                    Divider()
                    Text(frame.lastPathComponent).tag(workspace.brushSource)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .help("Or click a frame below to paint from it")
            Text("Size")
                .foregroundStyle(Theme.tertiaryLabel)
                .fixedSize()
            Slider(value: $workspace.brushRadius, in: 0.005 ... 0.1)
                .frame(width: 110)
            Text("Hardness")
                .foregroundStyle(Theme.tertiaryLabel)
                .fixedSize()
            Slider(value: $workspace.brushHardness, in: 0 ... 1)
                .frame(width: 80)
            Text("Opacity")
                .foregroundStyle(Theme.tertiaryLabel)
                .fixedSize()
            Slider(value: $workspace.brushOpacity, in: 0.1 ... 1)
                .frame(width: 80)
            Spacer()
            Text(workspace.strokes.count == 1 ? "1 stroke" : "\(workspace.strokes.count) strokes")
                .foregroundStyle(Theme.tertiaryLabel)
                .fixedSize()
            Button("Undo") { Task { await workspace.undoStroke() } }
                .keyboardShortcut("z")
                .disabled(workspace.strokes.isEmpty || workspace.isMerging)
            Button("Clear") { Task { await workspace.clearStrokes() } }
                .disabled(workspace.strokes.isEmpty || workspace.isMerging)
        }
        .font(Theme.captionFont)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func summary(_ report: FocusStackReport) -> String {
        let seconds = report.timings["total"].map { String(format: " · merged in %.0f s", $0) } ?? ""
        let failed = report.failedFrames.map { frames in
            frames.count == 1 ? " · 1 frame couldn't be read, left out" : " · \(frames.count) frames couldn't be read, left out"
        } ?? ""
        return "\(report.width) × \(report.height)" + failed
            + String(format: " · focus breathing %.1f%%", report.maximumScaleChange * 100)
            + String(format: " · depth confident over %.0f%%", report.confidentDepthFraction * 100)
            + seconds
    }
}

private struct StackFrameCell: View {
    let frame: URL
    let thumbnail: CGImage?
    let isIncluded: Bool
    let isUnreadable: Bool
    let isReference: Bool
    let isSource: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.14))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
            if !isIncluded || isUnreadable {
                Image(systemName: isIncluded ? "exclamationmark.triangle" : "eye.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
        .frame(width: 96, height: 70)
        .opacity(isIncluded && !isUnreadable ? 1 : 0.4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSource ? Color.accentColor : .clear, lineWidth: 2),
        )
        .overlay(alignment: .topLeading) {
            if isReference {
                Text("R")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .foregroundStyle(Color.white)
                    .padding(4)
                    .help("Reference frame: the narrowest view, which sets the framing")
            }
        }
        .help(
            isUnreadable && isIncluded
                ? "\(frame.lastPathComponent) couldn't be read, so the merge left it out — click to leave it out of the stack"
                : "\(frame.lastPathComponent) — click to \(isIncluded ? "leave out" : "include")",
        )
    }
}

/// Brush strokes painted over the preview, in the image's own (fitted) frame.
private struct RetouchCanvas: View {
    let workspace: StackWorkspaceModel
    @State private var points: [CGPoint] = []
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = 2 * workspace.brushRadius * max(size.width, size.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addLines(points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                    if points.count == 1, let point = points.first {
                        path.addLine(to: CGPoint(x: point.x * size.width + 0.1, y: point.y * size.height))
                    }
                }
                .stroke(
                    Color.accentColor.opacity(0.4),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round),
                )
                BrushRingLayer(
                    pointer: hover.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) },
                    fallback: CGPoint(x: size.width / 2, y: size.height / 2),
                    watched: [workspace.brushRadius, workspace.brushHardness],
                    label: "Hardness \(Int((workspace.brushHardness * 100).rounded()))%",
                    radius: width / 2,
                ) {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                        .frame(width: width, height: width)
                }
                if let hover {
                    if workspace.brushSource == .underCursor, let frame = workspace.frame(at: hover) {
                        Text(frame.deletingPathExtension().lastPathComponent)
                            .font(Theme.captionFont)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .foregroundStyle(Color.white)
                            .position(x: hover.x * size.width, y: hover.y * size.height - width / 2 - 12)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .background(CommandScrollArea { notches, hardness in
                workspace.scrollBrush(by: notches, hardness: hardness)
                return true
            })
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case let .active(location) = phase {
                    hover = CGPoint(x: location.x / size.width, y: location.y / size.height)
                } else {
                    hover = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let point = CGPoint(
                            x: min(max(drag.location.x / size.width, 0), 1),
                            y: min(max(drag.location.y / size.height, 0), 1),
                        )
                        hover = point
                        if let last = points.last,
                           hypot(point.x - last.x, point.y - last.y) < workspace.brushRadius / 4 {
                            return
                        }
                        points.append(point)
                    }
                    .onEnded { _ in
                        let stroke = points
                        points = []
                        Task { await workspace.addStroke(stroke) }
                    },
            )
        }
    }
}
