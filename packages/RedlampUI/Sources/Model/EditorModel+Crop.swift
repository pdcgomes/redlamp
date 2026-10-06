import AppKit
import CoreGraphics
import RedlampEngineAPI

/// The crop's aspect ratio presets, Lightroom's.
public enum CropAspect: Hashable, Sendable, CaseIterable {
    case free, original, square, fourByFive, fiveBySeven, twoByThree, sixteenByNine

    public var title: String {
        switch self {
        case .free: "Custom"
        case .original: "Original"
        case .square: "1 × 1"
        case .fourByFive: "4 × 5 / 8 × 10"
        case .fiveBySeven: "5 × 7"
        case .twoByThree: "2 × 3 / 4 × 6"
        case .sixteenByNine: "16 × 9"
        }
    }

    /// Width over height for a landscape frame; nil when free.
    func ratio(original: PixelSize) -> Double? {
        switch self {
        case .free: nil
        case .original: original.aspectRatio
        case .square: 1
        case .fourByFive: 5.0 / 4
        case .fiveBySeven: 7.0 / 5
        case .twoByThree: 3.0 / 2
        case .sixteenByNine: 16.0 / 9
        }
    }
}

/// The composition guides drawn in the crop, Lightroom's, in the order `O` cycles them.
public enum CropOverlay: Hashable, Sendable, CaseIterable {
    case grid, thirds, diagonal, goldenTriangle, goldenRatio, goldenSpiral, aspectRatios

    /// The orientations `⇧O` turns through: the golden spiral's eye in each corner, wound either
    /// way. The triangle alternates between its two.
    public static let orientations = 8

    public var title: String {
        switch self {
        case .grid: "Grid"
        case .thirds: "Thirds"
        case .diagonal: "Diagonal"
        case .goldenTriangle: "Golden Triangle"
        case .goldenRatio: "Golden Ratio"
        case .goldenSpiral: "Golden Spiral"
        case .aspectRatios: "Aspect Ratios"
        }
    }
}

public extension EditorModel {
    /// Swaps the crop between portrait and landscape about its centre (Lightroom's `X`), as
    /// large as it can be inside the frame.
    func swapCropOrientation() {
        let crop = recipe.crop
        let frame = cropFrameSize
        let toNormalized = Double(frame.width) / max(Double(frame.height), 1)
        // The same pixel size with width and height traded, scaled down to fit the frame.
        var width = crop.height / toNormalized
        var height = crop.width * toNormalized
        let fit = min(1, 1 / max(width, 1e-9), 1 / max(height, 1e-9))
        width *= fit
        height *= fit
        let center = crop.center
        var next = recipe
        next.crop = Self.shifted(
            CropRect(
                left: center.x - width / 2,
                top: center.y - height / 2,
                right: center.x + width / 2,
                bottom: center.y + height / 2,
            ),
            inside: .full,
        )
        cropIntent = next.crop
        constrainCrop(&next)
        commit(next, .crop, "Swap Crop Orientation")
    }

    /// The geometry of the frame on the canvas: the developed frame, or in the crop tool the
    /// whole straightened frame the crop is drawn on.
    var canvasGeometry: GeometryMap? {
        info.map { info in
            GeometryMap(
                recipe: recipe, imageSize: info.pixelSize, includesCrop: activeTool != .crop, lens: info.lensCorrection,
            )
        }
    }

    /// The photo point (EXIF-oriented, 0...1) behind a canvas point (0...1 across the frame).
    func imagePoint(forCanvas point: CGPoint) -> CGPoint? {
        guard let geometry = canvasGeometry else { return point }
        return geometry.imagePoint(SIMD2(point.x, point.y)).map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// The pixel size of the straightened frame the crop is cut from.
    var cropFrameSize: PixelSize {
        info
            .map { GeometryMap(recipe: recipe, imageSize: $0.pixelSize, includesCrop: false, lens: nil).outputSize } ??
            .zero
    }

    /// The crop's aspect as width over height, in pixels of the straightened frame.
    func pixelAspect(of crop: CropRect) -> Double {
        let frame = cropFrameSize
        return crop.width * Double(frame.width) / max(crop.height * Double(frame.height), 1e-9)
    }

    /// Sets the crop while drawing it (bracket a drag with `beginEdit` and `endEdit`).
    func setCrop(_ crop: CropRect) {
        var next = recipe
        next.crop = crop
        cropIntent = crop
        constrainCrop(&next)
        guard next != recipe else { return }
        apply(next)
    }

    /// Picks an aspect and fits the crop to it about its centre, as large as it can be.
    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let ratio = aspect.ratio(original: info?.pixelSize ?? cropFrameSize) else { return }
        let frame = cropFrameSize
        let current = recipe.crop
        // Keep the crop's orientation: a portrait crop stays portrait.
        let wanted = pixelAspect(of: current) >= 1 ? ratio : 1 / ratio
        let frameAspect = Double(frame.width) / max(Double(frame.height), 1)
        var width = 1.0, height = 1.0
        if wanted > frameAspect {
            height = frameAspect / wanted
        } else {
            width = wanted / frameAspect
        }
        let center = current.center
        var crop = CropRect(
            left: center.x - width / 2, top: center.y - height / 2, right: center.x + width / 2,
            bottom: center.y + height / 2,
        )
        crop = Self.shifted(crop, inside: .full)
        var next = recipe
        next.crop = crop
        cropIntent = crop
        constrainCrop(&next)
        commit(next, .crop, "Crop Aspect") { _ in aspect.title }
    }

