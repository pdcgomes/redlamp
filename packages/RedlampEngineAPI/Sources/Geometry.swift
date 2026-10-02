import Foundation
import simd

/// The user's rotation and flip, applied after the camera's (EXIF) orientation, so the photo's
/// own coordinates (`ImagePoint`, DEC-07) never change.
public struct ImageOrientation: Codable, Sendable, Hashable {
    /// Clockwise quarter turns, 0...3, after mirroring.
    public var quarterTurns: Int
    /// Mirrored left to right before turning.
    public var mirrored: Bool

    public static let identity = ImageOrientation()

    public init(quarterTurns: Int = 0, mirrored: Bool = false) {
        self.quarterTurns = (quarterTurns % 4 + 4) % 4
        self.mirrored = mirrored
    }

    public var isIdentity: Bool {
        self == .identity
    }

    /// Whether width and height trade places.
    public var swapsAxes: Bool {
        quarterTurns % 2 == 1
    }

    public var rotatedClockwise: ImageOrientation {
        ImageOrientation(quarterTurns: quarterTurns + 1, mirrored: mirrored)
    }

    public var rotatedCounterclockwise: ImageOrientation {
        ImageOrientation(quarterTurns: quarterTurns + 3, mirrored: mirrored)
    }

    /// Flipped left to right as the photo is shown now.
    public var flippedHorizontally: ImageOrientation {
        ImageOrientation(quarterTurns: -quarterTurns, mirrored: !mirrored)
    }

    /// Flipped top to bottom as the photo is shown now.
    public var flippedVertically: ImageOrientation {
        ImageOrientation(quarterTurns: 2 - quarterTurns, mirrored: !mirrored)
    }

    /// Photo (normalised) to oriented (normalised) coordinates, homogeneous.
    public var matrix: simd_double3x3 {
        var matrix = mirrored ? simd_double3x3(rows: [SIMD3(-1, 0, 1), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]) :
            matrix_identity_double3x3
        let clockwise = simd_double3x3(rows: [SIMD3(0, -1, 1), SIMD3(1, 0, 0), SIMD3(0, 0, 1)])
        for _ in 0 ..< quarterTurns {
            matrix = clockwise * matrix
        }
        return matrix
    }
}

/// A crop, normalised to the straightened frame: the oriented, transformed photo turned by the
/// crop angle so the crop is upright. The full frame is 0...1 on both axes.
public struct CropRect: Codable, Sendable, Hashable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public static let full = CropRect(left: 0, top: 0, right: 1, bottom: 1)

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: Double {
        right - left
    }

    public var height: Double {
        bottom - top
    }

    public var center: SIMD2<Double> {
        SIMD2((left + right) / 2, (top + bottom) / 2)
    }

    public var isFull: Bool {
        abs(left) < 1e-9 && abs(top) < 1e-9 && abs(right - 1) < 1e-9 && abs(bottom - 1) < 1e-9
    }

    /// Scaled by `factor` about its centre.
    public func scaled(by factor: Double) -> CropRect {
        let center = center
        let halfWidth = width / 2 * factor
        let halfHeight = height / 2 * factor
        return CropRect(
            left: center.x - halfWidth, top: center.y - halfHeight,
            right: center.x + halfWidth, bottom: center.y + halfHeight,
        )
    }
}

