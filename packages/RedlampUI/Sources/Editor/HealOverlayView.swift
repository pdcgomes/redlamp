import RedlampEngineAPI
import SwiftUI

/// Heal and Clone spots over the canvas while the Healing tool is active. A click adds a circle
/// the size the tool's ring shows, and a drag paints a brushed spot; each spot is drawn with its
/// source (dashed) and a line between them, and dragging either moves it.
struct HealOverlayView: View {
    @Environment(EditorModel.self) private var model
    @State private var hover: CGPoint?
    @State private var painting: [CGPoint] = []

    var body: some View {
        GeometryReader { geometry in
            let frame = ImageFrame(rect: model.canvas.imageRect(in: geometry.size), geometry: model.canvasGeometry)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(paint(frame))
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location): hover = location
                        case .ended: hover = nil
                        }
                    }

                if painting.count > 1 {
                    let outline = SpotShape.outline(painting, width: brushDiameter(frame))
                    outline.fill(Color.white.opacity(0.15)).allowsHitTesting(false)
                    outline.stroke(Color.white.opacity(0.8), lineWidth: 1).allowsHitTesting(false)
                }

                let diameter = brushDiameter(frame)
                BrushRingLayer(
                    pointer: hover.flatMap { frame.rect.contains($0) && model.spotPick == .spot ? $0 : nil },
                    fallback: CGPoint(x: frame.rect.midX, y: frame.rect.midY),
                    watched: [model.spotSettings.size, model.spotSettings.feather],
                    label: "Size \(Int(model.spotSettings.size.rounded()))  ·  Feather \(Int(model.spotSettings.feather.rounded()))",
                    radius: diameter / 2,
                ) {
                    Circle()
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(width: diameter, height: diameter)
                }

                if model.showSpots {
                    ForEach(model.recipe.spots) { spot in
                        SpotHandles(spot: spot, frame: frame, isSelected: spot.id == model.selectedSpotID)
                    }
                }

                ForEach(model.foundThings) { found in
                    FoundOutline(found: found, frame: frame)
                }
            }
        }
    }

    private func brushDiameter(_ frame: ImageFrame) -> CGFloat {
        RetouchSpot.radius(size: model.spotSettings.size) * frame.heightScale * 2
    }

    /// A click adds a circle (or, off the photo, deselects); a drag paints a stroke.
    private func paint(_ frame: ImageFrame) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if painting.isEmpty {
                    painting = [gesture.startLocation]
                }
                if frame.rect.contains(gesture.location) {
                    painting.append(gesture.location)
                }
            }
            .onEnded { gesture in
                let points = painting
                painting = []
                guard hypot(gesture.translation.width, gesture.translation.height) >= 4 else {
                    guard frame.rect.contains(gesture.startLocation) else {
                        model.selectedSpotID = nil
                        return
                    }
                    let point = frame.image(gesture.startLocation)
                    if model.spotPick == .spot {
                        Task { await model.addSpot(at: point) }
                    } else {
                        Task { await model.pickRegion(at: point) }
                    }
                    return
                }
                guard model.spotPick == .spot else { return }
                let stroke = points.filter(frame.rect.contains).map(frame.image)
                Task { await model.addStroke(stroke) }
            }
    }
}

/// A thing Find outlined: its box, dashed, with its name and score above it; a click removes it.
private struct FoundOutline: View {
    let found: FoundThing
    let frame: ImageFrame

