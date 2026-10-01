import RedlampEngineAPI
import SwiftUI

/// The crop frame, drawn over the whole straightened frame while the Crop tool is active:
/// the outside dimmed, a rule-of-thirds grid, and handles on the corners and edges. Dragging a
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

                Path { path in
                    for third in [1.0 / 3, 2.0 / 3] {
                        path.move(to: CGPoint(x: rect.minX + rect.width * third, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.minX + rect.width * third, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * third))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * third))
                    }
                }
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
