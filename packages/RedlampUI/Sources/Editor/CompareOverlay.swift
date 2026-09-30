import RedlampCanvas
import SwiftUI

/// Before and After labels over side-by-side and split comparisons, and the split's handle.
/// Laid out in the canvas's coordinates, like the Metal view under it.
struct CompareOverlay: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            let canvas = model.canvas
            let size = geometry.size
            let after = canvas.visibleImageFrame(in: size)
            if !after.isNull, after.width > 0 {
                switch canvas.comparison {
                case .none:
                    EmptyView()
                case .sideBySide:
                    if let pane = canvas.comparisonStage(in: size) {
                        let stage = canvas.stage(in: size)
                        let before = after.offsetBy(dx: pane.minX - stage.minX, dy: pane.minY - stage.minY)
                        labels(in: before, "Before", .top)
                        labels(in: after, "After", .top)
                    }
                case .split:
                    labels(in: after, "Before", .topLeading)
                    labels(in: after, "After", .bottomTrailing)
                    if let line = canvas.splitLine(in: size) {
                        SplitHandle(start: line.start, end: line.end)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func labels(in frame: CGRect, _ text: String, _ alignment: Alignment) -> some View {
        if model.lightsOut == 0 {
            Color.clear
                .frame(width: frame.width, height: frame.height)
                .overlay(alignment: alignment) {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .padding(12)
                }
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
        }
    }
}

/// The split line, dragged along the photo's diagonal; double-click centres it.
private struct SplitHandle: View {
    let start: CGPoint
    let end: CGPoint
    @Environment(EditorModel.self) private var model

    private static let knobSize: CGFloat = 26

    var body: some View {
        let line = Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        let knob = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let knobRect = CGRect(
            x: knob.x - Self.knobSize / 2, y: knob.y - Self.knobSize / 2, width: Self.knobSize, height: Self.knobSize,
        )
        var hitArea = line.strokedPath(StrokeStyle(lineWidth: 14))
        hitArea.addEllipse(in: knobRect)

        return ZStack {
            line.stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .shadow(color: .black.opacity(0.6), radius: 1.5)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: Self.knobSize, height: Self.knobSize)
                .glassEffect(.regular, in: .circle)
                .position(knob)
        }
        .contentShape(hitArea)
        .pointerStyle(.frameResize(position: .topLeading))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in model.splitPosition = model.canvas.splitPosition(through: drag.location) },
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.splitPosition = 0.5 })
        .help("Drag to move the split; double-click to centre it")
    }
}
