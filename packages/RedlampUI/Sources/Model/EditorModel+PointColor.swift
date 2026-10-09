import Foundation
import RedlampDocument
import RedlampEngineAPI

/// Whose swatches Point Color's controls edit: the edit's, in the Color Mixer, or a mask's, in the
/// Masking panel.
public enum PointColorTarget: Hashable, Sendable {
    case edit
    case mask(UUID)
}

/// Point Color (TON-29): swatches picked with an eyedropper on the photo, and the sliders of the
/// selected one.
public extension EditorModel {
    /// The selected mask's swatches while the Masking tool is open, the edit's otherwise.
    var pointColorTarget: PointColorTarget {
        if activeTool == .masking, let mask = selectedMaskID {
            return .mask(mask)
        }
        return .edit
    }

    /// The target's swatches.
    var pointColorSwatches: [PointColorSwatch] {
        Self.swatches(of: pointColorTarget, in: recipe)
    }

    /// The swatch the sliders edit: the one selected, or else the target's newest.
    var selectedPointColorSwatch: PointColorSwatch? {
        let swatches = pointColorSwatches
        return swatches.first { $0.id == selectedPointColorSwatchID } ?? swatches.last
    }

    /// The eyedropper's click on the canvas: what Point Color receives there becomes a new swatch.
    func samplePointColor(at point: CGPoint) {
        guard let photoPoint = imagePoint(forCanvas: point) else { return }
        samplePointColor(atImage: ImagePoint(x: photoPoint.x, y: photoPoint.y), radius: 0)
    }

    /// The colour Point Color receives at `point`, averaged over a disc of `radius` (a fraction of
    /// the photo's height), becomes a new swatch of the target's, selected; with all eight in use,
    /// the selected swatch takes it instead.
    func samplePointColor(atImage point: ImagePoint, radius: Double) {
        guard let visit = currentVisit else { return }
        let target = pointColorTarget
        Task {
            let sampled = await engine.pointColorInput(
                sampledAt: CGPoint(x: point.x, y: point.y), radius: radius, recipe: recipe,
            )
            guard currentVisit == visit else { return }
            pointColorEyedropperActive = false
            guard let sampled else { return }
            addPointColorSwatch(.oklch(sampled), picked: ColorSample(center: point, radius: radius), to: target)
        }
    }

    func addPointColorSwatch(_ color: OKLCh, picked: ColorSample? = nil) {
        addPointColorSwatch(.oklch(color), picked: picked, to: pointColorTarget)
    }

    /// A swatch of the selected mask's own colour: the median of what Point Color receives under it,
    /// for each photo the mask is on.
    func addMaskColorSwatch() {
        guard case .mask = pointColorTarget else { return }
        addPointColorSwatch(.mask, picked: nil, to: pointColorTarget)
    }

    func deletePointColorSwatch(_ id: UUID) {
        let target = pointColorTarget
        let next = Self.changingSwatches(of: target, in: recipe) { $0.removeAll { $0.id == id } }
        guard next != recipe else { return }
        commit(next, target.action, "Delete Point Color Swatch")
    }

    /// Leaving the Color Mixer's Point Color mode, or the Masking tool, ends Point Color's eyedropper
    /// and Visualize Range.
    func leavePointColor() {
        pointColorEyedropperActive = false
        visualizePointColorRange = false
    }

    /// A click on the canvas while an eyedropper or Calibrate from Target is on.
    func sampleEyedropper(at point: CGPoint) {
        if calibrationTargetActive {
            sampleCalibrationTarget(at: point)
        } else if pointColorEyedropperActive {
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
        guard let id = selectedPointColorSwatch?.id else { return }
        let next = Self.changingSwatches(of: pointColorTarget, in: recipe) { swatches in
            if let index = swatches.firstIndex(where: { $0.id == id }) {
                swatches[index][parameter] = parameter.spec.quantize(value)
            }
        }
        guard next != recipe else { return }
        let previous = recipe
        applyLive(next)
        if editStart == nil {
            recordStep(for: parameter, from: previous)
        }
    }

    /// Opening another photo turns both eyedroppers and Calibrate from Target off.
    func endEyedroppers() {
        // Set only when on: each assignment tells the views reading them, a photo left at a time.
        if eyedropperActive {
            eyedropperActive = false
        }
        if pointColorEyedropperActive {
            pointColorEyedropperActive = false
        }
        calibrationTargetActive = false
        calibrationTarget = nil
    }

    /// A group header's reset, on the selected swatch.
    func resetPointColorValues(_ parameters: [ParameterID], name: String) {
        guard let id = selectedPointColorSwatch?.id else { return }
        let target = pointColorTarget
        let next = Self.changingSwatches(of: target, in: recipe) { swatches in
            guard let index = swatches.firstIndex(where: { $0.id == id }) else { return }
            for parameter in parameters {
                swatches[index][parameter] = parameter.spec.defaultValue
            }
        }
        guard next != recipe else { return }
        commit(next, target == .edit ? .reset : target.action, name)
    }

    /// Records a change to the selected swatch's `parameter` as a step: "Point Color Hue Uniformity",
    /// after the mask's name for a mask's swatch.
    func recordPointColorStep(for parameter: ParameterID, from previous: EditRecipe) {
        let spec = parameter.spec
        let target = pointColorTarget
        let swatch = selectedPointColorSwatch?.id
        var name = "Point Color \(spec.label)"
        if case let .mask(id) = target {
            name = "\(recipe.mask(id)?.name ?? "Mask") \(name)"
        }
        recordHistory(target.action, name, from: previous) { recipe in
            spec
                .formatted(Self.swatches(of: target, in: recipe).first { $0.id == swatch }?[parameter] ?? spec
                    .defaultValue)
        }
    }

    private func addPointColorSwatch(
        _ color: PointColorSwatch.Color,
        picked: ColorSample?,
        to target: PointColorTarget,
    ) {
        let swatches = Self.swatches(of: target, in: recipe)
        if swatches.count < PointColorSwatch.maximumSwatches {
            let swatch = PointColorSwatch(color: color, picked: picked)
            let next = Self.changingSwatches(of: target, in: recipe) { $0.append(swatch) }
            selectedPointColorSwatchID = swatch.id
            commit(next, target.action, "Add Point Color Swatch")
        } else if let id = (swatches.first { $0.id == selectedPointColorSwatchID } ?? swatches.last)?.id {
            let next = Self.changingSwatches(of: target, in: recipe) { swatches in
                guard let index = swatches.firstIndex(where: { $0.id == id }) else { return }
                swatches[index].color = color
                swatches[index].picked = picked
            }
            commit(next, target.action, "Pick Point Color")
        }
    }

    static func swatches(of target: PointColorTarget, in recipe: EditRecipe) -> [PointColorSwatch] {
        switch target {
        case .edit: recipe.pointColor
        case let .mask(id): recipe.mask(id)?.pointColor ?? []
        }
    }

    static func changingSwatches(
        of target: PointColorTarget, in recipe: EditRecipe, _ change: (inout [PointColorSwatch]) -> Void,
    ) -> EditRecipe {
        var next = recipe
        switch target {
        case .edit:
            change(&next.pointColor)
        case let .mask(id):
            if let index = next.masks.firstIndex(where: { $0.id == id }) {
                change(&next.masks[index].pointColor)
            }
        }
        return next
    }
}

extension PointColorTarget {
    /// How history files a change to the target's swatches.
    var action: HistoryAction {
        switch self {
        case .edit: .edit
        case .mask: .mask(nil)
        }
    }
}