/// Every geometry edit as one map, from a pixel of the developed (cropped) output back to the
/// photo (LNS-05): the crop with its angle, then Transform, then the user's orientation, then
/// lens distortion (the manual slider, then the photo's own lens profile), to the EXIF-oriented
/// photo as the camera recorded it. Up to the lens it is a single homography; the lens adds
/// radial functions. The renderer applies them per pixel and samples the pyramid once.
public struct GeometryMap: Sendable, Equatable {
    /// The photo after its EXIF orientation.
    public let imageSize: PixelSize
    /// After the user's orientation: the frame Transform works in and the crop is cut from.
    public let canvasSize: PixelSize
    /// The developed photo: the crop, in canvas pixels.
    public let outputSize: PixelSize
    /// Output (0...1 across the crop) to photo (0...1, EXIF-oriented), homogeneous.
    public let toImage: simd_double3x3
    public let fromImage: simd_double3x3
    /// Radial distortion of the photo: a corrected point at radius r (in half-diagonals from the
    /// centre) was recorded at r · (1 + k r²). Zero without lens correction.
    public let lensDistortion: Double
    /// The photo's lens profile at the edit's amounts, when the edit applies it (process 5).
    public let lensProfile: LensCorrection?
    public let isIdentity: Bool

    /// The Distortion slider at ±100.
    public static let maximumDistortion = 0.2

    /// Vertical and Horizontal at ±100 tilt or turn the virtual camera this far.
    public static let maximumPerspective = 25.0

    /// `lens` is the photo's own correction (`ImageInfo.lensCorrection`), which the edit applies
    /// or not; every map of a photo must be given it, so overlays and renders agree.
    public init(recipe: EditRecipe, imageSize: PixelSize, includesCrop: Bool = true, lens: LensCorrection?) {
        self.init(
            imageSize: imageSize, orientation: recipe.orientation, crop: includesCrop ? recipe.crop : .full,
            angle: recipe[.cropAngle], transform: Transform(recipe: recipe),
            lensDistortion: -recipe[.lensDistortion] / 100 * Self.maximumDistortion,
            lensProfile: Self.profile(lens, recipe: recipe),
        )
    }

    /// The lens profile an edit applies: from its source's process version (5, or 6 for
    /// Fujifilm's), while Enable Profile Corrections is on.
    public static func profile(_ lens: LensCorrection?, recipe: EditRecipe) -> LensCorrection? {
        guard let lens, recipe.processVersion >= lens.source.process, recipe[.lensProfile] > 0.5 else { return nil }
        return lens.scaled(
            distortion: recipe[.lensProfileDistortion] / 100, vignetting: recipe[.lensProfileVignetting] / 100,
        )
    }

    public init(
        imageSize: PixelSize,
        orientation: ImageOrientation = .identity,
        crop: CropRect = .full,
        angle: Double = 0,
        transform: Transform = Transform(),
        lensDistortion: Double = 0,
        lensProfile: LensCorrection? = nil,
    ) {
        self.imageSize = imageSize
        self.lensDistortion = lensDistortion
        self.lensProfile = lensProfile.flatMap { lens in
            lens.distortion.isEmpty && lens.vignetting.isEmpty ? nil : lens.filling(imageSize: imageSize)
        }
        let canvas = orientation.swapsAxes
            ? PixelSize(width: imageSize.height, height: imageSize.width) : imageSize
        canvasSize = canvas
        outputSize = PixelSize(
            width: max(1, Int((crop.width * Double(canvas.width)).rounded())),
            height: max(1, Int((crop.height * Double(canvas.height)).rounded())),
        )
        let (w, h) = (Double(canvas.width), Double(canvas.height))
        let cropToFrame = simd_double3x3(rows: [
            SIMD3(crop.width, 0, crop.left), SIMD3(0, crop.height, crop.top), SIMD3(0, 0, 1),
        ])
        let centred = simd_double3x3(rows: [SIMD3(w, 0, -w / 2), SIMD3(0, h, -h / 2), SIMD3(0, 0, 1)])
        // The photo turns clockwise by the angle on screen, so a screen point shows the canvas
        // point turned back.
        let straighten = Self.rotation(-angle)
        let fromTransformed = transform.matrix(canvas: canvas).inverse
        let toImage = orientation.matrix.inverse * centred
            .inverse * fromTransformed * straighten * centred * cropToFrame
        self.toImage = (1 / toImage[2, 2]) * toImage
        fromImage = toImage.inverse
        isIdentity = orientation.isIdentity && crop.isFull && abs(angle) < 1e-9 && transform.isIdentity
            && abs(lensDistortion) < 1e-12 && self.lensProfile == nil
    }

