import RedlampEngineAPI
import SwiftUI

/// The crop frame, drawn over the whole straightened frame while the Crop tool is active:
/// the outside dimmed, a composition guide (`O` cycles it), and handles on the corners and edges. Dragging a
/// handle resizes (keeping the aspect when it is locked), dragging inside moves the crop.
struct CropOverlayView: View {
    @Environment(EditorModel.self) private var model
    @State private var dragStart: CropRect?

    /// Which edges a handle moves: x −1 left, 1 right; y −1 top, 1 bottom; both 0 moves.
    private struct Handle: Hashable {
        var x: Int
        var y: Int
    }

    private static let handles = [
        Handle(x: -1, y: -1), Handle(x: 0, y: -1), Handle(x: 1, y: -1), Handle(x: -1, y: 0),
        Handle(x: 1, y: 0), Handle(x: -1, y: 1), Handle(x: 0, y: 1), Handle(x: 1, y: 1),
    ]

    var body: some View {
        GeometryReader { geometry in
            let frame = model.canvas.imageRect(in: geometry.size)
            let crop = model.recipe.crop
            let rect = CGRect(
                x: frame.minX + crop.left * frame.width, y: frame.minY + crop.top * frame.height,
                width: crop.width * frame.width, height: crop.height * frame.height,
            )
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Self.overlay(model.cropOverlay, turns: model.cropOverlayTurns, in: rect)
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    .allowsHitTesting(false)

                Rectangle()
                    .path(in: rect)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .contentShape(Rectangle().path(in: rect))
                    .gesture(dragGesture(Handle(x: 0, y: 0), frame: frame))

                ForEach(Self.handles, id: \.self) { handle in
                    Rectangle()
                        .fill(Color.white)
                        .frame(
                            width: handle.x == 0 || handle.y == 0 ? 14 : 10,
                            height: handle.x == 0 || handle.y == 0 ? 4 : 10,
                        )
                        .rotationEffect(handle.x != 0 && handle.y == 0 ? .degrees(90) : .zero)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .contentShape(Rectangle().inset(by: -8))
                        .position(
                            x: handle.x < 0 ? rect.minX : (handle.x > 0 ? rect.maxX : rect.midX),
                            y: handle.y < 0 ? rect.minY : (handle.y > 0 ? rect.maxY : rect.midY),
                        )
                        .gesture(dragGesture(handle, frame: frame))
                }
            }
        }
    }

    /// The guide, turned `turns` times where it isn't symmetric.
    private nonisolated static func overlay(_ kind: CropOverlay, turns: Int, in rect: CGRect) -> Path {
        @Sendable func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        return Path { path in
            func line(_ a: CGPoint, _ b: CGPoint) {
                path.move(to: a)
                path.addLine(to: b)
            }
            func grid(_ stops: [Double]) {
                for stop in stops {
                    line(point(stop, 0), point(stop, 1))
                    line(point(0, stop), point(1, stop))
                }
            }
            switch kind {
            case .thirds:
                grid([1.0 / 3, 2.0 / 3])
            case .grid:
                grid((1 ..< 8).map { Double($0) / 8 })
            case .goldenRatio:
                grid([0.382, 0.618])
            case .diagonal:
                // From each corner at 45° on screen, until it meets an edge.
                let side = min(rect.width, rect.height)
                let dx = side / rect.width, dy = side / rect.height
                line(point(0, 0), point(dx, dy))
                line(point(1, 0), point(1 - dx, dy))
                line(point(0, 1), point(dx, 1 - dy))
                line(point(1, 1), point(1 - dx, 1 - dy))
            case .goldenTriangle:
                // A diagonal, and from the other corners the perpendiculars onto it.
                let flipped = turns % 2 == 1
                let a = point(0, flipped ? 1 : 0), b = point(1, flipped ? 0 : 1)
                line(a, b)
                for corner in flipped ? [point(0, 0), point(1, 1)] : [point(1, 0), point(0, 1)] {
                    let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
                    let t = ((corner.x - a.x) * ab.x + (corner.y - a.y) * ab.y) / (ab.x * ab.x + ab.y * ab.y)
                    line(corner, CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t))
                }
            }
        }
    }

    private func dragGesture(_ handle: Handle, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if dragStart == nil {
                    dragStart = model.recipe.crop
                    model.beginEdit()
                }
                guard let start = dragStart, frame.width > 0, frame.height > 0 else { return }
                let dx = gesture.translation.width / frame.width
                let dy = gesture.translation.height / frame.height
                model.setCrop(resized(start, handle: handle, dx: dx, dy: dy))
            }
            .onEnded { _ in
                dragStart = nil
                model.endEdit(name: "Crop")
            }
    }

    /// `start` with the dragged handle's edges moved, kept inside the frame and (when the
    /// aspect is locked) at its aspect, pivoting on the opposite edge.
    private func resized(_ start: CropRect, handle: Handle, dx: Double, dy: Double) -> CropRect {
        if handle.x == 0, handle.y == 0 {
            var moved = start
            moved.left += dx
            moved.right += dx
            moved.top += dy
            moved.bottom += dy
            return EditorModel.shifted(moved, inside: .full)
        }
        let minimum = 0.02
        var crop = start
        if handle.x < 0 {
            crop.left = min(max(start.left + dx, 0), start.right - minimum)
        }
        if handle.x > 0 {
            crop.right = max(min(start.right + dx, 1), start.left + minimum)
        }
        if handle.y < 0 {
            crop.top = min(max(start.top + dy, 0), start.bottom - minimum)
        }
        if handle.y > 0 {
            crop.bottom = max(min(start.bottom + dy, 1), start.top + minimum)
        }
        guard model.cropAspectLocked else { return crop }
        // Keep the starting aspect: the dragged dimension leads, the other follows.
        let aspect = model.pixelAspect(of: start)
        let frame = model.cropFrameSize
        let toNormalized = Double(frame.width) / max(Double(frame.height), 1)
        if handle.y == 0 || (handle.x != 0 && abs(dx) >= abs(dy)) {
            let height = min(crop.width * toNormalized / aspect, 1)
            let width = height * aspect / toNormalized
            if handle.x < 0 {
                crop.left = crop.right - width
            } else {
                crop.right = crop.left + width
            }
            if handle.y < 0 {
                crop.top = crop.bottom - height
            } else if handle.y > 0 {
                crop.bottom = crop.top + height
            } else {
                let middle = (start.top + start.bottom) / 2
                crop.top = middle - height / 2
                crop.bottom = middle + height / 2
            }
        } else {
            let width = min(crop.height * aspect / toNormalized, 1)
            let height = width * toNormalized / aspect
            if handle.y < 0 {
                crop.top = crop.bottom - height
            } else {
                crop.bottom = crop.top + height
            }
            if handle.x < 0 {
                crop.left = crop.right - width
            } else if handle.x > 0 {
                crop.right = crop.left + width
            } else {
                let middle = (start.left + start.right) / 2
                crop.left = middle - width / 2
                crop.right = middle + width / 2
            }
        }
        return EditorModel.shifted(crop, inside: .full)
    }
}
