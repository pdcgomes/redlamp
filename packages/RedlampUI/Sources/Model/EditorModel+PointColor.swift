import Foundation
import RedlampEngineAPI

/// Point Color (TON-29): swatches picked with an eyedropper on the photo, and the sliders of the
/// selected one.
public extension EditorModel {
    /// The swatch the sliders edit: the one selected, or else the newest.
    var selectedPointColorSwatch: PointColorSwatch? {
        recipe.pointColor.first { $0.id == selectedPointColorSwatchID } ?? recipe.pointColor.last
    }

    /// The eyedropper's click (a canvas point): the colour Point Color receives there becomes a new
    /// swatch, selected; with all eight in use, the selected swatch takes it instead.
    func samplePointColor(at point: CGPoint) {
        guard let visit = currentVisit else { return }
        Task {
            guard let photoPoint = imagePoint(forCanvas: point) else { return }
            let sampled = await engine.pointColorInput(sampledAt: photoPoint, radius: 0, recipe: recipe)
            guard currentVisit == visit else { return }
            pointColorEyedropperActive = false
            guard let sampled else { return }
            addPointColorSwatch(sampled, picked: ColorSample(center: ImagePoint(x: photoPoint.x, y: photoPoint.y)))
        }
    }

    func addPointColorSwatch(_ color: OKLCh, picked: ColorSample? = nil) {
        var next = recipe
        if next.pointColor.count < PointColorSwatch.maximumSwatches {
            let swatch = PointColorSwatch(color: .oklch(color), picked: picked)
            next.pointColor.append(swatch)
            selectedPointColorSwatchID = swatch.id
            commit(next, .edit, "Add Point Color Swatch")
        } else if let index = next.pointColor.firstIndex(where: { $0.id == selectedPointColorSwatch?.id }) {
            next.pointColor[index].color = .oklch(color)
            next.pointColor[index].picked = picked
            commit(next, .edit, "Pick Point Color")
        }
    }

    func deletePointColorSwatch(_ id: UUID) {
        var next = recipe
        next.pointColor.removeAll { $0.id == id }
        guard next != recipe else { return }
        commit(next, .edit, "Delete Point Color Swatch")
    }

    /// Leaving the Color Mixer's Point Color mode ends its eyedropper and Visualize Range.
    func leavePointColor() {
        pointColorEyedropperActive = false
        visualizePointColorRange = false
    }

    /// A click on the canvas while an eyedropper is on.
    func sampleEyedropper(at point: CGPoint) {
        if pointColorEyedropperActive {
            samplePointColor(at: point)
        } else {
            sampleWhiteBalance(at: point)
        }
    }
}

extension EditorModel {
    func pointColorValue(_ parameter: ParameterID) -> Double {
        selectedPointColorSwatch?[parameter] ?? parameter.spec.defaultValue
    }

    /// The selected swatch's setting; outside a drag, each change is its own history step.
    func setPointColorValue(_ parameter: ParameterID, _ value: Double) {
        guard let id = selectedPointColorSwatch?.id,
              let index = recipe.pointColor.firstIndex(where: { $0.id == id })
        else { return }
        var next = recipe
        next.pointColor[index][parameter] = parameter.spec.quantize(value)
        guard next != recipe else { return }
        let previous = recipe
        applyLive(next)
        if editStart == nil {
            recordStep(for: parameter, from: previous)
        }
    }

    /// Opening another photo turns both eyedroppers off.
    func endEyedroppers() {
        eyedropperActive = false
        pointColorEyedropperActive = false
    }

    /// A group header's reset, on the selected swatch.
    func resetPointColorValues(_ parameters: [ParameterID], name: String) {
        guard let id = selectedPointColorSwatch?.id,
              let index = recipe.pointColor.firstIndex(where: { $0.id == id })
        else { return }
        var next = recipe
        for parameter in parameters {
            next.pointColor[index][parameter] = parameter.spec.defaultValue
        }
        guard next != recipe else { return }
        commit(next, .reset, name)
    }
}
