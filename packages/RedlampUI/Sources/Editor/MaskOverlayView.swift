import AppKit
import RedlampEngineAPI
import SwiftUI

/// Mask drawing and handles, layered over the canvas while the Masking tool is active.
///
/// Reads `maskOutlines` and `maskShapes` (structure and geometry, not adjustments), so
/// dragging a mask's sliders doesn't re-render the guides.
struct MaskOverlayView: View {
    @Environment(EditorModel.self) private var model
    @State private var drawingKind: MaskKind?
    @State private var drawStart: ImagePoint?

    var body: some View {
        GeometryReader { geometry in
            let frame = ImageFrame(rect: model.canvas.imageRect(in: geometry.size), geometry: model.canvasGeometry)
            ZStack {
                if model.isBrushing || model.isRefiningEdges {
                    BrushCanvas(frame: frame)
                } else if model.pointColorEyedropperActive || model.drawingKind == .colorRange
                    || model.drawingKind == .luminanceRange {
                    RangeSampler(frame: frame)
                } else if model.drawingKind == .objects {
                    ObjectPicker(frame: frame)
                } else if model.drawingKind != nil || drawingKind != nil {
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

                if let box = model.hoveredPersonBox {
                    let topLeft = frame.view(ImagePoint(x: box.x, y: box.y))
                    let bottomRight = frame.view(ImagePoint(x: box.x + box.width, y: box.y + box.height))
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: abs(bottomRight.x - topLeft.x), height: abs(bottomRight.y - topLeft.y))
                        .position(x: (topLeft.x + bottomRight.x) / 2, y: (topLeft.y + bottomRight.y) / 2)
                        .allowsHitTesting(false)
                }

                let shapes = model.maskShapes
                ForEach(model.maskOutlines) { mask in
                    if model.showMaskPins, mask.id != model.selectedMaskID, let first = mask.components.first,
                       let center = model.maskPins[mask.id] ?? shapes[first.id]?.center {
                        Pin(selected: false)
                            .position(frame.view(center))
                            .onTapGesture { model.selectMask(mask.id) }
                            .onHover { inside in
                                if inside {
                                    model.hoveredMaskID = mask.id
                                } else if model.hoveredMaskID == mask.id {
                                    model.hoveredMaskID = nil
                                }
                            }
                            .help(mask.name)
                    }
                }

                // Shown while a shape is being drawn too, so its guides follow the drag.
                if model.showMaskPins, let mask = model.selectedOutline {
                    ForEach(mask.components) { component in
                        if let shape = shapes[component.id] {
                            ComponentHandles(
                                mask: mask,
                                component: component,
                                shape: shape,
                                frame: frame,
                                isSelected: component.id == model.selectedComponentOutline?.id,
                            )
                        }
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

/// Brushing: each drag paints a stroke; a ring shows the brush's size and feather. The Refine
/// Edge brush paints the same way, its strokes shown as bands until their edge is solved.
private struct BrushCanvas: View {
    let frame: ImageFrame
    @Environment(EditorModel.self) private var model
    @State private var pointer: CGPoint?
    @State private var painting = false
    @State private var erasing = false

    var body: some View {
        let refining = model.isRefiningEdges
        let choice = model.strokeBrush(erasing: !refining && (erasing || NSEvent.modifierFlags.contains(.option)))
        let settings = model.brushes[choice]
        let radius = CGFloat(refining ? model.edgeBrushRadius : settings.radius) * frame.heightScale
        let core = refining ? radius * 2 : max(radius * 2 * CGFloat(1 - settings.feather / 100), 1)
        ZStack {
            if refining {
                ForEach(Array(model.edgeBrushStrokes.enumerated()), id: \.offset) { _, pending in
                    band(pending.stroke)
                }
            }
            Color.clear
                .contentShape(Rectangle())
                .gesture(paint)
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        pointer = location
                        erasing = NSEvent.modifierFlags.contains(.option)
                    case .ended:
                        pointer = nil
                    }
                }
                .onHover { inside in
                    if inside {
                        NSCursor.crosshair.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            BrushRingLayer(
                pointer: pointer,
                fallback: CGPoint(x: frame.rect.midX, y: frame.rect.midY),
                watched: refining ? [model.edgeBrushSize] : [settings.size, settings.feather],
                label: refining
                    ? "Size \(Int(model.edgeBrushSize.rounded()))"
                    : "Size \(Int(settings.size.rounded()))  ·  Feather \(Int(settings.feather.rounded()))",
                radius: radius,
            ) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
                        .frame(width: radius * 2, height: radius * 2)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                    Circle()
                        .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: core, height: core)
                    if choice == .erase {
                        Image(systemName: "minus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 1)
                    }
                }
            }
        }
    }

    /// A Refine Edge stroke as the band it marks.
    private func band(_ stroke: BrushStroke) -> some View {
        let points = stroke.points.map(frame.view)
        return Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            // A single dab still draws its disc.
            path.addLine(to: points.count > 1 ? points[1] : CGPoint(x: first.x + 0.01, y: first.y))
            for point in points.dropFirst(2) {
                path.addLine(to: point)
            }
        }
        .stroke(
            Color.white.opacity(0.35),
            style: StrokeStyle(
                lineWidth: CGFloat(stroke.size) * frame.heightScale * 2,
                lineCap: .round,
                lineJoin: .round,
            ),
        )
        .allowsHitTesting(false)
    }

    private var paint: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                pointer = gesture.location
                let point = frame.image(gesture.location)
                if painting {
                    model.continueStroke(to: point, pressure: Self.penPressure)
                } else {
                    painting = true
                    model.beginStroke(
                        at: point, pressure: Self.penPressure, erasing: NSEvent.modifierFlags.contains(.option),
                    )
                }
            }
            .onEnded { _ in
                painting = false
                model.endStroke()
            }
    }

    /// The pen's pressure when the stroke comes from a tablet; mice paint at full pressure.
    private static var penPressure: Double? {
        guard let event = NSApp.currentEvent, event.subtype == .tabletPoint else { return nil }
        return Double(event.pressure)
    }
}

/// The Color and Luminance Range eyedroppers, and Point Color's in a mask: click a spot, or drag out
/// a disc to average. Shift adds a colour sample instead of replacing the samples.
private struct RangeSampler: View {
    let frame: ImageFrame
    @Environment(EditorModel.self) private var model
    @State private var drag: (start: CGPoint, end: CGPoint)?

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(sample)
                .onHover { inside in
                    if inside {
                        NSCursor.crosshair.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            if let drag {
                let radius = hypot(drag.end.x - drag.start.x, drag.end.y - drag.start.y)
                Circle()
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .position(drag.start)
                    .allowsHitTesting(false)
            }
        }
    }