    /// The photo point behind an output point, or nil when it lies behind the virtual camera.
    public func imagePoint(_ output: SIMD2<Double>) -> SIMD2<Double>? {
        Self.project(toImage, output).map(distorted)
    }

    /// Where a photo point lands in the output, or nil.
    public func outputPoint(_ image: SIMD2<Double>) -> SIMD2<Double>? {
        Self.project(fromImage, undistorted(image))
    }

    /// Half-diagonal units about the centre, so the lens is round whatever the aspect.
    private var lensScale: SIMD2<Double> {
        let aspect = imageSize.aspectRatio
        let halfDiagonal = 0.5 * (aspect * aspect + 1).squareRoot()
        return SIMD2(aspect, 1) / halfDiagonal
    }

    /// Where the camera recorded a lens-corrected photo point (green, for a profile that
    /// corrects colour fringes).
    func distorted(_ point: SIMD2<Double>) -> SIMD2<Double> {
        profileDistorted(manualDistorted(point))
    }

    /// The lens-corrected point the camera recorded at `point`.
    func undistorted(_ point: SIMD2<Double>) -> SIMD2<Double> {
        manualUndistorted(profileUndistorted(point))
    }

    private func manualDistorted(_ point: SIMD2<Double>) -> SIMD2<Double> {
        guard lensDistortion != 0 else { return point }
        let offset = (point - 0.5) * lensScale
        let scale = 1 + lensDistortion * simd_length_squared(offset)
        return 0.5 + (point - 0.5) * scale
    }

    private func profileDistorted(_ point: SIMD2<Double>) -> SIMD2<Double> {
        guard let lens = lensProfile else { return point }
        let radius = simd_length((point - lens.center) * lens.offsetScale(imageSize: imageSize))
        return lens.center + (point - lens.center) * lens.interpolate(lens.distortion, at: radius).y
    }

    /// The profile's inverse, by bisection on the radius (its source radius rises with radius).
    private func profileUndistorted(_ point: SIMD2<Double>) -> SIMD2<Double> {
        guard let lens = lensProfile else { return point }
        let recorded = simd_length((point - lens.center) * lens.offsetScale(imageSize: imageSize))
        guard recorded > 1e-12 else { return point }
        var (low, high) = (0.0, recorded * 2 + 0.5)
        for _ in 0 ..< 48 {
            let middle = (low + high) / 2
            if middle * lens.interpolate(lens.distortion, at: middle).y < recorded {
                low = middle
            } else {
                high = middle
            }
        }
        return lens.center + (point - lens.center) * ((low + high) / 2 / recorded)
    }

    /// The lens-corrected point the camera recorded at `point` (Newton on the radius).
    private func manualUndistorted(_ point: SIMD2<Double>) -> SIMD2<Double> {
        guard lensDistortion != 0 else { return point }
        let recorded = simd_length((point - 0.5) * lensScale)
        guard recorded > 1e-12 else { return point }
        var radius = recorded
        for _ in 0 ..< 8 {
            let f = radius * (1 + lensDistortion * radius * radius) - recorded
            let slope = 1 + 3 * lensDistortion * radius * radius
            guard abs(slope) > 1e-9 else { break }
            radius -= f / slope
        }
        return 0.5 + (point - 0.5) * (radius / recorded)
    }

    /// Photo pixels per output pixel at the output's centre.
    public var pixelScale: Double {
        let step = 1e-3
        guard let center = imagePoint(SIMD2(0.5, 0.5)),
              let right = imagePoint(SIMD2(0.5 + step, 0.5)),
              let down = imagePoint(SIMD2(0.5, 0.5 + step))
        else { return 1 }
        let image = SIMD2(Double(imageSize.width), Double(imageSize.height))
        let output = SIMD2(Double(outputSize.width), Double(outputSize.height))
        let dx = (right - center) * image / (step * output.x)
        let dy = (down - center) * image / (step * output.y)
        return abs(dx.x * dy.y - dx.y * dy.x).squareRoot()
    }

