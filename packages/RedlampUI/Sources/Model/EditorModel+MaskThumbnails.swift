import CoreGraphics
import Foundation
import RedlampEngineAPI

/// A thumbnail of each mask's coverage for the Masks panel's list (UX-23), drawn as the renderer
/// draws the black and white overlay: what the mask covers in white.
extension EditorModel {
    /// The long side of a mask's thumbnail, in pixels: two points' worth for a 36 pt row.
    static let maskThumbnailLongEdge = 72

    /// What a mask's coverage is drawn from: its components, the photo, and the edit without its
    /// masks (Color and Luminance Range select on the edited photo). A mask's own adjustments
    /// change nothing.
    var maskCoverageKeys: [UUID: Int] {
        var global = recipe
        global.masks = []
        return Dictionary(uniqueKeysWithValues: recipe.masks.map { mask in
            var hasher = Hasher()
            hasher.combine(mask.components)
            hasher.combine(global)
            hasher.combine(selection)
            return (mask.id, hasher.finalize())
        })
    }

    /// Draws the thumbnails of masks whose coverage may have changed, keeping the others. A hidden
    /// mask is drawn as if shown.
    func refreshMaskThumbnails() async {
        guard info != nil, let visit = currentVisit else { return }
        let keys = maskCoverageKeys
        var thumbnails = maskThumbnails.filter { keys[$0.key] != nil && maskThumbnailKeys[$0.key] == keys[$0.key] }
        for mask in recipe.masks where thumbnails[mask.id] == nil {
            var shown = recipe
            if let index = shown.masks.firstIndex(where: { $0.id == mask.id }) {
                shown.masks[index].isVisible = true
            }
            var request = StillRequest(recipe: shown, maxLongEdge: Self.maskThumbnailLongEdge)
            request.maskOverlay = mask.id
            request.maskOverlayStyle = .blackAndWhite
            guard let image = try? await engine.renderStill(request) else { continue }
            guard currentVisit == visit else { return }
            thumbnails[mask.id] = image
        }
        maskThumbnails = thumbnails
        maskThumbnailKeys = keys.filter { thumbnails[$0.key] != nil }
    }
}
