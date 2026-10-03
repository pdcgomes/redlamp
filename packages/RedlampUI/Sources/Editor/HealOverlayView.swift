import AppKit
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

                if let hover, frame.rect.contains(hover) {
                    let diameter = brushDiameter(frame)
                    Circle()
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(width: diameter, height: diameter)
                        .position(hover)
                        .allowsHitTesting(false)
                }

                ForEach(model.recipe.spots) { spot in
                    SpotHandles(spot: spot, frame: frame, isSelected: spot.id == model.selectedSpotID)
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
                    Task { await model.addSpot(at: point) }
                    return
                }
                let stroke = points.filter(frame.rect.contains).map(frame.image)
                Task { await model.addStroke(stroke) }
            }
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
                original = nil
                model.endEdit(.retouch, name)
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
                original = nil
                if let resized = model.recipe.spots.first(where: { $0.id == spot.id }) {
                    model.spotSettings.size = RetouchSpot.size(radius: resized.radius)
                }
                model.endEdit(.retouch, "Resize Spot")
            }
    }
}