    private var sample: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                drag = (gesture.startLocation, gesture.location)
            }
            .onEnded { gesture in
                drag = nil
                let start = frame.image(gesture.startLocation)
                let distance = hypot(gesture.translation.width, gesture.translation.height)
                let radius = distance < 4 ? 0 : distance / frame.heightScale
                if model.pointColorEyedropperActive {
                    model.samplePointColor(atImage: start, radius: radius)
                } else if model.drawingKind == .colorRange {
                    model.sampleColorRange(at: start, radius: radius, adding: NSEvent.modifierFlags.contains(.shift))
                } else {
                    Task { await model.sampleLuminanceRange(at: start) }
                }
            }
    }
}

/// Objects: hovering tints what a click would select; clicks select and refine, and a drag draws a
/// box around a thing or brushes over it, as the Masking panel's choice says.
private struct ObjectPicker: View {
    let frame: ImageFrame
    @Environment(EditorModel.self) private var model
    /// The drag under way: where it started and the points it has passed.
    @State private var drag: [CGPoint] = []

    var body: some View {
        ZStack {
            if let preview = model.objectPreview, let image = Self.tint(preview) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: frame.rect.width, height: frame.rect.height)
                    .position(x: frame.rect.midX, y: frame.rect.midY)
                    .allowsHitTesting(false)
            }
            if let start = drag.first, let end = drag.last, drag.count > 1 {
                switch model.objectSelection {
                case .rectangle:
                    Path(CGRect(
                        x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
                        height: abs(end.y - start.y),
                    ))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .allowsHitTesting(false)
                case .brush:
                    Path { $0.addLines(drag) }
                        .stroke(
                            Color.accentColor.opacity(0.5),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round),
                        )
                        .allowsHitTesting(false)
                }
            }
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location) where drag.isEmpty: model.hoverObject(at: frame.image(location))
                    case .active: break
                    case .ended: model.hoverObject(at: nil)
                    }
                }
                .onTapGesture(coordinateSpace: .local) { location in
                    let excluding = NSEvent.modifierFlags.contains(.option)
                    Task { await model.selectObject(at: frame.image(location), excluding: excluding) }
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { gesture in
                            if drag.isEmpty {
                                drag = [gesture.startLocation]
                                model.hoverObject(at: nil)
                            }
                            drag.append(gesture.location)
                        }
                        .onEnded { gesture in
                            let stroke = (drag + [gesture.location]).map(frame.image)
                            drag = []
                            switch model.objectSelection {
                            case .rectangle:
                                let (a, b) = (frame.image(gesture.startLocation), frame.image(gesture.location))
                                let (left, right) = (min(max(min(a.x, b.x), 0), 1), min(max(max(a.x, b.x), 0), 1))
                                let (top, bottom) = (min(max(min(a.y, b.y), 0), 1), min(max(max(a.y, b.y), 0), 1))
                                guard right > left, bottom > top else { return }
                                let box = ImageRect(x: left, y: top, width: right - left, height: bottom - top)
                                Task { await model.selectObject(in: box) }
                            case .brush:
                                let excluding = NSEvent.modifierFlags.contains(.option)
                                Task { await model.selectObject(along: stroke, excluding: excluding) }
                            }
                        },
                )
                .onHover { inside in
                    if inside {
                        NSCursor.crosshair.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
    }

    /// The preview mask as translucent accent over the photo.
    private static func tint(_ bitmap: MaskBitmap) -> NSImage? {
        guard let png = bitmap.png, let mask = NSBitmapImageRep(data: png)?.cgImage else { return nil }
        let size = NSSize(width: mask.width, height: mask.height)
        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.clip(to: rect, mask: mask)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor)
            context.fill(rect)
            return true
        }
    }
}

