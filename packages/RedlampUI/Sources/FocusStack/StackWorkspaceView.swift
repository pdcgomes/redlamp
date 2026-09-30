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
                        isReference: frame == workspace.referenceFrame,
                    )
                    .onTapGesture { workspace.toggle(frame) }
                    .task { await workspace.loadThumbnail(for: frame) }
                }
            }
            .padding(10)
        }
        .frame(height: 96)
        .disabled(workspace.isMerging)
    }

    private func summary(_ report: FocusStackReport) -> String {
        let seconds = report.timings["total"].map { String(format: " · merged in %.0f s", $0) } ?? ""
        return "\(report.width) × \(report.height)"
            + String(format: " · focus breathing %.1f%%", report.maximumScaleChange * 100)
            + String(format: " · depth confident over %.0f%%", report.confidentDepthFraction * 100)
            + seconds
    }
}

private struct StackFrameCell: View {
    let frame: URL
    let thumbnail: CGImage?
    let isIncluded: Bool
    let isReference: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.14))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
            if !isIncluded {
                Image(systemName: "eye.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
        .frame(width: 96, height: 70)
        .opacity(isIncluded ? 1 : 0.4)
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
        .help("\(frame.lastPathComponent) — click to \(isIncluded ? "leave out" : "include")")
    }
}