    /// Whether the whole output shows the photo, with no empty corners. The corners decide for a
    /// homography; lens distortion bends the edges, so points along them are checked too.
    public var staysInsideImage: Bool {
        let steps = lensDistortion == 0 && lensProfile == nil ? 1 : 8
        let border = (0 ... steps).flatMap { index -> [SIMD2<Double>] in
            let t = Double(index) / Double(steps)
            return [SIMD2(t, 0), SIMD2(t, 1), SIMD2(0, t), SIMD2(1, t)]
        }
        return border.allSatisfy { edge in
            guard let point = imagePoint(edge) else { return false }
            return point.x >= -1e-6 && point.y >= -1e-6 && point.x <= 1 + 1e-6 && point.y <= 1 + 1e-6
        }
    }

    /// The crop scaled about its centre until it stays inside the photo (Lightroom's Constrain to
    /// Image).
    public static func constrained(
        _ crop: CropRect,
        imageSize: PixelSize,
        orientation: ImageOrientation,
        angle: Double,
        transform: Transform,
        lensDistortion: Double = 0,
        lensProfile: LensCorrection? = nil,
    ) -> CropRect {
        func fits(_ candidate: CropRect) -> Bool {
            GeometryMap(
                imageSize: imageSize, orientation: orientation, crop: candidate, angle: angle, transform: transform,
                lensDistortion: lensDistortion, lensProfile: lensProfile,
            ).staysInsideImage
        }
        guard !fits(crop) else { return crop }
        var low = 0.0, high = 1.0
        for _ in 0 ..< 40 {
            let middle = (low + high) / 2
            if fits(crop.scaled(by: middle)) {
                low = middle
            } else {
                high = middle
            }
        }
        return crop.scaled(by: low)
    }

    /// `crop` fitted inside the photo under `recipe`'s angle, Transform, orientation and lens.
    public static func constrained(
        _ crop: CropRect, recipe: EditRecipe, imageSize: PixelSize, lens: LensCorrection?,
    ) -> CropRect {
        constrained(
            crop, imageSize: imageSize, orientation: recipe.orientation, angle: recipe[.cropAngle],
            transform: Transform(recipe: recipe),
            lensDistortion: -recipe[.lensDistortion] / 100 * maximumDistortion,
            lensProfile: profile(lens, recipe: recipe),
        )
    }

    static func rotation(_ degrees: Double) -> simd_double3x3 {
        let radians = degrees * .pi / 180
        return simd_double3x3(rows: [
            SIMD3(cos(radians), -sin(radians), 0), SIMD3(sin(radians), cos(radians), 0), SIMD3(0, 0, 1),
        ])
    }

    static func project(_ matrix: simd_double3x3, _ point: SIMD2<Double>) -> SIMD2<Double>? {
        let mapped = matrix * SIMD3(point.x, point.y, 1)
        guard mapped.z > 1e-12 else { return nil }
        return SIMD2(mapped.x / mapped.z, mapped.y / mapped.z)
    }
}

/// Lightroom's manual Transform: a virtual camera tilted (Vertical), turned (Horizontal) and
/// rolled (Rotate) about the frame's centre, then stretched (Aspect), scaled and offset.
public struct Transform: Sendable, Hashable {
    /// −100...100: negative widens the top, correcting verticals that converge upwards.
    public var vertical: Double = 0
    /// −100...100: negative widens the left side.
    public var horizontal: Double = 0
    /// Degrees, clockwise.
    public var rotate: Double = 0
    /// −100...100: positive stretches horizontally.
    public var aspect: Double = 0
    /// Percent.
    public var scale: Double = 100
    /// −100...100: a share of the frame's half width and half height.
    public var offsetX: Double = 0
    public var offsetY: Double = 0

