import AppKit
import RedlampEngineAPI
import SwiftUI

/// Mask drawing and handles, layered over the canvas while the Masking tool is active.
struct MaskOverlayView: View {
    @Environment(EditorModel.self) private var model
    @State private var drawingKind: MaskKind?
    @State private var drawStart: ImagePoint?

    var body: some View {
        GeometryReader { geometry in
            let frame = ImageFrame(rect: model.canvas.imageRect(in: geometry.size))
            ZStack {
                if model.drawingKind != nil || drawingKind != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(drawGesture(frame))
                        .onHover { inside in
                            if inside {
                                NSCursor.crosshair.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                }

                ForEach(model.masks) { mask in
                    if model.showMaskPins, mask.id != model.selectedMaskID,
                       let center = mask.components.first?.shape.center {
                        Pin(selected: false)
                            .position(frame.view(center))
                            .onTapGesture { model.selectMask(mask.id) }
                            .help(mask.name)
                    }
                }

                // Shown while a shape is being drawn too, so its guides follow the drag.
                if model.showMaskPins, let mask = model.selectedMask {
                    ForEach(mask.components) { component in
                        ComponentHandles(
                            mask: mask,
                            component: component,
                            frame: frame,
                            isSelected: component.id == model.selectedComponent?.id,
                        )
                    }
                }
            }
        }
    }

    private func drawGesture(_ frame: ImageFrame) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let current = frame.image(gesture.location)
                if drawStart == nil {
                    guard let kind = model.drawingKind else { return }
                    drawingKind = kind
                    drawStart = frame.image(gesture.startLocation)
                    model.beginDrawing(shape(kind, from: drawStart!, to: current, frame: frame))
                    return
                }
                guard let kind = drawingKind, let start = drawStart,
                      let maskID = model.selectedMaskID, let componentID = model.selectedComponentID
                else { return }
                model.updateComponent(
                    componentID,
                    in: maskID,
                    shape: shape(kind, from: start, to: current, frame: frame),
                )
            }
            .onEnded { gesture in
                defer {
                    drawStart = nil
                    drawingKind = nil
                    model.finishDrawing()
                }
                // A click without a drag places a default-sized shape.
                guard let kind = drawingKind, let start = drawStart,
                      hypot(gesture.translation.width, gesture.translation.height) < 4,
                      let maskID = model.selectedMaskID, let componentID = model.selectedComponentID
                else { return }
                let shape: MaskShape = kind == .radial
                    ? .radial(RadialMask(center: start, radiusX: 0.22, radiusY: 0.16))
                    : .linear(LinearMask(start: start, end: ImagePoint(x: start.x, y: min(start.y + 0.25, 1))))
                model.updateComponent(componentID, in: maskID, shape: shape)
            }
    }

    private func shape(_ kind: MaskKind, from start: ImagePoint, to end: ImagePoint, frame: ImageFrame) -> MaskShape {
        switch kind {
        case .radial:
            let dx = abs(end.x - start.x) * frame.rect.width / frame.rect.height
            let dy = abs(end.y - start.y)
            let circular = NSEvent.modifierFlags.contains(.shift)
            let rx = max(circular ? max(dx, dy) : dx, 0.01)
            let ry = max(circular ? max(dx, dy) : dy, 0.01)
            return .radial(RadialMask(center: start, radiusX: rx, radiusY: ry))
        default:
            return .linear(LinearMask(start: start, end: end))
        }
    }
}

/// Converts between normalised image coordinates and view points.
struct ImageFrame {
    let rect: CGRect

    func view(_ point: ImagePoint) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    func image(_ point: CGPoint) -> ImagePoint {
        ImagePoint(
            x: (point.x - rect.minX) / max(rect.width, 1),
            y: (point.y - rect.minY) / max(rect.height, 1),
        )
    }

    /// View points per unit of image height (radial radii are in image heights).
    var heightScale: CGFloat {
        rect.height
    }
}

private struct Pin: View {
    let selected: Bool

    var body: some View {
        Circle()
            .fill(selected ? Color.accentColor : Color.white.opacity(0.85))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: selected ? 14 : 11, height: selected ? 14 : 11)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .contentShape(Circle().inset(by: -6))
    }
}

private struct Handle: View {
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.5), radius: 1.5)
            .contentShape(Circle().inset(by: -6))
    }
}

/// Guides and draggable handles for one component.
private struct ComponentHandles: View {
    let mask: MaskLayer
    let component: MaskComponent
    let frame: ImageFrame
    let isSelected: Bool

    @Environment(EditorModel.self) private var model
    @State private var original: MaskShape?

    var body: some View {
        switch component.shape {
        case let .linear(gradient):
            linear(gradient)
        case let .radial(gradient):
            radial(gradient)
        }
    }

    // MARK: Linear

