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

    public init() {}

    public mutating func setCameraToWorking(_ matrix: simd_float3x3) {
        (camToWork0, camToWork1, camToWork2) = Self.rows(matrix)
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

    public init(origin: SIMD4<Int32>, size: SIMD4<Int32>, a: SIMD4<Float>, b: SIMD4<Float>) {
        self.origin = origin
        self.size = size
        self.a = a
        self.b = b
    }
}

public struct SharpenParams {
    public var origin: SIMD4<Int32>
    public var size: SIMD4<Int32>
    public var luma: SIMD4<Float>
    public var shape: SIMD4<Float>

    public init(origin: SIMD4<Int32>, size: SIMD4<Int32>, luma: SIMD4<Float>, shape: SIMD4<Float>) {
        self.origin = origin
        self.size = size
        self.luma = luma
        self.shape = shape
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

public struct MaskComponentGPU: Sendable {
    public var geometry: SIMD4<Float>
    public var shape: SIMD4<Float>
    public var rotation: SIMD4<Float>

    public init(geometry: SIMD4<Float>, shape: SIMD4<Float>, rotation: SIMD4<Float>) {
        self.geometry = geometry
        self.shape = shape
        self.rotation = rotation
    }

    public static let empty = MaskComponentGPU(geometry: .zero, shape: .zero, rotation: .zero)
}

public struct MaskLayerGPU: Sendable {
    public var color: SIMD4<Float>
    public var tone: SIMD4<Float>
    public var tone2: SIMD4<Float>

    public init(color: SIMD4<Float>, tone: SIMD4<Float>, tone2: SIMD4<Float>) {
        self.color = color
        self.tone = tone
        self.tone2 = tone2
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
}
