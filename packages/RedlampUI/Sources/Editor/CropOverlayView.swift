import AppKit
import RedlampEngineAPI
import SwiftUI

/// The crop frame, drawn over the whole straightened frame while the Crop tool is active:
/// the outside dimmed, a composition guide (`O` cycles the chosen ones), and handles on the
/// corners and edges. Dragging a handle resizes (keeping the aspect when it is locked),
/// dragging inside moves the crop, and dragging outside turns the photo as the Angle slider
/// does, with a fine grid in the crop while Angle changes. ⌘-dragging (or any drag after
/// Straighten) draws a line to level the photo along instead.
struct CropOverlayView: View {
    @Environment(EditorModel.self) private var model
    @State private var dragStart: CropRect?
    @State private var level: (start: CGPoint, end: CGPoint)?
    @State private var turn: CropTurn?
    /// Which way the pointer outside the crop faces (`TurnPointer`).
    @State private var turnDirection = 0

    /// Which edges a handle moves: x −1 left, 1 right; y −1 top, 1 bottom; both 0 moves.
    private struct Handle: Hashable {
        var x: Int
        var y: Int

        /// The pointer over it shows the edges it moves.
        var position: FrameResizePosition {
            switch (x, y) {
            case (-1, -1): .topLeading
            case (0, -1): .top
            case (1, -1): .topTrailing
            case (-1, 0): .leading
            case (1, 0): .trailing
            case (-1, 1): .bottomLeading
            case (0, 1): .bottom
            default: .bottomTrailing
            }
        }
    }

    private nonisolated static let cornerSize: CGFloat = 10
    private nonisolated static let handleClickMargin: CGFloat = 8
    /// How far past the photo's corner a corner handle takes clicks.
    nonisolated static let cornerClickReach = cornerSize / 2 + handleClickMargin

    private static let handles = [
        Handle(x: -1, y: -1), Handle(x: 0, y: -1), Handle(x: 1, y: -1), Handle(x: -1, y: 0),
        Handle(x: 1, y: 0), Handle(x: -1, y: 1), Handle(x: 0, y: 1), Handle(x: 1, y: 1),
    ]

    var body: some View {
        GeometryReader { geometry in
            let frame = model.canvas.imageRect(in: geometry.size)
            let rect = Self.rect(of: model.recipe.crop, in: frame)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let drawsLine = model.isStraightening || level != nil
            ZStack {
                // Outside the crop a drag turns the photo, or draws a level line.
                Color.clear
                    .contentShape(Self.outside(rect, in: geometry.size), eoFill: true)
                    .gesture(outsideGesture(center: center))
                    .onContinuousHover { phase in
                        if case let .active(location) = phase {
                            turnDirection = TurnPointer.direction(of: location, from: center)
                        }
                    }
                    .pointerStyle(drawsLine ? .rectSelection : TurnPointer.styles[turnDirection])

                Self.outside(rect, in: geometry.size)
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                if model.isAdjustingAngle {
                    Self.fineGrid(in: rect)
                        .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                        .allowsHitTesting(false)
                } else {
                    Self.faintOverlay(model.cropOverlay, turns: model.cropOverlayTurns, in: rect)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        .allowsHitTesting(false)

                    Self.overlay(
                        model.cropOverlay, turns: model.cropOverlayTurns, ratios: model.cropOverlayChoices.ratios,
                        in: rect,
                    )
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    .allowsHitTesting(false)
                }

                // The crop's own size, with a pointer of its own, so the turning arrow stops at its edge.
                Rectangle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .pointerStyle(drawsLine ? .rectSelection : .default)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(dragGesture(Handle(x: 0, y: 0), frame: frame))

                if let level {
                    Path { path in
                        path.move(to: level.start)
                        path.addLine(to: level.end)
                    }
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    .allowsHitTesting(false)
                }

                ForEach(Self.handles, id: \.self) { handle in
                    Rectangle()
                        .fill(Color.white)
                        .frame(
                            width: handle.x == 0 || handle.y == 0 ? 14 : Self.cornerSize,
                            height: handle.x == 0 || handle.y == 0 ? 4 : Self.cornerSize,
                        )
                        .rotationEffect(handle.x != 0 && handle.y == 0 ? .degrees(90) : .zero)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .contentShape(Rectangle().inset(by: -Self.handleClickMargin))
                        .pointerStyle(.frameResize(position: handle.position))
                        .position(
                            x: handle.x < 0 ? rect.minX : (handle.x > 0 ? rect.maxX : rect.midX),
                            y: handle.y < 0 ? rect.minY : (handle.y > 0 ? rect.maxY : rect.midY),
                        )
                        .gesture(dragGesture(handle, frame: frame))
                }
            }
        }
    }

