import Foundation
import RedlampEngineAPI
import simd

/// Lightroom's crop (`crs:HasCrop`, `crs:CropLeft` … `crs:CropAngle`). Lightroom keeps it in the
/// photo's pixels as the file stores them, before the camera's orientation: (`left`, `top`) is
/// the crop's upper-left corner and (`right`, `bottom`) its lower-right, each 0...1 across those
/// pixels, and the crop is turned clockwise by `angle` degrees about its centre (John R. Ellis,
/// "SDK: Computing the corners of a crop rectangle", Adobe Community, 2022).
public struct LightroomCrop: Sendable, Hashable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var angle: Double
    /// Constrain to Image (`crs:CropConstrainToWarp`), which Redlamp keeps as a setting of the
    /// Crop tool rather than of the edit.
    public var constrainsToImage: Bool

    public init(
        left: Double,
        top: Double,
        right: Double,
        bottom: Double,
        angle: Double = 0,
        constrainsToImage: Bool = false,
    ) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.angle = angle
        self.constrainsToImage = constrainsToImage
    }

    /// The crop and its angle in Redlamp's terms (`EditRecipe.crop`, `ParameterID.cropAngle`) for
    /// a photo of `imageSize` after the camera's orientation (as `GeometryMap.imageSize`), which
    /// `cameraOrientation` turned from its stored pixels (LibRaw's orientation 6 is one quarter
    /// turn clockwise, 3 two and 5 three), in an edit turned by `orientation`. Nil when the
    /// corners don't make a crop.
    public func redlamp(
        imageSize: PixelSize,
        cameraOrientation: ImageOrientation = .identity,
        orientation: ImageOrientation = .identity,
    ) -> (crop: CropRect, angle: Double)? {
        func swapped(_ size: PixelSize) -> PixelSize {
            PixelSize(width: size.height, height: size.width)
        }
        let stored = cameraOrientation.swapsAxes ? swapped(imageSize) : imageSize
        let canvas = orientation.swapsAxes ? swapped(imageSize) : imageSize
        let storedScale = SIMD2(Double(stored.width), Double(stored.height))
        let canvasScale = SIMD2(Double(canvas.width), Double(canvas.height))
        // The turn is a rotation in pixels, not in 0...1 units.
        let size = Self.turned((SIMD2(right, bottom) - SIMD2(left, top)) * storedScale, by: -angle)
        guard size.x > 0, size.y > 0 else { return nil }

        let centre = orientation.matrix * cameraOrientation.matrix * SIMD3((left + right) / 2, (top + bottom) / 2, 1)
        let quarterTurns = cameraOrientation.quarterTurns + orientation.quarterTurns
        let upright = quarterTurns % 2 == 1 ? SIMD2(size.y, size.x) : size
        // A mirror turns the crop the other way. Redlamp turns the photo clockwise under an
        // upright crop, which turns the crop anticlockwise over the photo: against Lightroom's.
        let mirrored = cameraOrientation.mirrored != orientation.mirrored
        let turn = mirrored ? angle : -angle
        // The straightened frame is the canvas turned by the angle about its centre.
        let framed = Self.turned((SIMD2(centre.x, centre.y) - 0.5) * canvasScale, by: turn) / canvasScale + 0.5
        let half = upright / canvasScale / 2
        let crop = CropRect(
            left: framed.x - half.x, top: framed.y - half.y, right: framed.x + half.x, bottom: framed.y + half.y,
        )
        return (crop, ParameterID.cropAngle.spec.clamp(turn))
    }

    /// `vector` turned by `degrees`, clockwise on screen (y down).
    static func turned(_ vector: SIMD2<Double>, by degrees: Double) -> SIMD2<Double> {
        let radians = degrees * .pi / 180
        return SIMD2(
            cos(radians) * vector.x - sin(radians) * vector.y,
            sin(radians) * vector.x + cos(radians) * vector.y,
        )
    }
}

extension LightroomCrop {
    /// The preset's crop, when it has one (`crs:HasCrop`).
    init?(_ settings: CameraRawSettings) {
        guard settings.flag("HasCrop") == true else { return nil }
        self.init(
            left: settings.number("CropLeft") ?? 0,
            top: settings.number("CropTop") ?? 0,
            right: settings.number("CropRight") ?? 1,
            bottom: settings.number("CropBottom") ?? 1,
            angle: settings.number("CropAngle") ?? 0,
            constrainsToImage: settings.flag("CropConstrainToWarp") ?? false,
        )
    }
}