    public init() {}

    public init(recipe: EditRecipe) {
        vertical = recipe[.transformVertical]
        horizontal = recipe[.transformHorizontal]
        rotate = recipe[.transformRotate]
        aspect = recipe[.transformAspect]
        scale = recipe[.transformScale]
        offsetX = recipe[.transformOffsetX]
        offsetY = recipe[.transformOffsetY]
    }

    public var isIdentity: Bool {
        self == Transform()
    }

    /// Oriented photo to transformed canvas, in pixels about the canvas centre.
    func matrix(canvas: PixelSize) -> simd_double3x3 {
        guard !isIdentity else { return matrix_identity_double3x3 }
        let (w, h) = (Double(canvas.width), Double(canvas.height))
        // A normal lens: the focal length is the frame's diagonal.
        let focal = hypot(w, h)
        let k = simd_double3x3(rows: [SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(0, 0, 1)])
        let tilt = -vertical / 100 * GeometryMap.maximumPerspective * .pi / 180
        let turn = -horizontal / 100 * GeometryMap.maximumPerspective * .pi / 180
        let aboutX = simd_double3x3(rows: [
            SIMD3(1, 0, 0), SIMD3(0, cos(tilt), -sin(tilt)), SIMD3(0, sin(tilt), cos(tilt)),
        ])
        let aboutY = simd_double3x3(rows: [
            SIMD3(cos(turn), 0, sin(turn)), SIMD3(0, 1, 0), SIMD3(-sin(turn), 0, cos(turn)),
        ])
        var perspective = k * GeometryMap.rotation(rotate) * aboutX * aboutY * k.inverse
        perspective = (1 / perspective[2, 2]) * perspective
        // Keep the centre where it was.
        let centre = perspective * SIMD3(0, 0, 1)
        let recentre = simd_double3x3(rows: [
            SIMD3(1, 0, -centre.x / centre.z), SIMD3(0, 1, -centre.y / centre.z), SIMD3(0, 0, 1),
        ])
        let stretch = exp(aspect / 100 * 0.4)
        let size = scale / 100
        let affine = simd_double3x3(rows: [
            SIMD3(size * stretch, 0, offsetX / 100 * w / 2),
            SIMD3(0, size / stretch, offsetY / 100 * h / 2),
            SIMD3(0, 0, 1),
        ])
        return affine * recentre * perspective
    }
}

public extension EditRecipe {
    /// The parameters that shape the developed frame rather than its look.
    static let geometryParameters: [ParameterID] = [
        .cropAngle, .lensDistortion, .lensProfile, .lensProfileDistortion, .transformVertical, .transformHorizontal,
        .transformRotate, .transformAspect, .transformScale, .transformOffsetX, .transformOffsetY,
    ]

    /// This edit with `other`'s crop, angle, Transform and orientation: a Before view framed
    /// like the After.
    func withGeometry(of other: EditRecipe) -> EditRecipe {
        var framed = self
        framed.crop = other.crop
        framed.orientation = other.orientation
        for parameter in Self.geometryParameters {
            framed[parameter] = other[parameter]
        }
        return framed
    }

    /// The developed frame's size for a photo of `imageSize` (EXIF-oriented).
    func developedSize(imageSize: PixelSize) -> PixelSize {
        // The crop alone sizes the frame; the lens doesn't.
        GeometryMap(recipe: self, imageSize: imageSize, lens: nil).outputSize
    }
}

/// A Guided Upright guide: a line along an edge that should be vertical or horizontal, in the
/// photo's own coordinates (EXIF-oriented), so it stays on its edge as the correction applies.
public struct GuideLine: Codable, Sendable, Hashable {
    public var start: ImagePoint
    public var end: ImagePoint

    public init(start: ImagePoint, end: ImagePoint) {
        self.start = start
        self.end = end
    }
}