/// Converts between normalised image coordinates and view points.
struct ImageFrame {
    let rect: CGRect
    /// How the photo maps to the frame on the canvas (crop, straighten, Transform, rotation);
    /// masks live in the photo's own coordinates.
    var geometry: GeometryMap?

    func view(_ point: ImagePoint) -> CGPoint {
        let image = SIMD2(point.x, point.y)
        let shown = geometry?.isIdentity == false ? geometry?.outputPoint(image) ?? image : image
        return CGPoint(x: rect.minX + shown.x * rect.width, y: rect.minY + shown.y * rect.height)
    }

    func image(_ point: CGPoint) -> ImagePoint {
        let shown = SIMD2((point.x - rect.minX) / max(rect.width, 1), (point.y - rect.minY) / max(rect.height, 1))
        let image = geometry?.isIdentity == false ? geometry?.imagePoint(shown) ?? shown : shown
        return ImagePoint(x: image.x, y: image.y)
    }

    /// How the photo's axes appear on screen at the frame's centre: the angle of its x axis
    /// (degrees, clockwise) and whether it is mirrored.
    var axes: (angle: Double, mirrored: Bool) {
        guard geometry?.isIdentity == false else { return (0, false) }
        let centre = image(CGPoint(x: rect.midX, y: rect.midY))
        let origin = view(centre)
        let alongX = view(ImagePoint(x: centre.x + 0.01, y: centre.y))
        let alongY = view(ImagePoint(x: centre.x, y: centre.y + 0.01))
        let x = CGPoint(x: alongX.x - origin.x, y: alongX.y - origin.y)
        let y = CGPoint(x: alongY.x - origin.x, y: alongY.y - origin.y)
        return (atan2(x.y, x.x) * 180 / .pi, x.x * y.y - x.y * y.x < 0)
    }

