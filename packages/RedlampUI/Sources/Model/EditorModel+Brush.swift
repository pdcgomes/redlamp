import Foundation
import RedlampEngineAPI

/// Painting brush masks: each drag is a stroke, added to the brush component being painted.
public extension EditorModel {
    var isBrushing: Bool {
        drawingKind == .brush
    }

    /// Paints into an existing brush component, as selecting it in Lightroom does.
    func editBrush(_ componentID: UUID, in maskID: UUID) {
        guard info != nil, case .brush = recipe.mask(maskID)?.components.first(where: { $0.id == componentID })?.shape
        else { return }
        edgeBrushTarget = nil
        activeTool = .masking
        selectedMaskID = maskID
        selectedComponentID = componentID
        drawingKind = .brush
        drawingTarget = nil
        drawingComponentID = componentID
    }

    /// The brush a stroke would use now: Erase while Option is held or Erase is chosen.
    func strokeBrush(erasing: Bool) -> BrushChoice {
        erasing ? .erase : activeBrush
    }

    /// Starts a stroke at `point`. The first stroke of a new brush creates its component (in a new
    /// mask, or added to `drawingTarget`); later ones are added to it.
    func beginStroke(at point: ImagePoint, pressure: Double? = nil, erasing: Bool = false) {
        if isRefiningEdges {
            return beginEdgeStroke(at: point)
        }
        guard isBrushing, info != nil else { return }
        let choice = strokeBrush(erasing: erasing)
        let settings = brushes[choice]
        let stroke = BrushStroke(
            points: [point], pressures: pressure.map { [$0] } ?? [], size: settings.radius,
            feather: settings.feather, flow: settings.flow, density: settings.density, erase: choice == .erase,
            autoMask: settings.autoMask,
        )
        var next = recipe
        if let target = drawingComponentID ?? (choice == .erase ? selectedBrushComponent : nil),
           let location = locateComponent(target, in: next),
           case var .brush(brush) = next.masks[location.mask].components[location.component].shape {
            brush.strokes.append(stroke)
            next.masks[location.mask].components[location.component].shape = .brush(brush)
            drawingComponentID = target
            selectedMaskID = next.masks[location.mask].id
            selectedComponentID = target
            pendingDrawingName = choice == .erase ? "Erase Brush" : "Brush Stroke"
        } else {
            // Nothing to erase from yet.
            guard choice != .erase,
                  let name = addDrawnComponent(.brush(BrushMask(strokes: [stroke])), kind: .brush, to: &next)
            else { return }
            pendingDrawingName = name
        }
        beginEdit()
        applyLive(next)
    }

    /// Extends the stroke; points closer than a tenth of the radius to the last are skipped.
    func continueStroke(to point: ImagePoint, pressure: Double? = nil) {
        if isRefiningEdges {
            return continueEdgeStroke(to: point)
        }
        guard isBrushing, let target = drawingComponentID, editStart != nil,
              let location = locateComponent(target, in: recipe),
              case var .brush(brush) = recipe.masks[location.mask].components[location.component].shape,
              var stroke = brush.strokes.last, let last = stroke.points.last
        else { return }
        let aspect = info?.pixelSize.aspectRatio ?? 1
        let distance = hypot((point.x - last.x) * aspect, point.y - last.y)
        guard distance >= max(stroke.size * 0.1, 0.0005) else { return }
        stroke.points.append(point)
        if let pressure {
            stroke.pressures.append(pressure)
        }
        brush.strokes[brush.strokes.count - 1] = stroke
        var next = recipe
        next.masks[location.mask].components[location.component].shape = .brush(brush)
        applyLive(next)
    }

    func endStroke() {
        if isRefiningEdges {
            Task { await endEdgeStroke() }
            return
        }
        guard editStart != nil else { return }
        endEdit(.mask(.brush), pendingDrawingName ?? "Brush Stroke")
        pendingDrawingName = nil
    }

    /// `[` and `]` while brushing: Size, or Feather with Shift.
    func nudgeBrush(direction: Double, feather: Bool) {
        let choice = activeBrush
        if feather {
            brushes[choice].feather = ParameterID.maskBrushFeather.spec.clamp(brushes[choice].feather + direction * 10)
        } else {
            let size = brushes[choice].size
            brushes[choice].size = ParameterID.maskBrushSize.spec.clamp(size + direction * max(
                1,
                (size * 0.15).rounded(),
            ))
        }
    }

    // MARK: - Helpers

    /// The selected component, when it is a brush.
    private var selectedBrushComponent: UUID? {
        guard let component = selectedComponent, case .brush = component.shape else { return nil }
        return component.id
    }
}
