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
/// photo (LNS-05): the crop with its angle, then Transform, then the user's orientation, to the
/// EXIF-oriented photo. Without lens correction this is a single homography, so the renderer
/// applies it per pixel and samples the pyramid once.
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
    public let isIdentity: Bool

    /// Vertical and Horizontal at ±100 tilt or turn the virtual camera this far.
    public static let maximumPerspective = 25.0

    public init(recipe: EditRecipe, imageSize: PixelSize, includesCrop: Bool = true) {
        self.init(
            imageSize: imageSize, orientation: recipe.orientation, crop: includesCrop ? recipe.crop : .full,
            angle: recipe[.cropAngle], transform: Transform(recipe: recipe),
        )
    }

    public init(
        imageSize: PixelSize,
        orientation: ImageOrientation = .identity,
        crop: CropRect = .full,
        angle: Double = 0,
        transform: Transform = Transform(),
    ) {
        self.imageSize = imageSize
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
    }

    /// The photo point behind an output point, or nil when it lies behind the virtual camera.
    public func imagePoint(_ output: SIMD2<Double>) -> SIMD2<Double>? {
        Self.project(toImage, output)
    }

    /// Where a photo point lands in the output, or nil.
    public func outputPoint(_ image: SIMD2<Double>) -> SIMD2<Double>? {
        Self.project(fromImage, image)
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

    /// Whether the whole output shows the photo, with no empty corners.
    public var staysInsideImage: Bool {
        [SIMD2(0.0, 0.0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)].allSatisfy { corner in
            guard let point = imagePoint(corner) else { return false }
            return point.x >= -1e-6 && point.y >= -1e-6 && point.x <= 1 + 1e-6 && point.y <= 1 + 1e-6
        }
    }

    /// The crop scaled about its centre until it stays inside the photo (Lightroom's Constrain to
    /// Image). The photo's outline under a homography is convex, so the corners decide.
    public static func constrained(
        _ crop: CropRect,
        imageSize: PixelSize,
        orientation: ImageOrientation,
        angle: Double,
        transform: Transform,
    ) -> CropRect {
        func fits(_ candidate: CropRect) -> Bool {
            GeometryMap(
                imageSize: imageSize, orientation: orientation, crop: candidate, angle: angle, transform: transform,
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
        .cropAngle, .transformVertical, .transformHorizontal, .transformRotate, .transformAspect,
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
