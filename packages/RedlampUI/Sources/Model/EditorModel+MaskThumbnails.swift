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

    /// Draws the thumbnails of masks whose coverage may have changed, keeping the others, and
    /// places their pins. A hidden mask is drawn as if shown.
    func refreshMaskThumbnails() async {
        guard let info, let visit = currentVisit else { return }
        let keys = maskCoverageKeys
        var thumbnails = maskThumbnails.filter { keys[$0.key] != nil && maskThumbnailKeys[$0.key] == keys[$0.key] }
        var pins = maskPins.filter { thumbnails[$0.key] != nil }
        // A still is drawn cropped, straightened and transformed, as the canvas shows the photo.
        let geometry = GeometryMap(
            recipe: recipe,
            imageSize: info.pixelSize,
            includesCrop: true,
            lens: info.lensCorrection,
        )
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
            pins[mask.id] = Self.innermostPoint(of: image).flatMap { point in
                let output = SIMD2(Double(point.x), Double(point.y))
                return (geometry.isIdentity ? output : geometry.imagePoint(output)).map { ImagePoint(x: $0.x, y: $0.y) }
            }
        }
        maskThumbnails = thumbnails
        maskThumbnailKeys = keys.filter { thumbnails[$0.key] != nil }
        maskPins = pins
    }

    /// The mask the canvas previews a component with while the pointer is over its row: the
    /// component alone, added, with no adjustments, so the photo under the overlay is unchanged.
    /// None with every mask slot taken, which shows the component's mask instead.
    func componentPreview(in recipe: EditRecipe) -> MaskLayer? {
        guard activeTool == .masking, let id = hoveredComponentID,
              recipe.masks.count(where: \.isVisible) < MaskLayer.maximumLayers,
              let component = recipe.masks.lazy.flatMap(\.components).first(where: { $0.id == id })
        else { return nil }
        return MaskLayer(
            id: Self.componentPreviewID, name: "",
            components: [MaskComponent(id: component.id, shape: component.shape, inverted: component.inverted)],
        )
    }

    static let componentPreviewID = UUID(uuidString: "C0B9E7A0-0000-4000-8000-00000000C0B9")!

    /// The point of a coverage thumbnail furthest from its edge (the frame's included), as a
    /// fraction of it; nil when it covers nothing. Of the points nearly as far in, the one nearest
    /// the coverage's centre, so a band's pin sits in its middle and a ring's on the ring.
    nonisolated static func innermostPoint(of image: CGImage) -> CGPoint? {
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        // A chamfer distance (3 along an axis, 4 diagonally) to the nearest pixel not covered.
        var distance = [Int](repeating: 0, count: width * height)
        var (sumX, sumY, covered) = (0.0, 0.0, 0.0)
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[y * width + x] > 127 {
                distance[y * width + x] = Int(Int32.max)
                sumX += Double(x)
                sumY += Double(y)
                covered += 1
            }
        }
        guard covered > 0 else { return nil }
        func at(_ x: Int, _ y: Int) -> Int {
            x < 0 || y < 0 || x >= width || y >= height ? 0 : distance[y * width + x]
        }
        for y in 0 ..< height {
            for x in 0 ..< width where distance[y * width + x] > 0 {
                distance[y * width + x] = min(
                    distance[y * width + x], at(x - 1, y) + 3, at(x, y - 1) + 3, at(x - 1, y - 1) + 4,
                    at(x + 1, y - 1) + 4,
                )
            }
        }
        for y in (0 ..< height).reversed() {
            for x in (0 ..< width).reversed() where distance[y * width + x] > 0 {
                distance[y * width + x] = min(
                    distance[y * width + x], at(x + 1, y) + 3, at(x, y + 1) + 3, at(x + 1, y + 1) + 4,
                    at(x - 1, y + 1) + 4,
                )
            }
        }
        let deepest = distance.max() ?? 0
        let (centreX, centreY) = (sumX / covered, sumY / covered)
        var best: (x: Int, y: Int, offset: Double)?
        for y in 0 ..< height {
            for x in 0 ..< width where distance[y * width + x] * 10 >= deepest * 9 {
                let offset = (Double(x) - centreX) * (Double(x) - centreX) + (Double(y) - centreY) *
                    (Double(y) - centreY)
                if offset < best?.offset ?? .infinity {
                    best = (x, y, offset)
                }
            }
        }
        return best.map { CGPoint(x: (Double($0.x) + 0.5) / Double(width), y: (Double($0.y) + 0.5) / Double(height)) }
    }
}