    @Environment(EditorModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        let box = found.box
        // Through the corners, so a rotated crop turns the box with the photo.
        let corners = [
            ImagePoint(x: box.x, y: box.y), ImagePoint(x: box.x + box.width, y: box.y),
            ImagePoint(x: box.x + box.width, y: box.y + box.height), ImagePoint(x: box.x, y: box.y + box.height),
        ].map(frame.view)
        let outline = Path { path in
            path.addLines(corners)
            path.closeSubpath()
        }
        outline
            .fill(Color.yellow.opacity(isHovered ? 0.18 : 0.04))
            .overlay(outline.stroke(
                Color.yellow.opacity(0.9), style: StrokeStyle(lineWidth: isHovered ? 2 : 1.5, dash: [5, 3]),
            ))
            .shadow(color: .black.opacity(0.6), radius: 1)
            .contentShape(outline)
            .onHover { isHovered = $0 }
            .onTapGesture { Task { await model.removeFound(found) } }
            .help("Remove this \(found.thing)")
        Color.clear
            .frame(width: 1, height: 1)
            .overlay(alignment: .bottomLeading) {
                Text("\(found.thing) \(Int((found.score * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.yellow)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()
            }
            .position(corners[0])
            .allowsHitTesting(false)
    }
}

/// A brushed spot's outline on screen: the stroke widened to the brush.
private enum SpotShape {
    static func outline(_ points: [CGPoint], width: CGFloat) -> Path {
        Path { path in
            path.addLines(points)
        }
        .strokedPath(StrokeStyle(lineWidth: max(width, 1), lineCap: .round, lineJoin: .round))
    }
}

/// One spot: its circle, its source's, the line between them, and a handle to resize it.
/// The label under a spot filled by the generative model, or being filled (RM-10).
private struct GeneratedLabel: View {
    let isGenerating: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isGenerating {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "sparkles")
            }
            Text(isGenerating ? "Generating" : "Generated")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

private struct SpotHandles: View {
    let spot: RetouchSpot
    let frame: ImageFrame
    let isSelected: Bool

    @Environment(EditorModel.self) private var model
    @State private var original: RetouchSpot?

    var body: some View {
        let center = frame.view(spot.center)
        let source = frame.view(spot.source)
        let radius = max(spot.radius * frame.heightScale, 4)
        let strength = isSelected ? 0.95 : 0.55

        if let region = spot.region {
            regionHandles(region, center: center, strength: strength)
        } else {
            shapeHandles(center: center, source: source, radius: radius, strength: strength)
        }

        let isGenerating = model.generating?.spot == spot.id
        if spot.fill != nil || isGenerating {
            GeneratedLabel(isGenerating: isGenerating)
                .position(x: center.x, y: center.y + (spot.region == nil ? radius : 0) + 14)
                .allowsHitTesting(false)
        }
    }

    /// A picked person or object: its outline while selected, so the fill inside it shows, and a
    /// pin to select it by.
    @ViewBuilder
    private func regionHandles(_ region: AIMask, center: CGPoint, strength: Double) -> some View {
        if isSelected, let loops = model.regionOutlines[region.bitmap.sha256] {
            Path { path in
                for loop in loops {
                    path.addLines(loop.map(frame.view))
                    path.closeSubpath()
                }
            }
            .stroke(Color.white.opacity(strength), lineWidth: 2)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .allowsHitTesting(false)
        }
        Circle()
            .fill(isSelected ? Color.accentColor : Color.white.opacity(0.85))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: isSelected ? 14 : 11, height: isSelected ? 14 : 11)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .contentShape(Circle().inset(by: -6))
            .position(center)
            .onTapGesture { model.selectedSpotID = spot.id }
            .help("\(spot.mode.name) \(region.kind == .people ? "person" : "object")")
            .task(id: isSelected ? region.bitmap : nil) {
                if isSelected {
                    await model.traceOutline(of: region)
                }
            }
    }

    /// A circle or stroke, its source when it has one, and a handle to resize it.
    @ViewBuilder
    private func shapeHandles(center: CGPoint, source: CGPoint, radius: CGFloat, strength: Double) -> some View {
        if spot.mode.usesSource {
            sourceHandles(center: center, source: source, radius: radius, strength: strength)
        }

        if spot.stroke.isEmpty {
            Circle()
                .stroke(Color.white.opacity(strength), lineWidth: isSelected ? 2 : 1)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .frame(width: radius * 2, height: radius * 2)
                .contentShape(Circle())
                .position(center)
                .onTapGesture { model.selectedSpotID = spot.id }
                .gesture(drag("Move Spot") { spot, delta in spot.center = offset(spot.center, by: delta) })
                .help(spot.mode.name)
        } else {
            let outline = SpotShape.outline(spot.points().map(frame.view), width: radius * 2)
            outline
                .stroke(Color.white.opacity(strength), lineWidth: isSelected ? 2 : 1)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .contentShape(outline)
                .onTapGesture { model.selectedSpotID = spot.id }
                .gesture(drag("Move Spot") { spot, delta in spot.center = offset(spot.center, by: delta) })
                .help("\(spot.mode.name) brush")
        }

        if isSelected {
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                .frame(width: 9, height: 9)
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .contentShape(Circle().inset(by: -6))
                .position(CGPoint(x: center.x + radius, y: center.y))
                .gesture(resize(center: center))
                .help("Drag to resize")
        }
    }

