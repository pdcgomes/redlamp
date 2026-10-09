import Foundation
import RedlampEngineAPI

/// What Calibrate from Target measured on a grey patch (CAM-28).
public struct CalibrationTarget: Equatable, Sendable {
    /// Where it was clicked, in the canvas's normalised frame, as the readout reads it.
    public var point: CGPoint
    /// The light the tone controls received there: linear Rec. 2020 luminance.
    public var luminance: Double
    /// Its L* as it rendered.
    public var lstar: Double
    /// The edit it was measured with, whose Exposure and anchor that light includes.
    public var recipe: EditRecipe
}

/// Redlamp Reproduction's exposure anchor on the open photo, and Calibrate from Target (CAM-28,
/// `docs/plans/2026-10-09-reproduction-design.md`).
public extension EditorModel {
    /// The anchor this photo's edit gets under Redlamp Reproduction: its camera's calibration, or
    /// else the typical one; nil for a photo that isn't raw.
    var photoAnchor: ExposureAnchor? {
        guard let info, info.isRaw else { return nil }
        return cameras.anchor(for: info.cameraName)
    }

    /// The camera's calibration in the store, when it has one.
    var cameraCalibration: CameraCalibrations.Entry? {
        guard let info, info.isRaw else { return nil }
        return cameras.entry(for: info.cameraName)
    }

    /// The camera's calibration differs from the anchor the edit renders with.
    var canUpdateCalibration: Bool {
        guard recipe.baseLook.isReproduction, let photo = photoAnchor else { return false }
        let current = recipe.exposureAnchor ?? .typical(for: info?.cameraName)
        return photo.stops != current.stops || photo.source != current.source
    }

    /// Calibrate from Target applies: a photo under Redlamp Reproduction.
    var canCalibrateFromTarget: Bool {
        info != nil && recipe.baseLook.isReproduction
    }

    /// The status line under the Base Look: how the edit's exposure is anchored.
    var calibrationStatus: String {
        guard let info, info.isRaw else { return "Not a raw photo: shown in its file's own light" }
        guard let anchor = recipe.exposureAnchor, anchor.source == .target else {
            return "Not calibrated: typical exposure"
        }
        let camera = anchor.camera ?? info.cameraName ?? "this camera"
        guard let entry = cameras.entry(for: anchor.camera), abs(entry.stops - anchor.stops) < 1e-9 else {
            return "Calibrated for \(camera) from a target"
        }
        return "Calibrated for \(camera) from a target, \(entry.date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// What bends the rendering away from the scene's own values, for the status line; nil when
    /// nothing does.
    var reproductionChanges: String? {
        let names = Self.bendingControls(in: recipe)
        guard !names.isEmpty else { return nil }
        let shown = names.count > 3 ? Array(names.prefix(2)) + ["\(names.count - 2) more"] : names
        let list = ListFormatter.localizedString(byJoining: shown)
        return "\(list) changed: tones no longer as measured"
    }

    /// The reference L* the popover offers: the last one used.
    var calibrationReference: Double {
        get { UserDefaults.standard.object(forKey: Self.calibrationReferenceKey) as? Double ?? 50 }
        set { UserDefaults.standard.set(newValue, forKey: Self.calibrationReferenceKey) }
    }

    /// Calibrate [camera]: keeps the anchor that puts the measured patch at `lstar` at Exposure 0
    /// for this camera, and gives it to the edit with Exposure 0, in one step.
    func calibrate(toReference lstar: Double) {
        guard let target = calibrationTarget, let info, info.isRaw, let camera = info.cameraName else { return }
        let measured = target.recipe.exposureAnchor?.stops ?? ExposureAnchor.typicalStops
        let stops = Self.stops(from: target, to: lstar) + target.recipe[.exposure] + measured
        do {
            try cameras.calibrate(CameraCalibrations.Entry(
                camera: camera, stops: stops, iso: info.iso, date: Date(), photo: info.fileName,
            ))
            calibrationMessage = nil
        } catch {
            calibrationMessage = "The calibration couldn't be kept: \(error.localizedDescription)"
            return
        }
        calibrationReference = lstar
        calibrationTarget = nil
        var next = recipe
        next.exposureAnchor = ExposureAnchor(stops: stops, source: .target, camera: camera)
        next[.exposure] = 0
        commit(next, .baseLook, "Calibrate from Target")
    }

    /// Set This Photo's Exposure: the Exposure that puts the measured patch at `lstar`. Nothing is
    /// kept for the camera.
    func setExposure(toReference lstar: Double) {
        guard let target = calibrationTarget else { return }
        calibrationReference = lstar
        calibrationTarget = nil
        setValue(.exposure, Self.stops(from: target, to: lstar) + target.recipe[.exposure])
    }

    /// Closes the popover without changing anything.
    func cancelCalibration() {
        calibrationTarget = nil
    }

    /// Gives the edit the camera's calibration as it is now, the typical anchor once forgotten.
    func updateCalibration() {
        guard canUpdateCalibration, let photo = photoAnchor else { return }
        var next = recipe
        next.exposureAnchor = photo
        commit(next, .baseLook, "Update Calibration")
    }

    /// Forgets the camera's calibration. Edits keep the anchor they have.
    func forgetCalibration() {
        guard let camera = info?.cameraName else { return }
        do {
            try cameras.forget(camera)
            calibrationMessage = nil
        } catch {
            calibrationMessage = "The calibration couldn't be forgotten: \(error.localizedDescription)"
        }
    }
}

extension EditorModel {
    static let calibrationReferenceKey = "app.redlamp.calibrationReference"

