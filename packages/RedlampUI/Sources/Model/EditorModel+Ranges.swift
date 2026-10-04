import Foundation
import RedlampEngineAPI

/// Color Range and Luminance Range: sampled with an eyedropper on the photo, then refined.
public extension EditorModel {
    /// The selected component's colour range, if it is one.
    var selectedColorRange: ColorRangeMask? {
        if case let .colorRange(range) = selectedComponent?.shape {
            range
        } else {
            nil
        }
    }

    var selectedLuminanceRange: LuminanceRangeMask? {
        if case let .luminanceRange(range) = selectedComponent?.shape {
            range
        } else {
            nil
        }
    }

    /// The selected Depth Range's trapezoid (0 far, 100 near).
    var selectedDepthRange: LuminanceRangeMask? {
        if case let .depthRange(range) = selectedComponent?.shape {
            range.range
        } else {
            nil
        }
    }

    func setDepthRange(_ trapezoid: LuminanceRangeMask) {
        guard let component = selectedComponent, let maskID = selectedMaskID,
              case var .depthRange(range) = component.shape
        else { return }
        range.range = trapezoid
        updateComponent(component.id, in: maskID, shape: .depthRange(range))
    }

    /// A Color Range sample: a click (radius 0) or a dragged disc. The first creates the
    /// component; later ones replace its samples, or with `adding` (Shift) join them, up to five.
    func sampleColorRange(at point: ImagePoint, radius: Double = 0, adding: Bool) {
        guard drawingKind == .colorRange, info != nil else { return }
        let sample = ColorSample(center: point, radius: radius)
        var next = recipe
        let name: String
        if let target = drawingComponentID ?? (adding ? selectedComponent?.id : nil),
           let location = locateComponent(target, in: next),
           case var .colorRange(range) = next.masks[location.mask].components[location.component].shape {
            if adding {
                guard range.samples.count < ColorRangeMask.maximumSamples else { return }
                range.samples.append(sample)
            } else {
                range.samples = [sample]
            }
            next.masks[location.mask].components[location.component].shape = .colorRange(range)
            drawingComponentID = target
            name = adding ? "Add Color Sample" : "Sample Color"
        } else {
            guard let added = addDrawnComponent(
                .colorRange(ColorRangeMask(samples: [sample])), kind: .colorRange, to: &next,
            ) else { return }
            name = added
        }
        commit(next, .mask(.colorRange), name)
    }

    func removeColorSample(at index: Int) {
        guard let component = selectedComponent, let maskID = selectedMaskID,
              case var .colorRange(range) = component.shape, range.samples.indices.contains(index),
              range.samples.count > 1
        else { return }
        range.samples.remove(at: index)
        updateComponent(component.id, in: maskID, shape: .colorRange(range), name: "Remove Color Sample")
    }

    /// The Luminance Range eyedropper: a range around the lightness under `point`.
    func sampleLuminanceRange(at point: ImagePoint) async {
        guard drawingKind == .luminanceRange, let visit = currentVisit else { return }
        let global = recipe
        guard let color = await engine.maskColor(sampledAt: CGPoint(x: point.x, y: point.y), recipe: global),
              currentVisit == visit, drawingKind == .luminanceRange
        else { return }
        let range = LuminanceRangeMask.sampled(lightness: color.x * 100, at: point)
        var next = recipe
        let name: String
        if let target = drawingComponentID, let location = locateComponent(target, in: next),
           case .luminanceRange = next.masks[location.mask].components[location.component].shape {
            next.masks[location.mask].components[location.component].shape = .luminanceRange(range)
            name = "Sample Luminance"
        } else {
            guard let added = addDrawnComponent(.luminanceRange(range), kind: .luminanceRange, to: &next)
            else { return }
            name = added
        }
        commit(next, .mask(.luminanceRange), name)
    }

    /// The range bar's handles. Live while dragging (inside `beginEdit` / `endEdit`).
    func setLuminanceRange(_ range: LuminanceRangeMask) {
        guard let component = selectedComponent, let maskID = selectedMaskID,
              case .luminanceRange = component.shape
        else { return }
        updateComponent(component.id, in: maskID, shape: .luminanceRange(range.normalized))
    }

    /// Edits an existing range component's samples with the eyedropper again.
    func resampleRange(_ componentID: UUID, in maskID: UUID) {
        guard info != nil, let shape = recipe.mask(maskID)?.components.first(where: { $0.id == componentID })?.shape,
              let kind = shape.kind, kind == .colorRange || kind == .luminanceRange
        else { return }
        activeTool = .masking
        selectedMaskID = maskID
        selectedComponentID = componentID
        drawingKind = kind
        drawingTarget = nil
        drawingComponentID = componentID
    }

    internal func locateComponent(_ componentID: UUID, in recipe: EditRecipe) -> (mask: Int, component: Int)? {
        for (maskIndex, mask) in recipe.masks.enumerated() {
            if let index = mask.components.firstIndex(where: { $0.id == componentID }) {
                return (maskIndex, index)
            }
        }
        return nil
    }
}