    /// The crop's rectangle on screen, in the straightened frame's.
    nonisolated static func rect(of crop: CropRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + crop.left * frame.width, y: frame.minY + crop.top * frame.height,
            width: crop.width * frame.width, height: crop.height * frame.height,
        )
    }

    /// The guide, turned `turns` times where it isn't symmetric; the Aspect Ratios overlay
    /// outlines `ratios`.
    private nonisolated static func overlay(
        _ kind: CropOverlay, turns: Int, ratios: Set<CropOverlay.AspectRatio>, in rect: CGRect,
    ) -> Path {
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
            case .goldenSpiral:
                let arcs = GoldenSpiral(in: rect, turns: turns).arcs
                if let first = arcs.first {
                    path.move(to: first.start)
                }
                for arc in arcs {
                    path.addCurve(to: arc.end, control1: arc.control1, control2: arc.control2)
                }
            case .aspectRatios:
                for outline in CropOverlay.aspectOutlines(in: rect, ratios: ratios) {
                    path.addRect(outline)
                }
            }
        }
    }

    /// The guide's faint lines: the golden spiral's squares.
    private nonisolated static func faintOverlay(_ kind: CropOverlay, turns: Int, in rect: CGRect) -> Path {
        Path { path in
            guard kind == .goldenSpiral else { return }
            for divider in GoldenSpiral(in: rect, turns: turns).dividers {
                path.move(to: divider.start)
                path.addLine(to: divider.end)
            }
        }
    }

    /// The grid while Angle changes, in place of the guide: squares a sixteenth of the crop's
    /// shorter side, lined up on its centre, for lining up horizons and verticals.
    nonisolated static func fineGrid(in rect: CGRect) -> Path {
        Path { path in
            let cell = min(rect.width, rect.height) / 16
            guard cell > 0 else { return }
            for offset in stride(from: 0, to: rect.width / 2, by: cell) {
                for x in offset == 0 ? [rect.midX] : [rect.midX - offset, rect.midX + offset] {
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                }
            }
            for offset in stride(from: 0, to: rect.height / 2, by: cell) {
                for y in offset == 0 ? [rect.midY] : [rect.midY - offset, rect.midY + offset] {
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
        }
    }

    /// The canvas outside the crop, filled even-odd.
    nonisolated static func outside(_ rect: CGRect, in size: CGSize) -> Path {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(rect)
        }
    }

    private var isLevelling: Bool {
        model.isStraightening || NSEvent.modifierFlags.contains(.command)
    }

    /// Outside the crop, turns the photo round the crop's centre as the Angle slider does, as one
    /// step; with ⌘ (or after Straighten), draws a level line.
    private func outsideGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { gesture in
                if level != nil || (turn == nil && isLevelling) {
                    level = (gesture.startLocation, gesture.location)
                    return
                }
                if turn == nil {
                    turn = CropTurn(center: center, from: gesture.startLocation, angle: model.recipe[.cropAngle])
                    model.beginEdit(.cropAngle)
                }
                turnDirection = TurnPointer.direction(of: gesture.location, from: center)
                if let angle = turn?.angle(at: gesture.location) {
                    model.setValue(.cropAngle, angle)
                }
            }
            .onEnded { _ in
                if turn != nil {
                    turn = nil
                    model.endEdit()
                } else {
                    finishLevel()
                }
            }
    }

    private func finishLevel() {
        if let level {
            model.straighten(from: level.start, to: level.end)
        }
        level = nil
    }

    private func dragGesture(_ handle: Handle, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                // Inside the crop, ⌘ (or Straighten) draws a level line instead of moving it.
                if handle == Handle(x: 0, y: 0), dragStart == nil, level != nil || isLevelling {
                    level = (gesture.startLocation, gesture.location)
                    return
                }
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
                if level != nil {
                    finishLevel()
                    return
                }
                dragStart = nil
                model.endEdit(.crop, "Crop")
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

/// A drag outside the crop turning the photo, as Lightroom's does: Angle changes by as far as the
/// pointer has gone round the crop's centre since the drag began, within the slider's range.
struct CropTurn {
    let center: CGPoint
    let startAngle: Double
    /// Where the pointer was last, round the centre: radians, clockwise on screen.
    private var bearing: Double
    /// How far it has gone round since the drag began, in degrees, clockwise.
    private var swept = 0.0

    init(center: CGPoint, from point: CGPoint, angle: Double) {
        self.center = center
        startAngle = angle
        bearing = Self.bearing(of: point, from: center)
    }

    /// Angle with the pointer at `point`. A rising angle turns the photo clockwise on screen, so the
    /// photo follows the pointer round; beyond the range it waits for the pointer to come back.
    mutating func angle(at point: CGPoint) -> Double {
        let next = Self.bearing(of: point, from: center)
        swept += remainder(next - bearing, 2 * .pi) * 180 / .pi
        bearing = next
        let range = ParameterID.cropAngle.spec.range
        return min(max(startAngle + swept, range.lowerBound), range.upperBound)
    }

    static func bearing(of point: CGPoint, from center: CGPoint) -> Double {
        atan2(point.y - center.y, point.x - center.x)
    }
}

/// The pointer outside the crop: a curved arrow round the crop's centre, black with a white edge
/// as macOS's own pointers are, facing the way it is from the centre.
@MainActor
enum TurnPointer {
    /// The directions it can face, round the crop.
    static let directions = 16

    /// One for each direction, the first facing right.
    static let styles: [PointerStyle] = (0 ..< directions).map { direction in
        .image(Image(nsImage: arrow(facing: Double(direction) * 2 * .pi / Double(directions))), hotSpot: .center)
    }

    /// The direction nearest `point`'s from `center`.
    static func direction(of point: CGPoint, from center: CGPoint) -> Int {
        let step = 2 * Double.pi / Double(directions)
        let index = Int((CropTurn.bearing(of: point, from: center) / step).rounded())
        return (index % directions + directions) % directions
    }

    /// An arc of a circle about a point towards the crop's centre, through the hot spot, with a head
    /// at each end; `bearing` is the pointer's from the centre, in radians clockwise on screen.
    private static func arrow(facing bearing: Double) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 12, y: 12)
            context.rotate(by: bearing)
            let radius = 10.0, sweep = 0.75
            let arc = CGMutablePath()
            arc.addArc(
                center: CGPoint(x: -radius, y: 0), radius: radius, startAngle: -sweep, endAngle: sweep,
                clockwise: false,
            )
            let heads = CGMutablePath()
            for (angle, outward) in [(-sweep, -1.0), (sweep, 1.0)] {
                let end = CGPoint(x: -radius + radius * cos(angle), y: radius * sin(angle))
                let along = CGPoint(x: -sin(angle) * outward, y: cos(angle) * outward)
                let across = CGPoint(x: cos(angle), y: sin(angle))
                let base = CGPoint(x: end.x - along.x * 1.5, y: end.y - along.y * 1.5)
                heads.addLines(between: [
                    CGPoint(x: end.x + along.x * 3.5, y: end.y + along.y * 3.5),
                    CGPoint(x: base.x + across.x * 3.5, y: base.y + across.y * 3.5),
                    CGPoint(x: base.x - across.x * 3.5, y: base.y - across.y * 3.5),
                ])
                heads.closeSubpath()
            }
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setFillColor(NSColor.white.cgColor)
            context.setLineWidth(4.5)
            context.addPath(arc)
            context.strokePath()
            context.setLineWidth(2.5)
            context.addPath(heads)
            context.drawPath(using: .fillStroke)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(2)
            context.addPath(arc)
            context.strokePath()
            context.addPath(heads)
            context.fillPath()
            return true
        }
    }
}

