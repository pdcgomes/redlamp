import Foundation
import RedlampEngineAPI

/// The repeating color-filter layout of a sensor. Colors are 0 = red, 1 = green, 2 = blue.
public struct CFAPattern: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let colors: [UInt8]

    public init(width: Int, height: Int, colors: [UInt8]) {
        precondition(colors.count == width * height)
        self.width = width
        self.height = height
        self.colors = colors
    }

    public func color(x: Int, y: Int) -> UInt8 {
        colors[(y % height) * width + (x % width)]
    }

    public var description: String {
        if width == 6 {
            return "X-Trans"
        }
        let letters = colors.map { ["R", "G", "B"][Int($0)] }.joined()
        return "Bayer \(letters)"
    }
}

/// Sensor data ready for upload to the GPU, plus the calibration needed to develop it.
public struct DecodedImage: Sendable {
    public enum Layout: Sendable {
        /// One `UInt16` sample per pixel behind a color filter array.
        case mosaic(CFAPattern)
        /// Three `UInt16` samples per pixel (linear DNG, e.g. ProRAW).
        case linearRGB
        /// Four float16 samples per pixel (RGBA), linear sRGB. Bitmap files.
        case linearSRGBHalf
    }

    public let width: Int
    public let height: Int
    public let layout: Layout
    /// Raw samples; float16 bit patterns for `.linearSRGBHalf`.
    public let samples: [UInt16]
    /// Black level per CFA position (or per channel for linear RGB).
    public let blackLevels: [Float]
    public let whiteLevel: Float
    /// Camera white-balance multipliers as shot, green = 1.
    public let asShotMultipliers: SIMD3<Double>
    /// Row-major camera RGB → linear sRGB (D65), for white-balanced camera data.
    public let cameraToSRGB: [Double]
    /// Row-major XYZ → camera RGB, when the camera is calibrated.
    public let xyzToCamera: [Double]?
    /// LibRaw orientation code: 0, 3 (180°), 5 (90° CCW) or 6 (90° CW).
    public let orientation: Int
    /// DNG BaselineExposure, in stops.
    public let baselineExposure: Double
    public let info: ImageInfo

    public init(
        width: Int,
        height: Int,
        layout: Layout,
        samples: [UInt16],
        blackLevels: [Float],
        whiteLevel: Float,
        asShotMultipliers: SIMD3<Double>,
        cameraToSRGB: [Double],
        xyzToCamera: [Double]?,
        orientation: Int,
        baselineExposure: Double,
        info: ImageInfo,
    ) {
        self.width = width
        self.height = height
        self.layout = layout
        self.samples = samples
        self.blackLevels = blackLevels
        self.whiteLevel = whiteLevel
        self.asShotMultipliers = asShotMultipliers
        self.cameraToSRGB = cameraToSRGB
        self.xyzToCamera = xyzToCamera
        self.orientation = orientation
        self.baselineExposure = baselineExposure
        self.info = info
    }

    public var isRaw: Bool {
        if case .linearSRGBHalf = layout {
            return false
        }
        return true
    }

    /// Size after orientation.
    public var orientedSize: PixelSize {
        orientation == 5 || orientation == 6
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
    }
}

public enum ImageDecoder {
    /// Decodes a raw or bitmap file.
    public static func decode(_ url: URL) throws -> DecodedImage {
        if SupportedFormats.isRaw(url) {
            return try RawDecoder.decode(url)
        }
        return try BitmapDecoder.decode(url)
    }
}