/// Lightroom's automatic Upright modes.
public enum UprightMode: String, CaseIterable, Sendable {
    /// Level for a strong horizon or few lines, otherwise Vertical or Full, whichever the lines
    /// support, with perspective held to what still looks natural.
    case auto
    /// Rotate only: horizontal lines level, vertical ones upright on average.
    case level
    /// Rotate and Vertical: converging verticals made parallel.
    case vertical
    /// Rotate, Vertical and Horizontal: verticals upright and horizontals level.
    case full

    public var name: String {
        switch self {
        case .auto: "Auto"
        case .level: "Level"
        case .vertical: "Vertical"
        case .full: "Full"
        }
    }
}

/// A straight edge found in a photo, for automatic Upright, in the photo's own coordinates
/// (EXIF-oriented, like `GuideLine`).
public struct DetectedLine: Sendable, Hashable {
    public var line: GuideLine
    /// How much the edge counts: its length in pixels of a 1024-pixel analysis image, times its contrast.
    public var strength: Double

    public init(line: GuideLine, strength: Double) {
        self.line = line
        self.strength = strength
    }
}

public extension Transform {
    /// Lightroom's Guided Upright: the Vertical, Horizontal and Rotate that turn each guide
    /// upright or level (whichever it is nearer, as shown), keeping `self`'s other sliders.
    func guided(by guides: [GuideLine], imageSize: PixelSize, orientation: ImageOrientation) -> Transform {
        let lines = Self.uprightLines(guides.map { DetectedLine(line: $0, strength: 1) }, imageSize, orientation)
        return fitted(to: lines, free: [true, true, true], robust: false, canvas: Self.canvas(imageSize, orientation))
    }

    /// Automatic Upright from the photo's detected edges, keeping `self`'s other sliders. Lines
    /// within 30° of vertical count as verticals and within 30° of level as horizontals; the
    /// rest (roofs, diagonals) are ignored, and a robust fit lets the outliers among the counted
    /// ones go. A correction must be agreed: most of the lines' weight upright or level within
    /// 1.5° afterwards (for Level, which can't straighten converging lines, twice the minimum
    /// evidence instead), from lines spread over a quarter of the frame, and inside the
    /// sliders' range. Otherwise Full falls back to Vertical, Vertical to Level, and Level to
    /// nil, when `self` should stay as it is. Auto then leaves strong perspective partly in
    /// place, as Lightroom's does: past 30 at half strength, and eased until the crop it forces
    /// keeps at least 80% of the frame.
    func upright(
        _ mode: UprightMode, lines detected: [DetectedLine], imageSize: PixelSize, orientation: ImageOrientation,
    ) -> Transform? {
        let canvas = Self.canvas(imageSize, orientation)
        let all = Self.uprightLines(detected, imageSize, orientation).filter { line in
            let dx = line.b.x - line.a.x, dy = line.b.y - line.a.y
            let fromAxis = abs(line.vertical ? atan2(dx, dy) : atan2(dy, dx))
            return min(fromAxis, .pi - fromAxis) < 30 * .pi / 180
        }
        func evidence(_ lines: [UprightLine]) -> Double {
            lines.map(\.weight).reduce(0, +)
        }
        /// How far apart the lines are across the frame: verticals side to side, horizontals top to bottom.
        func spread(_ lines: [UprightLine], vertical: Bool) -> Double {
            let positions = lines.filter { $0.vertical == vertical }
                .map {
                    vertical ? ($0.a.x + $0.b.x) / 2 / Double(canvas.width) : ($0.a.y + $0.b.y) / 2 /
                        Double(canvas.height)
                }
            return (positions.max() ?? 0) - (positions.min() ?? 0)
        }
        // Lines of a combined 60 analysis pixels, at full contrast, make a correction worth applying.
        let enough = 60.0
        var base = self
        base.vertical = 0
        base.horizontal = 0
        base.rotate = 0
        func solve(_ lines: [UprightLine], free: [Bool]) -> (transform: Transform, inliers: [UprightLine])? {
            guard evidence(lines) >= enough else { return nil }
            let solved = base.fitted(to: lines, free: free, robust: true, canvas: canvas)
            guard abs(solved.rotate) < 9.9, abs(solved.vertical) < 99, abs(solved.horizontal) < 99 else { return nil }
            let residuals = Self.residuals(of: solved, lines, canvas: canvas)
            let inliers = zip(lines, residuals).filter { abs($1) < 1.5 * .pi / 180 }.map(\.0)
            let agreed = free == [false, false, true] ? evidence(inliers) >= 2 * enough
                : evidence(inliers) >= enough && evidence(inliers) >= 0.5 * evidence(lines)
            return agreed ? (solved, inliers) : nil
        }
        let level = solve(all, free: [false, false, true])?.transform
        let vertical: Transform? = {
            guard let solved = solve(all.filter(\.vertical), free: [true, false, true]),
                  solved.inliers.count >= 2, spread(solved.inliers, vertical: true) >= 0.25
            else { return level }
            return solved.transform
        }()
        let full: Transform? = {
            guard let solved = solve(all, free: [true, true, true]),
                  solved.inliers.count(where: { !$0.vertical }) >= 2, spread(solved.inliers, vertical: false) >= 0.25
            else { return vertical }
            return solved.transform
        }()
        switch mode {
        case .level: return level
        case .vertical: return vertical
        case .full: return full
        case .auto:
            guard var solved = full else { return nil }
            for keyPath in [\Transform.vertical, \Transform.horizontal] {
                let value = solved[keyPath: keyPath]
                if abs(value) > 30 {
                    solved[keyPath: keyPath] = (value < 0 ? -1 : 1) * (30 + 0.5 * (abs(value) - 30))
                }
            }
            return solved.eased(keeping: 0.8, imageSize: imageSize, orientation: orientation)
        }
    }

