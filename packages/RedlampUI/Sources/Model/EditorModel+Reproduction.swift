import Foundation
import RedlampEngineAPI

/// Redlamp Reproduction's exposure anchor on the open photo (CAM-28,
/// `docs/plans/2026-10-09-reproduction-design.md`).
public extension EditorModel {
    /// The anchor this photo's edit gets under Redlamp Reproduction: its camera's calibration, or
    /// else the typical one; nil for a photo that isn't raw.
    var photoAnchor: ExposureAnchor? {
        guard let info, info.isRaw else { return nil }
        return cameras.anchor(for: info.cameraName)
    }

    /// The camera's calibration differs from the anchor the edit renders with.
    var canUpdateCalibration: Bool {
        guard recipe.baseLook.isReproduction, let photo = photoAnchor else { return false }
        let current = recipe.exposureAnchor ?? .typical(for: info?.cameraName)
        return photo.stops != current.stops || photo.source != current.source
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
}