    /// Turns the photo a quarter, the crop with it.
    func rotate(clockwise: Bool) {
        var next = recipe
        let crop = next.crop
        next.orientation = clockwise ? next.orientation.rotatedClockwise : next.orientation.rotatedCounterclockwise
        next.crop = clockwise
            ? CropRect(left: 1 - crop.bottom, top: crop.left, right: 1 - crop.top, bottom: crop.right)
            : CropRect(left: crop.top, top: 1 - crop.right, right: crop.bottom, bottom: 1 - crop.left)
        cropIntent = next.crop
        commit(next, .rotate, clockwise ? "Rotate Right" : "Rotate Left")
    }

    /// Mirrors the photo as shown, keeping the same crop of it.
    func flip(horizontally: Bool) {
        var next = recipe
        let crop = next.crop
        next.orientation = horizontally ? next.orientation.flippedHorizontally : next.orientation.flippedVertically
        next.crop = horizontally
            ? CropRect(left: 1 - crop.right, top: crop.top, right: 1 - crop.left, bottom: crop.bottom)
            : CropRect(left: crop.left, top: 1 - crop.bottom, right: crop.right, bottom: 1 - crop.top)
        // A mirrored photo turns the other way: the same angle would tilt it further.
        next[.cropAngle] = -next[.cropAngle]
        cropIntent = next.crop
        commit(next, .flip, horizontally ? "Flip Horizontal" : "Flip Vertical")
    }

    /// Levels the photo along a line drawn on the canvas (view points, y down): nearer horizontal
    /// it becomes horizontal, nearer vertical it becomes vertical, as Lightroom's Straighten tool.
    func straighten(from start: CGPoint, to end: CGPoint) {
        isStraightening = false
        let dx = end.x - start.x, dy = end.y - start.y
        guard hypot(dx, dy) > 4 else { return }
        var tilt = atan2(dy, dx) * 180 / .pi
        // The line's direction doesn't matter, only its slope.
        if tilt > 90 {
            tilt -= 180
        } else if tilt < -90 {
            tilt += 180
        }
        let correction = abs(tilt) <= 45 ? tilt : tilt - (tilt > 0 ? 90 : -90)
        // A positive angle turns the photo clockwise on screen, so a line falling to the right
        // needs a counterclockwise turn.
        let angle = min(max(recipe[.cropAngle] - correction, -45), 45)
        var next = recipe
        next[.cropAngle] = angle
        constrainCrop(&next)
        commit(next, .straighten, "Straighten") { "\(ParameterID.cropAngle.spec.formatted($0[.cropAngle]))°" }
    }

    /// Adds a Guided Upright guide (up to four, the oldest giving way) and solves again.
    func addGuide(_ guide: GuideLine) {
        uprightGuides.append(guide)
        if uprightGuides.count > 4 {
            uprightGuides.removeFirst()
        }
        applyGuidedUpright()
    }

    /// The Vertical, Horizontal and Rotate that make the guides upright or level.
    func applyGuidedUpright() {
        guard let info, !uprightGuides.isEmpty else { return }
        let solved = Transform(recipe: recipe).guided(
            by: uprightGuides, imageSize: info.pixelSize, orientation: recipe.orientation,
        )
        var next = recipe
        next[.transformVertical] = solved.vertical
        next[.transformHorizontal] = solved.horizontal
        next[.transformRotate] = solved.rotate
        constrainCrop(&next)
        commit(next, .upright, "Guided Upright")
    }

    /// Automatic Upright from the photo's detected edges. Guides give way to it; with too few
    /// edges to go on, the edit stays as it is.
    func applyUpright(_ mode: UprightMode) {
        guard let visit = currentVisit else { return }
        Task {
            let lines = await engine.detectLines()
            guard currentVisit == visit, let info,
                  let solved = Transform(recipe: recipe).upright(
                      mode, lines: lines, imageSize: info.pixelSize, orientation: recipe.orientation,
                  )
            else {
                NSSound.beep()
                return
            }
            uprightGuides = []
            isPlacingGuides = false
            var next = recipe
            next[.transformVertical] = solved.vertical
            next[.transformHorizontal] = solved.horizontal
            next[.transformRotate] = solved.rotate
            constrainCrop(&next)
            commit(next, .upright, "Upright") { _ in mode.name }
        }
    }

    /// Upright off: no guides, and no perspective or rotation correction.
    func clearUpright() {
        uprightGuides = []
        isPlacingGuides = false
        var next = recipe
        next.reset([.transformVertical, .transformHorizontal, .transformRotate])
        constrainCrop(&next)
        commit(next, .upright, "Upright") { _ in "Off" }
    }

    /// Removes the crop, angle and orientation.
    func resetCrop() {
        var next = recipe
        next.crop = .full
        next.orientation = .identity
        next[.cropAngle] = 0
        cropIntent = .full
        commit(next, .reset, "Reset Crop")
    }

    /// Fits the crop as last drawn inside the photo, when Constrain to Image is on.
    internal func constrainCrop(_ next: inout EditRecipe) {
        guard constrainCropToImage, let info else { return }
        next.crop = GeometryMap.constrained(
            cropIntent,
            recipe: next,
            imageSize: info.pixelSize,
            lens: info.lensCorrection,
        )
    }

    /// `crop` moved (not resized) to lie inside `bounds` where it can.
    internal static func shifted(_ crop: CropRect, inside bounds: CropRect) -> CropRect {
        var crop = crop
        let dx = max(bounds.left - crop.left, 0) - max(crop.right - bounds.right, 0)
        let dy = max(bounds.top - crop.top, 0) - max(crop.bottom - bounds.bottom, 0)
        crop.left += dx
        crop.right += dx
        crop.top += dy
        crop.bottom += dy
        return crop
    }
}
