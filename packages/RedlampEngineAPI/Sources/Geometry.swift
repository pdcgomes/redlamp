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
/// lens distortion, to the EXIF-oriented photo as the camera recorded it. Up to the lens it is a
/// single homography; the lens adds one radial polynomial. The renderer applies both per pixel
/// and samples the pyramid once.
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
    public let isIdentity: Bool

    /// The Distortion slider at ±100.
    public static let maximumDistortion = 0.2

    /// Vertical and Horizontal at ±100 tilt or turn the virtual camera this far.
    public static let maximumPerspective = 25.0

    public init(recipe: EditRecipe, imageSize: PixelSize, includesCrop: Bool = true) {
        self.init(
            imageSize: imageSize, orientation: recipe.orientation, crop: includesCrop ? recipe.crop : .full,
            angle: recipe[.cropAngle], transform: Transform(recipe: recipe),
            lensDistortion: -recipe[.lensDistortion] / 100 * Self.maximumDistortion,
        )
    }

    public init(
        imageSize: PixelSize,
        orientation: ImageOrientation = .identity,
        crop: CropRect = .full,
        angle: Double = 0,
        transform: Transform = Transform(),
        lensDistortion: Double = 0,
    ) {
        self.imageSize = imageSize
        self.lensDistortion = lensDistortion
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
            && abs(lensDistortion) < 1e-12
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

    /// Where the camera recorded a lens-corrected photo point.
    func distorted(_ point: SIMD2<Double>) -> SIMD2<Double> {
        guard lensDistortion != 0 else { return point }
        let offset = (point - 0.5) * lensScale
        let scale = 1 + lensDistortion * simd_length_squared(offset)
        return 0.5 + (point - 0.5) * scale
    }

    /// The lens-corrected point the camera recorded at `point` (Newton on the radius).
    func undistorted(_ point: SIMD2<Double>) -> SIMD2<Double> {
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
        let steps = lensDistortion == 0 ? 1 : 8
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
    ) -> CropRect {
        func fits(_ candidate: CropRect) -> Bool {
            GeometryMap(
                imageSize: imageSize, orientation: orientation, crop: candidate, angle: angle, transform: transform,
                lensDistortion: lensDistortion,
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
    public static func constrained(_ crop: CropRect, recipe: EditRecipe, imageSize: PixelSize) -> CropRect {
        constrained(
            crop, imageSize: imageSize, orientation: recipe.orientation, angle: recipe[.cropAngle],
            transform: Transform(recipe: recipe),
            lensDistortion: -recipe[.lensDistortion] / 100 * maximumDistortion,
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
        .cropAngle, .lensDistortion, .transformVertical, .transformHorizontal, .transformRotate, .transformAspect,
        .transformScale, .transformOffsetX, .transformOffsetY,
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
        GeometryMap(recipe: self, imageSize: imageSize).outputSize
    }
}
