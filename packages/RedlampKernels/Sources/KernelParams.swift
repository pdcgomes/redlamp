import simd

// Swift mirrors of the structs in Shaders/RedlampShaderTypes.h and Demosaic.metal.
// Field order and types must match exactly; every field is a 32-bit scalar or a
// 16-byte vector so no implicit padding differs between the two languages.

public struct CFAParams {
    public var width: UInt32
    public var height: UInt32
    public var channels: UInt32
    public var patternWidth: UInt32
    public var patternHeight: UInt32
    public var pad0: UInt32 = 0
    public var pad1: UInt32 = 0
    public var white: Float
    public var multipliers: SIMD4<Float>

    public init(
        width: UInt32,
        height: UInt32,
        channels: UInt32,
        patternWidth: UInt32,
        patternHeight: UInt32,
        white: Float,
        multipliers: SIMD4<Float>,
    ) {
        self.width = width
        self.height = height
        self.channels = channels
        self.patternWidth = patternWidth
        self.patternHeight = patternHeight
        self.white = white
        self.multipliers = multipliers
    }
}

public struct DemosaicParams {
    public var width: UInt32
    public var height: UInt32
    public var patternWidth: UInt32
    public var patternHeight: UInt32

    public init(width: UInt32, height: UInt32, patternWidth: UInt32, patternHeight: UInt32) {
        self.width = width
        self.height = height
        self.patternWidth = patternWidth
        self.patternHeight = patternHeight
    }
}

public struct HotPixelParams {
    public var width: UInt32
    public var height: UInt32
    public var patternWidth: UInt32
    public var patternHeight: UInt32
    public var threshold: Float
    public var ratio: Float
    public var pad1: Float = 0
    public var pad2: Float = 0
    public var a: SIMD4<Float>
    public var b: SIMD4<Float>

    public init(
        width: UInt32,
        height: UInt32,
        patternWidth: UInt32,
        patternHeight: UInt32,
        threshold: Float,
        ratio: Float,
        a: SIMD4<Float>,
        b: SIMD4<Float>,
    ) {
        self.width = width
        self.height = height
        self.patternWidth = patternWidth
        self.patternHeight = patternHeight
        self.threshold = threshold
        self.ratio = ratio
        self.a = a
        self.b = b
    }
}

public struct HighlightParams {
    public var width: UInt32
    public var height: UInt32
    public var patternWidth: UInt32
    public var patternHeight: UInt32
    public var clip: SIMD4<Float>

    public init(width: UInt32, height: UInt32, patternWidth: UInt32, patternHeight: UInt32, clip: SIMD4<Float>) {
        self.width = width
        self.height = height
        self.patternWidth = patternWidth
        self.patternHeight = patternHeight
        self.clip = clip
    }
}

public struct GainMapGPU {
    public var area: SIMD4<Int32>
    public var grid: SIMD4<Int32>
    public var placement: SIMD4<Float>
    public var planes: SIMD4<Int32>

    public init(area: SIMD4<Int32>, grid: SIMD4<Int32>, placement: SIMD4<Float>, planes: SIMD4<Int32>) {
        self.area = area
        self.grid = grid
        self.placement = placement
        self.planes = planes
    }
}

public struct HistogramParams {
    public var width: UInt32
    public var height: UInt32
    public var step: UInt32
    public var linearInput: UInt32

    public init(width: UInt32, height: UInt32, step: UInt32, linearInput: Bool) {
        self.width = width
        self.height = height
        self.step = step
        self.linearInput = linearInput ? 1 : 0
    }
}