    /// This correction with its perspective scaled back, by bisection, until Constrain to Image
    /// keeps `area` of the frame.
    private func eased(keeping area: Double, imageSize: PixelSize, orientation: ImageOrientation) -> Transform {
        func scaled(_ factor: Double) -> Transform {
            var transform = self
            transform.vertical *= factor
            transform.horizontal *= factor
            return transform
        }
        func kept(_ transform: Transform) -> Double {
            var recipe = EditRecipe()
            recipe.orientation = orientation
            recipe[.transformVertical] = transform.vertical
            recipe[.transformHorizontal] = transform.horizontal
            recipe[.transformRotate] = transform.rotate
            let crop = GeometryMap.constrained(.full, recipe: recipe, imageSize: imageSize, lens: nil)
            return crop.width * crop.height
        }
        guard kept(self) < area else { return self }
        var (low, high) = (0.0, 1.0)
        for _ in 0 ..< 12 {
            let middle = (low + high) / 2
            if kept(scaled(middle)) >= area {
                low = middle
            } else {
                high = middle
            }
        }
        return scaled(low)
    }

    /// Each line's angle away from upright or level once `transform` applies.
    private static func residuals(of transform: Transform, _ lines: [UprightLine], canvas: PixelSize) -> [Double] {
        let matrix = transform.matrix(canvas: canvas)
        return lines.map { line in
            let pa = matrix * line.a, pb = matrix * line.b
            let dx = pb.x / pb.z - pa.x / pa.z, dy = pb.y / pb.z - pa.y / pa.z
            // The angle away from vertical or level, whichever way the line was drawn.
            let angle = line.vertical ? atan2(dx, dy) : atan2(dy, dx)
            return remainder(angle, .pi)
        }
    }

    private struct UprightLine {
        var a: SIMD3<Double>
        var b: SIMD3<Double>
        var vertical: Bool
        var weight: Double
    }