/// The golden spiral in a rectangle: quarter arcs through the golden rectangle's successive
/// squares, each cut at the golden ratio from what is left. In any other rectangle the squares
/// and arcs are stretched with it. Of the eight orientations (`turns`), the first four put the
/// eye in the bottom right, bottom left, top left and top right corners, cutting the longer side
/// first; the last four wind the other way into the same corners, cutting the shorter side first.
struct GoldenSpiral: Equatable {
    /// A quarter of an ellipse from `start` to `end` about `center`, its axes the frame's.
    struct Arc: Equatable {
        var center: CGPoint
        var start: CGPoint
        var end: CGPoint

        /// The control points of the cubic Bézier that draws it: a quarter circle's, stretched.
        var control1: CGPoint {
            CGPoint(x: start.x + Self.kappa * (end.x - center.x), y: start.y + Self.kappa * (end.y - center.y))
        }

        var control2: CGPoint {
            CGPoint(x: end.x + Self.kappa * (start.x - center.x), y: end.y + Self.kappa * (start.y - center.y))
        }

        private static let kappa = 4 * (sqrt(2) - 1) / 3
    }

    /// Outermost first, each starting where the one before ends, down to a couple of points.
    private(set) var arcs: [Arc] = []

    /// The lines between its squares: each arc's centre to its end.
    var dividers: [(start: CGPoint, end: CGPoint)] {
        arcs.map { (start: $0.center, end: $0.end) }
    }