public struct DevelopParams {
    public var camToWork0 = SIMD4<Float>(1, 0, 0, 0)
    public var camToWork1 = SIMD4<Float>(0, 1, 0, 0)
    public var camToWork2 = SIMD4<Float>(0, 0, 1, 0)
    public var displayToOutput0 = SIMD4<Float>(1, 0, 0, 0)
    public var displayToOutput1 = SIMD4<Float>(0, 1, 0, 0)
    public var displayToOutput2 = SIMD4<Float>(0, 0, 1, 0)
    public var wbRatio = SIMD4<Float>(1, 1, 1, 0)
    public var tone = SIMD4<Float>(1, 0, 0, 0)
    public var tone2 = SIMD4<Float>(1, 0, 0, 0)
    public var color = SIMD4<Float>(0, 1, 0, 0)
    public var look = SIMD4<Float>(0, 0, 0, 0)
    public var gradeShadows = SIMD4<Float>(0, 0, 0, 0)
    public var gradeMidtones = SIMD4<Float>(0, 0, 0, 0)
    public var gradeHighlights = SIMD4<Float>(0, 0, 0, 0)
    public var gradeGlobal = SIMD4<Float>(0, 0, 0, 0)
    public var gradeShape = SIMD4<Float>(0.5, 0, 0, 0)
    public var vignette = SIMD4<Float>(0, 0.5, 0, 0.5)
    public var grain = SIMD4<Float>(0, 0.25, 0.5, 0)
    public var geometry = SIMD4<Float>(0, 0, 0, 1)
    public var outputSize = SIMD4<Float>(0, 0, 1, 0)
    public var masks = SIMD4<Float>(0, -1, 0, 0)
    public var region = SIMD4<Float>(0, 0, 1, 1)
    public var denoised = SIMD4<Float>(0, 0, 0, 0)
    public var lookTable = SIMD4<Float>(0, 2, 0, 0)
    public var recipe = SIMD4<Float>(0, 0, 0, 0)
    public var haze = SIMD4<Float>(0, 0, 0, 0)
    public var glow = SIMD4<Float>(0, 0, 0, 0)
    public var grain2 = SIMD4<Float>(0, 0, 0, 0)
    public var render = SIMD4<Float>(0, 0, 0, 0)
    public var workToCam0 = SIMD4<Float>(1, 0, 0, 0)
    public var workToCam1 = SIMD4<Float>(0, 1, 0, 0)
    public var workToCam2 = SIMD4<Float>(0, 0, 1, 0)
    public var mood0 = SIMD4<Float>(0, 0, 0, 0)
    public var mood1 = SIMD4<Float>(0, 0, 0, 0)
    public var toImage0 = SIMD4<Float>(1, 0, 0, 1)
    public var toImage1 = SIMD4<Float>(0, 1, 0, 0)
    public var toImage2 = SIMD4<Float>(0, 0, 1, 0)
    public var lens = SIMD4<Float>(0, 0, 0.5, 0)
    public var hueSat = SIMD4<Float>(0, 1, 0, 0)
    public var toProPhoto0 = SIMD4<Float>(1, 0, 0, 0)
    public var toProPhoto1 = SIMD4<Float>(0, 1, 0, 0)
    public var toProPhoto2 = SIMD4<Float>(0, 0, 1, 0)
    public var fromProPhoto0 = SIMD4<Float>(1, 0, 0, 0)
    public var fromProPhoto1 = SIMD4<Float>(0, 1, 0, 0)
    public var fromProPhoto2 = SIMD4<Float>(0, 0, 1, 0)
    public var lensProfile = SIMD4<Float>(0, 0.5, 0.5, 0)
    public var lensProfile2 = SIMD4<Float>(1, 1, 1, 0)
    public var defringe = SIMD4<Float>(0, 0, 0, 0)
    public var defringeHue = SIMD4<Float>(0, 0, 0, 0)

    public init() {}

    /// The output frame to the photo (see `GeometryMap.toImage`), and the photo's aspect.
    public mutating func setOutputToImage(_ matrix: simd_float3x3, imageAspect: Float) {
        (toImage0, toImage1, toImage2) = Self.rows(matrix)
        toImage0.w = imageAspect
    }

    public mutating func setCameraToWorking(_ matrix: simd_float3x3) {
        (camToWork0, camToWork1, camToWork2) = Self.rows(matrix)
        (workToCam0, workToCam1, workToCam2) = Self.rows(matrix.inverse)
    }

    /// Working space to the space camera profiles' HueSatMaps work in.
    public mutating func setWorkingToProPhoto(_ matrix: simd_float3x3) {
        (toProPhoto0, toProPhoto1, toProPhoto2) = Self.rows(matrix)
        (fromProPhoto0, fromProPhoto1, fromProPhoto2) = Self.rows(matrix.inverse)
    }

    public mutating func setDisplayToOutput(_ matrix: simd_float3x3) {
        (displayToOutput0, displayToOutput1, displayToOutput2) = Self.rows(matrix)
    }

    private static func rows(_ m: simd_float3x3) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let t = m.transpose
        return (
            SIMD4(t.columns.0, 0),
            SIMD4(t.columns.1, 0),
            SIMD4(t.columns.2, 0),
        )
    }
}

public struct DenoiseParams {
    public var origin: SIMD4<Int32>
    public var size: SIMD4<Int32>
    public var scale = SIMD4<Int32>(1, 0, 0, 0)
    public var a: SIMD4<Float>
    public var b: SIMD4<Float>
    public var threshold = SIMD4<Float>(0, 0, 0, 0)
    public var edge = SIMD4<Float>(0, 0, 0, 0)
    public var nonLocal = SIMD4<Float>(0, 0, 0, 0)

    public init(origin: SIMD4<Int32>, size: SIMD4<Int32>, a: SIMD4<Float>, b: SIMD4<Float>) {
        self.origin = origin
        self.size = size
        self.a = a
        self.b = b
    }
}

public struct StackWarpParams {
    /// a, b, tx, ty: output (reference) pixel to source pixel.
    public var transform: SIMD4<Float>
    /// Per-channel gain to the reference's brightness.
    public var gain: SIMD4<Float>
    /// xy output size, zw source size.
    public var size: SIMD4<Int32>

    public init(transform: SIMD4<Float>, gain: SIMD4<Float>, size: SIMD4<Int32>) {
        self.transform = transform
        self.gain = gain
        self.size = size
    }
}