    /// View points per unit of image height (radial radii are in image heights), at the
    /// frame's centre.
    var heightScale: CGFloat {
        guard geometry?.isIdentity == false else { return rect.height }
        let centre = image(CGPoint(x: rect.midX, y: rect.midY))
        let a = view(centre)
        let b = view(ImagePoint(x: centre.x, y: centre.y + 0.01))
        return hypot(b.x - a.x, b.y - a.y) / 0.01
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
    let mask: MaskOutline
    let component: MaskOutline.Component
    let shape: MaskShape
    let frame: ImageFrame
    let isSelected: Bool

    @Environment(EditorModel.self) private var model
    @State private var original: MaskShape?

    var body: some View {
        switch shape {
        case let .linear(gradient):
            linear(gradient)
        case let .radial(gradient):
            radial(gradient)
        case let .colorRange(range):
            if isSelected {
                ForEach(range.samples.indices, id: \.self) { index in
                    let sample = range.samples[index]
                    let diameter = max(CGFloat(sample.radius) * frame.heightScale * 2, 10)
                    Circle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .position(frame.view(sample.center))
                        .allowsHitTesting(false)
                }
            }
            Pin(selected: isSelected)
                .position(frame.view(shape.center))
                .onTapGesture { model.selectedComponentID = component.id }
        default:
            Pin(selected: isSelected)
                .position(frame.view(shape.center))
                .onTapGesture { model.selectedComponentID = component.id }
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
        let axes = frame.axes
        // The shape's rotation is in the photo; on screen the photo may be turned or mirrored.
        let screenDegrees = axes.angle + (axes.mirrored ? -gradient.rotation : gradient.rotation)
        let angle = Angle.degrees(screenDegrees)
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
            let radians = screenDegrees * .pi / 180
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
        let shown = frame.view(point)
        return frame.image(CGPoint(x: shown.x + delta.width, y: shown.y + delta.height))
    }

    /// A drag that transforms the shape captured at the start of the gesture.
    private func drag(_ transform: @escaping (MaskShape, CGSize) -> MaskShape) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if original == nil {
                    original = shape
                    model.selectedComponentID = component.id
                    model.beginEdit()
                }
                guard let original else { return }
                model.updateComponent(component.id, in: mask.id, shape: transform(original, gesture.translation))
            }
            .onEnded { _ in
                original = nil
                model.endEdit(.mask(component.kind), "Edit \(mask.name)")
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
                    original = shape
                    model.beginEdit()
                }
                guard case var .radial(value) = shape else { return }
                let projected = abs((gesture.location.x - center.x) * axis.x + (gesture.location.y - center.y) * axis.y)
                apply(&value, max(projected / frame.heightScale, 0.01))
                model.updateComponent(component.id, in: mask.id, shape: .radial(value))
            }
            .onEnded { _ in
                original = nil
                model.endEdit(.mask(component.kind), "Edit \(mask.name)")
            }
    }

    private func rotationDrag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if original == nil {
                    original = shape
                    model.beginEdit()
                }
                guard case var .radial(value) = shape else { return }
                let screen = atan2(gesture.location.y - center.y, gesture.location.x - center.x) * 180 / .pi + 90
                let axes = frame.axes
                value.rotation = axes.mirrored ? axes.angle - screen : screen - axes.angle
                model.updateComponent(component.id, in: mask.id, shape: .radial(value))
            }
            .onEnded { _ in
                original = nil
                model.endEdit(.mask(component.kind), "Rotate \(mask.name)")
            }
    }
}