    init(in rect: CGRect, turns: Int) {
        let orientations = CropOverlay.orientations
        let turn = (turns % orientations + orientations) % orientations
        // Laid out in a unit square for a landscape frame with the eye at the bottom right, then
        // transposed for the other winding (or a portrait frame) and mirrored into its corner.
        let transposed = (turn >= 4) != (rect.height > rect.width)
        let mirrorX = turn % 4 == 1 || turn % 4 == 2
        let mirrorY = turn % 4 >= 2
        func place(_ x: Double, _ y: Double) -> CGPoint {
            let (u, v) = transposed ? (y, x) : (x, y)
            return CGPoint(
                x: rect.minX + rect.width * (mirrorX ? 1 - u : u),
                y: rect.minY + rect.height * (mirrorY ? 1 - v : v),
            )
        }
        let width = transposed ? rect.height : rect.width
        let height = transposed ? rect.width : rect.height
        let section = (sqrt(5) - 1) / 2
        // What is left to divide: squares come off its left, top, right and bottom in turn.
        var (left, top, right, bottom) = (0.0, 0.0, 1.0, 1.0)
        while min((right - left) * width, (bottom - top) * height) >= 2 {
            switch arcs.count % 4 {
            case 0:
                let x = left + (right - left) * section
                arcs.append(Arc(center: place(x, bottom), start: place(left, bottom), end: place(x, top)))
                left = x
            case 1:
                let y = top + (bottom - top) * section
                arcs.append(Arc(center: place(left, y), start: place(left, top), end: place(right, y)))
                top = y
            case 2:
                let x = right - (right - left) * section
                arcs.append(Arc(center: place(x, top), start: place(right, top), end: place(x, bottom)))
                right = x
            default:
                let y = bottom - (bottom - top) * section
                arcs.append(Arc(center: place(right, y), start: place(right, bottom), end: place(left, y)))
                bottom = y
            }
        }
    }
}

extension CropOverlay {
    /// The outlines of `ratios`, in Lightroom's order: each centred in `rect`, the largest that
    /// fits, and portrait when `rect` is.
    static func aspectOutlines(in rect: CGRect, ratios: Set<AspectRatio> = Set(AspectRatio.allCases)) -> [CGRect] {
        AspectRatio.allCases.filter(ratios.contains).map { ratio in
            let aspect = rect.height > rect.width ? 1 / ratio.value : ratio.value
            let width = min(rect.width, rect.height * aspect)
            let height = min(rect.height, rect.width / aspect)
            return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
    }
}