public struct StackFuseParams {
    /// x frame index (or a scale factor), y Auto window in frames, z Auto release ratio on root
    /// salience, w grit level on root salience.
    public var frame: SIMD4<Float>
    /// x level selects per coefficient, y level suppresses grit, z first frame.
    public var flags: SIMD4<Int32>

    public init(frame: SIMD4<Float>, flags: SIMD4<Int32> = .zero) {
        self.frame = frame
        self.flags = flags
    }
}

public struct SharpenParams {
    public var origin: SIMD4<Int32>
    public var size: SIMD4<Int32>
    public var luma: SIMD4<Float>
    public var shape: SIMD4<Float>
    /// x Detail's share of deconvolution, y Richardson-Lucy step (0 ratio, 1 update), z source softening available.
    public var deconvolution: SIMD4<Float>

    public init(
        origin: SIMD4<Int32>, size: SIMD4<Int32>, luma: SIMD4<Float>, shape: SIMD4<Float>,
        deconvolution: SIMD4<Float> = .zero,
    ) {
        self.origin = origin
        self.size = size
        self.luma = luma
        self.shape = shape
        self.deconvolution = deconvolution
    }
}

public struct LocalContrastParams {
    public var origin: SIMD4<Int32>
    public var size: SIMD4<Int32>
    public var place: SIMD4<Int32>
    public var levels: SIMD4<Int32>
    public var luma: SIMD4<Float>
    public var shape: SIMD4<Float>

    public init(
        origin: SIMD4<Int32>,
        size: SIMD4<Int32>,
        place: SIMD4<Int32>,
        levels: SIMD4<Int32>,
        luma: SIMD4<Float>,
        shape: SIMD4<Float>,
    ) {
        self.origin = origin
        self.size = size
        self.place = place
        self.levels = levels
        self.luma = luma
        self.shape = shape
    }
}

public struct DetailLocalParams {
    public var place: SIMD4<Int32>
    public var size: SIMD4<Int32>
    public var geometry: SIMD4<Float>

    public init(place: SIMD4<Int32>, size: SIMD4<Int32>, geometry: SIMD4<Float>) {
        self.place = place
        self.size = size
        self.geometry = geometry
    }
}

public struct GlowParams {
    public var size: SIMD4<Int32>
    public var shape: SIMD4<Float>

    public init(size: SIMD4<Int32>, shape: SIMD4<Float>) {
        self.size = size
        self.shape = shape
    }
}

public struct HazeParams {
    public var size: SIMD4<Int32>
    public var mode = SIMD4<Int32>(0, 0, 0, 0)
    public var airlight: SIMD4<Float>

    public init(size: SIMD4<Int32>, airlight: SIMD4<Float>) {
        self.size = size
        self.airlight = airlight
    }
}

public struct MaskComponentGPU: Sendable {
    public var geometry: SIMD4<Float>
    public var shape: SIMD4<Float>
    public var rotation: SIMD4<Float>
    public var extra0: SIMD4<Float> = .zero
    public var extra1: SIMD4<Float> = .zero
    public var extra2: SIMD4<Float> = .zero
    public var extra3: SIMD4<Float> = .zero

    public init(geometry: SIMD4<Float>, shape: SIMD4<Float>, rotation: SIMD4<Float>) {
        self.geometry = geometry
        self.shape = shape
        self.rotation = rotation
    }

    public static let empty = MaskComponentGPU(geometry: .zero, shape: .zero, rotation: .zero)
}

public struct MaskRasterParams {
    public var box: SIMD4<Int32>
    public var info: SIMD4<Int32>
    public var brush: SIMD4<Float>
    public var raster: SIMD4<Float>

    public init(box: SIMD4<Int32>, info: SIMD4<Int32>, brush: SIMD4<Float> = .zero, raster: SIMD4<Float>) {
        self.box = box
        self.info = info
        self.brush = brush
        self.raster = raster
    }
}

public struct MaskLayerGPU: Sendable {
    public var color: SIMD4<Float>
    public var tone: SIMD4<Float>
    public var tone2: SIMD4<Float>
    public var detail: SIMD4<Float>
    public var glow: SIMD4<Float>

    public init(
        color: SIMD4<Float>, tone: SIMD4<Float>, tone2: SIMD4<Float>, detail: SIMD4<Float> = .zero,
        glow: SIMD4<Float> = .zero,
    ) {
        self.color = color
        self.tone = tone
        self.tone2 = tone2
        self.detail = detail
        self.glow = glow
    }

    public static let empty = MaskLayerGPU(color: .zero, tone: .zero, tone2: .zero)
}

/// The output encodings understood by `rl_develop`.
public enum OutputEncoding: Float {
    /// Linear values in the output primaries (for an extended-linear CAMetalLayer).
    case linear = 0
    /// sRGB-encoded sRGB.
    case sRGB = 1
    /// sRGB-encoded (Display P3 transfer) Display P3.
    case displayP3 = 2
    /// Linear values in sRGB primaries (for downscaling an sRGB export before encoding it).
    case linearSRGB = 3
    /// OKLab of the Rec.2020 result, for the guides range masks and Auto Mask select on.
    case okLab = 4
}