    private static func canvas(_ imageSize: PixelSize, _ orientation: ImageOrientation) -> PixelSize {
        orientation.swapsAxes ? PixelSize(width: imageSize.height, height: imageSize.width) : imageSize
    }

    /// The lines in the oriented photo, in pixels about its centre: what Transform maps.
    private static func uprightLines(
        _ lines: [DetectedLine], _ imageSize: PixelSize, _ orientation: ImageOrientation,
    ) -> [UprightLine] {
        let canvas = canvas(imageSize, orientation)
        let (w, h) = (Double(canvas.width), Double(canvas.height))
        return lines.compactMap { detected -> UprightLine? in
            func oriented(_ point: ImagePoint) -> SIMD3<Double> {
                let mapped = orientation.matrix * SIMD3(point.x, point.y, 1)
                return SIMD3((mapped.x / mapped.z - 0.5) * w, (mapped.y / mapped.z - 0.5) * h, 1)
            }
            let a = oriented(detected.line.start), b = oriented(detected.line.end)
            guard simd_distance(SIMD2(a.x, a.y), SIMD2(b.x, b.y)) > 1, detected.strength > 0 else { return nil }
            return UprightLine(a: a, b: b, vertical: abs(b.y - a.y) >= abs(b.x - a.x), weight: detected.strength)
        }
    }

    /// A few Levenberg–Marquardt steps on the lines' angles over the free sliders (Vertical,
    /// Horizontal, Rotate), damped towards the smallest correction, so two verticals don't
    /// invent a horizontal turn. Robust fits reweight each line by a Cauchy function of its
    /// residual (scale 1°), so lines that were never meant to be upright stop pulling.
    private func fitted(to lines: [UprightLine], free: [Bool], robust: Bool, canvas: PixelSize) -> Transform {
        guard !lines.isEmpty else { return self }
        func candidate(_ p: SIMD3<Double>) -> Transform {
            var transform = self
            transform.vertical = min(max(p.x, -100), 100)
            transform.horizontal = min(max(p.y, -100), 100)
            transform.rotate = min(max(p.z, -10), 10)
            return transform
        }
        func residuals(_ p: SIMD3<Double>) -> [Double] {
            Self.residuals(of: candidate(p), lines, canvas: canvas)
        }
        let scale = Double.pi / 180
        // Far below the lines' sensitivity (about 2e-4 radians per slider unit, squared), so it
        // only holds still what the lines don't determine.
        let damping = 1e-12
        var p = SIMD3(vertical, horizontal, rotate)
        for _ in 0 ..< 50 {
            let r = residuals(p)
            let weights = zip(lines, r).map { line, residual in
                line.weight * (robust ? 1 / (1 + (residual / scale) * (residual / scale)) : 1)
            }
            let step = 1e-3
            let columns = (0 ..< 3).map { axis -> [Double] in
                guard free[axis] else { return Array(repeating: 0, count: r.count) }
                var moved = p
                moved[axis] += step
                return zip(residuals(moved), r).map { ($0 - $1) / step }
            }
            // (JᵀWJ + λI) δ = −JᵀWr − λp: the damping also pulls towards no correction. Fixed
            // sliders get δ = 0.
            var normal = simd_double3x3(diagonal: SIMD3(repeating: damping))
            var gradient = -damping * p
            for i in 0 ..< 3 {
                guard free[i] else {
                    normal[i] = SIMD3(repeating: 0)
                    normal[i][i] = 1
                    gradient[i] = 0
                    continue
                }
                for j in 0 ..< 3 where free[j] {
                    normal[j][i] += zip(zip(columns[i], columns[j]), weights).map { $0.0 * $0.1 * $1 }.reduce(0, +)
                }
                gradient[i] -= zip(zip(columns[i], r), weights).map { $0.0 * $0.1 * $1 }.reduce(0, +)
            }
            let delta = normal.inverse * gradient
            p += delta
            if simd_length(delta) < 1e-7 {
                break
            }
        }
        return candidate(p)
    }
}