    /// The source's circle or stroke (dashed), and the line from it to the spot.
    @ViewBuilder
    private func sourceHandles(center: CGPoint, source: CGPoint, radius: CGFloat, strength: Double) -> some View {
        Path { path in
            let dx = center.x - source.x, dy = center.y - source.y
            let length = hypot(dx, dy)
            guard length > radius * 2 else { return }
            let unit = CGPoint(x: dx / length, y: dy / length)
            path.move(to: CGPoint(x: source.x + unit.x * radius, y: source.y + unit.y * radius))
            path.addLine(to: CGPoint(x: center.x - unit.x * radius, y: center.y - unit.y * radius))
        }
        .stroke(Color.white.opacity(strength * 0.8), lineWidth: 1)
        .shadow(color: .black.opacity(0.6), radius: 1)
        .allowsHitTesting(false)

        if spot.stroke.isEmpty {
            Circle()
                .stroke(
                    Color.white.opacity(strength),
                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: [4, 3]),
                )
                .shadow(color: .black.opacity(0.6), radius: 1)
                .frame(width: radius * 2, height: radius * 2)
                .contentShape(Circle())
                .position(source)
                .onTapGesture { model.selectedSpotID = spot.id }
                .gesture(drag("Move Source") { spot, delta in spot.source = offset(spot.source, by: delta) })
                .help("\(spot.mode.name) source")
        } else {
            let sourceOutline = SpotShape.outline(spot.points(at: spot.source).map(frame.view), width: radius * 2)
            sourceOutline
                .stroke(
                    Color.white.opacity(strength),
                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: [4, 3]),
                )
                .shadow(color: .black.opacity(0.6), radius: 1)
                .contentShape(sourceOutline)
                .onTapGesture { model.selectedSpotID = spot.id }
                .gesture(drag("Move Source") { spot, delta in spot.source = offset(spot.source, by: delta) })
                .help("\(spot.mode.name) source")
        }
    }

    private func offset(_ point: ImagePoint, by delta: CGSize) -> ImagePoint {
        let shown = frame.view(point)
        return frame.image(CGPoint(x: shown.x + delta.width, y: shown.y + delta.height))
    }

    /// A drag that moves the spot as it was when the drag began.
    private func drag(_ name: String, _ transform: @escaping (inout RetouchSpot, CGSize) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if original == nil {
                    original = spot
                    model.selectedSpotID = spot.id
                    model.beginEdit()
                }
                guard var moved = original else { return }
                transform(&moved, gesture.translation)
                model.updateSpot(spot.id) { $0 = moved }
            }
            .onEnded { _ in
                let refills = original?.fill != nil || model.generating?.spot == spot.id
                original = nil
                model.endEdit(.retouch, name)
                if refills {
                    model.refillGeneratively(spot.id)
                }
            }
    }

    private func resize(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if original == nil {
                    original = spot
                    model.beginEdit()
                }
                let distance = hypot(gesture.location.x - center.x, gesture.location.y - center.y)
                let range = RetouchSpot.radiusRange
                let radius = min(max(distance / max(frame.heightScale, 1), range.lowerBound), range.upperBound)
                model.updateSpot(spot.id) { $0.radius = radius }
            }
            .onEnded { _ in
                let refills = original?.fill != nil || model.generating?.spot == spot.id
                original = nil
                if let resized = model.recipe.spots.first(where: { $0.id == spot.id }) {
                    model.spotSettings.size = RetouchSpot.size(radius: resized.radius)
                }
                model.endEdit(.retouch, "Resize Spot")
                if refills {
                    model.refillGeneratively(spot.id)
                }
            }
    }
}
