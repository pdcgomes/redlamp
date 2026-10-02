import Foundation
import RedlampEngineAPI

/// The AI component the Refine Edge brush is armed on.
public struct EdgeBrushTarget: Hashable, Sendable {
    public var mask: UUID
    public var component: UUID
}

/// A Refine Edge stroke and the component it refines.
public struct EdgeBrushStroke: Hashable, Sendable {
    public var target: EdgeBrushTarget
    public var stroke: BrushStroke
    /// Painted to its end, so it can be solved.
    public var finished = false
}

/// The Refine Edge brush: paint over an AI mask's edge (hair, fur, a frayed sleeve) and the engine
/// solves coverage there again, per pixel, from the photo, keeping the mask as it was elsewhere.
/// Each stroke is one history step, and is kept with the mask so Update AI Masks applies it again.
public extension EditorModel {
    var isRefiningEdges: Bool {
        edgeBrushTarget != nil
    }

    /// The brush radius, as a fraction of the image height (as brush strokes measure it).
    var edgeBrushRadius: Double {
        BrushSettings(size: edgeBrushSize).radius
    }

    /// Arms the Refine Edge brush on an AI component.
    func startRefiningEdges(_ componentID: UUID, in maskID: UUID) {
        guard info != nil, case .ai = recipe.mask(maskID)?.components.first(where: { $0.id == componentID })?.shape
        else { return }
        cancelDrawing()
        activeTool = .masking
        selectedMaskID = maskID
        selectedComponentID = componentID
        edgeBrushTarget = EdgeBrushTarget(mask: maskID, component: componentID)
    }

    func stopRefiningEdges() {
        edgeBrushTarget = nil
    }

    func beginEdgeStroke(at point: ImagePoint) {
        guard let target = edgeBrushTarget else { return }
        edgeBrushStrokes.append(EdgeBrushStroke(
            target: target, stroke: BrushStroke(points: [point], size: edgeBrushRadius, feather: 0),
        ))
    }

    /// Extends the stroke being painted; points closer than a tenth of the radius are skipped.
    func continueEdgeStroke(to point: ImagePoint) {
        guard var last = edgeBrushStrokes.last, !last.finished, let previous = last.stroke.points.last
        else { return }
        let aspect = info?.pixelSize.aspectRatio ?? 1
        guard hypot((point.x - previous.x) * aspect, point.y - previous.y) >= max(last.stroke.size * 0.1, 0.0005)
        else { return }
        last.stroke.points.append(point)
        edgeBrushStrokes[edgeBrushStrokes.count - 1] = last
    }

    /// Ends the stroke being painted and solves the finished ones, one at a time, in order (a
    /// stroke ended while another is being solved waits its turn).
    func endEdgeStroke() async {
        if let last = edgeBrushStrokes.indices.last {
            edgeBrushStrokes[last].finished = true
        }
        guard !isSolvingEdges else { return }
        isSolvingEdges = true
        defer { isSolvingEdges = false }
        let photo = selection
        while let next = edgeBrushStrokes.first, next.finished {
            let target = next.target
            guard case let .ai(mask) = component(target)?.shape else {
                edgeBrushStrokes.removeFirst()
                continue
            }
            do {
                let refined = try await engine.refineMaskEdges(mask.bitmap, along: [next.stroke])
                guard selection == photo else {
                    edgeBrushStrokes.removeAll()
                    return
                }
                if case var .ai(current) = component(target)?.shape {
                    current.bitmap = refined
                    current.refinements = (current.refinements ?? []) + [next.stroke]
                    updateComponent(target.component, in: target.mask, shape: .ai(current), name: "Refine Edge Brush")
                }
            } catch {
                maskMessage = "The edge couldn't be refined: \(error)"
                edgeBrushStrokes.removeAll { $0.finished }
                return
            }
            edgeBrushStrokes.removeFirst()
        }
    }

    /// `[` and `]` while refining edges: the brush size.
    func nudgeEdgeBrush(direction: Double) {
        edgeBrushSize = ParameterID.maskBrushSize.spec.clamp(edgeBrushSize + direction * max(
            1,
            (edgeBrushSize * 0.15).rounded(),
        ))
    }

    private func component(_ target: EdgeBrushTarget) -> MaskComponent? {
        recipe.mask(target.mask)?.components.first { $0.id == target.component }
    }
}