    /// `edit` with this photo's anchor (`EditRecipe.anchored`); as it is while no photo is open.
    func anchored(_ edit: EditRecipe) -> EditRecipe {
        info == nil ? edit : edit.anchored(photoAnchor)
    }

    /// The anchor a photo that isn't open gets: its camera's calibration or the typical one, its
    /// camera read from the file off the main thread; nil when it isn't raw.
    func anchor(forPhotoAt url: URL) async -> ExposureAnchor? {
        guard let inspector = engine as? any RawFileInspecting else { return .typical(for: nil) }
        let identity = await Task.detached { inspector.identify(url) }.value
        guard let identity else { return nil }
        return cameras.anchor(for: ImageInfo.cameraName(make: identity.make, model: identity.model))
    }

    /// A click on the photo with Calibrate from Target on: measures the patch there, over the
    /// readout's area, for the popover.
    func sampleCalibrationTarget(at point: CGPoint) {
        guard let visit = currentVisit else { return }
        let edit = recipe
        let area = readoutArea
        Task {
            let readout = await engine.readout(at: point, area: area, recipe: edit)
            guard currentVisit == visit else { return }
            calibrationTargetActive = false
            guard let readout, let stops = readout.stops else { return }
            calibrationTarget = CalibrationTarget(
                point: point, luminance: PixelReadout.middleGrey * pow(2, stops), lstar: readout.lab.x, recipe: edit,
            )
        }
    }

    /// The stops that take the measured patch's light to the luminance of `lstar`.
    static func stops(from target: CalibrationTarget, to lstar: Double) -> Double {
        log2(luminance(lstar: lstar) / max(target.luminance, 1e-9))
    }

    /// CIE luminance, white 1, of a lightness.
    static func luminance(lstar: Double) -> Double {
        lstar > 8 ? pow((lstar + 16) / 116, 3) : lstar / 903.3
    }

    /// What bends Redlamp Reproduction's rendering, by the names the panels give it: Amount below
    /// 100, tone controls but Exposure, Presence, the colour controls, the Tone Curve, Calibration,
    /// Black & White, the effects and masks with adjustments. White balance, Exposure, detail and
    /// lens corrections don't.
    static func bendingControls(in recipe: EditRecipe) -> [String] {
        var names: [String] = []
        if recipe.baseLook.amount < 100 {
            names.append("Base Look Amount")
        }
        let sliders: [ParameterID] = [
            .contrast, .highlights, .shadows, .whites, .blacks, .texture, .clarity, .dehaze, .vibrance, .saturation,
            .colorChrome, .colorChromeBlue, .dynamicRange,
        ]
        names += sliders.filter { !recipe.isDefault($0) }.map(\.spec.label)
        if !ToneCurveMath.isIdentity(recipe) {
            names.append(PanelID.toneCurve.title)
        }
        if PanelID.colorMixer.parameters.contains(where: { !recipe.isDefault($0) }) {
            names.append(PanelID.colorMixer.title)
        }
        if GradingRange.allCases.contains(where: {
            !recipe.isDefault($0.saturationParameter) || !recipe.isDefault($0.luminanceParameter)
        }) {
            names.append(PanelID.colorGrading.title)
        }
        if !recipe.pointColor.isEmpty {
            names.append("Point Color")
        }
        if PanelID.calibration.parameters.contains(where: { !recipe.isDefault($0) }) {
            names.append(PanelID.calibration.title)
        }
        if recipe.treatment == .blackAndWhite {
            names.append("Black & White")
        }
        let effects: [ParameterID] = [
            .vignetteAmount, .grainAmount, .halationAmount, .bloomAmount, .leakAmount, .dustAmount, .scratchAmount,
            .frameStyle,
        ]
        if effects.contains(where: { !recipe.isDefault($0) }) {
            names.append(PanelID.effects.title)
        }
        if recipe.masks.contains(where: { layer in
            layer.isVisible && layer.amount > 0
                && (!layer.adjustments.isEmpty || layer.curves != nil || !layer.pointColor.isEmpty)
        }) {
            names.append("Masks")
        }
        return names
    }
}