    @ViewBuilder
    private func linear(_ gradient: LinearMask) -> some View {
        let start = frame.view(gradient.start)
        let end = frame.view(gradient.end)
        let center = frame.view(gradient.center)
        let direction = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let length = max(hypot(direction.x, direction.y), 1)
        let normal = CGPoint(x: -direction.y / length, y: direction.x / length)
        let reach = hypot(frame.rect.width, frame.rect.height)

        Path { path in
            for point in [start, end] {
                path.move(to: CGPoint(x: point.x - normal.x * reach, y: point.y - normal.y * reach))
                path.addLine(to: CGPoint(x: point.x + normal.x * reach, y: point.y + normal.y * reach))
            }
        }
        .stroke(Color.white.opacity(isSelected ? 0.9 : 0.5), lineWidth: 1)
        .shadow(color: .black.opacity(0.6), radius: 1)
        .clipShape(Rectangle().path(in: frame.rect))
        .allowsHitTesting(false)

        Path { path in
            path.move(to: CGPoint(x: center.x - normal.x * reach, y: center.y - normal.y * reach))
            path.addLine(to: CGPoint(x: center.x + normal.x * reach, y: center.y + normal.y * reach))
        }
        .stroke(Color.white.opacity(isSelected ? 0.7 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        .clipShape(Rectangle().path(in: frame.rect))
        .allowsHitTesting(false)

        if isSelected {
            Handle().position(start).gesture(drag { shape, delta in
                guard case var .linear(value) = shape else { return shape }
                value.start = offset(value.start, by: delta)
                return .linear(value)
            })
            Handle().position(end).gesture(drag { shape, delta in
                guard case var .linear(value) = shape else { return shape }
                value.end = offset(value.end, by: delta)
                return .linear(value)
            })
        }
        Pin(selected: isSelected)
            .position(center)
            .onTapGesture { model.selectedComponentID = component.id }
            .gesture(drag { shape, delta in
                guard case var .linear(value) = shape else { return shape }
                value.start = offset(value.start, by: delta)
                value.end = offset(value.end, by: delta)
                return .linear(value)
            })
    }

    // MARK: Radial

    @ViewBuilder
    private func radial(_ gradient: RadialMask) -> some View {
        let center = frame.view(gradient.center)
        let rx = gradient.radiusX * frame.heightScale
        let ry = gradient.radiusY * frame.heightScale
        let angle = Angle.degrees(gradient.rotation)
        let inner = 1 - gradient.feather / 100

        Ellipse()
            .stroke(Color.white.opacity(isSelected ? 0.9 : 0.5), lineWidth: 1)
            .frame(width: rx * 2, height: ry * 2)
            .rotationEffect(angle)
            .position(center)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .allowsHitTesting(false)
        Ellipse()
            .stroke(Color.white.opacity(isSelected ? 0.5 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .frame(width: max(rx * 2 * inner, 1), height: max(ry * 2 * inner, 1))
            .rotationEffect(angle)
            .position(center)
            .allowsHitTesting(false)

        if isSelected {
            let radians = gradient.rotation * .pi / 180
            let axisX = CGPoint(x: cos(radians), y: sin(radians))
            let axisY = CGPoint(x: -sin(radians), y: cos(radians))
            Handle().position(CGPoint(x: center.x + axisX.x * rx, y: center.y + axisX.y * rx))
                .gesture(radiusDrag(axis: axisX, center: center) { value, radius in value.radiusX = radius })
            Handle().position(CGPoint(x: center.x + axisY.x * ry, y: center.y + axisY.y * ry))
                .gesture(radiusDrag(axis: axisY, center: center) { value, radius in value.radiusY = radius })
            Handle(size: 7)
                .position(CGPoint(x: center.x - axisY.x * (ry + 18), y: center.y - axisY.y * (ry + 18)))
                .gesture(rotationDrag(center: center))
                .help("Drag to rotate")
        }
        Pin(selected: isSelected)
            .position(center)
            .onTapGesture { model.selectedComponentID = component.id }
            .gesture(drag { shape, delta in
                guard case var .radial(value) = shape else { return shape }
                value.center = offset(value.center, by: delta)
                return .radial(value)
            })
    }

    // MARK: Gestures

    private func offset(_ point: ImagePoint, by delta: CGSize) -> ImagePoint {
        ImagePoint(x: point.x + delta.width / frame.rect.width, y: point.y + delta.height / frame.rect.height)
    }

    /// A drag that transforms the shape captured at the start of the gesture.
    private func drag(_ transform: @escaping (MaskShape, CGSize) -> MaskShape) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if original == nil {
                    original = component.shape
                    model.selectedComponentID = component.id
                    model.beginEdit()
                }
                guard let original else { return }
                model.updateComponent(component.id, in: mask.id, shape: transform(original, gesture.translation))
            }
            .onEnded { _ in
                original = nil
                model.endEdit(name: "Edit \(mask.name)")
            }
    }

    private func radiusDrag(
        axis: CGPoint,
        center: CGPoint,
        apply: @escaping (inout RadialMask, Double) -> Void,
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if original == nil {
                    original = component.shape
                    model.beginEdit()
                }
                guard case var .radial(value) = component.shape else { return }
                let projected = abs((gesture.location.x - center.x) * axis.x + (gesture.location.y - center.y) * axis.y)
                apply(&value, max(projected / frame.heightScale, 0.01))
                model.updateComponent(component.id, in: mask.id, shape: .radial(value))
            }
            .onEnded { _ in
                original = nil
                model.endEdit(name: "Edit \(mask.name)")
            }
    }

    private func rotationDrag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if original == nil {
                    original = component.shape
                    model.beginEdit()
                }
                guard case var .radial(value) = component.shape else { return }
                let degrees = atan2(gesture.location.y - center.y, gesture.location.x - center.x) * 180 / .pi + 90
                value.rotation = degrees
                model.updateComponent(component.id, in: mask.id, shape: .radial(value))
            }
            .onEnded { _ in
                original = nil
                model.endEdit(name: "Rotate \(mask.name)")
            }
    }
}
