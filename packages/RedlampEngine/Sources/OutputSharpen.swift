import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels

/// The last step of a downscaled export: linear light to the sRGB curve, sharpened for the screen
/// when asked (`OutputSharpen.metal`, EDT-28).
enum OutputSharpen {
    /// The Gaussian's sigma in output pixels; its 3 × 3 cut keeps all but 0.5% of its weight.
    static let sigma: Float = 0.6

    /// Encodes `linear` into `output`, which is the same size; `.off` is today's plain encode.
    static func encode(
        _ linear: any MTLTexture,
        into output: any MTLTexture,
        sharpening: OutputSharpening,
        colorSpace: OutputColorSpace,
        kernels: KernelLibrary,
        commands: any MTLCommandBuffer,
    ) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        if sharpening == .off {
            encoder.setComputePipelineState(kernels.encodeSRGB)
            encoder.setTexture(linear, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.dispatchGrid(width: output.width, height: output.height, pipeline: kernels.encodeSRGB)
        } else {
            encoder.label = "Output sharpening"
            let side = exp(-1 / (2 * sigma * sigma))
            let total = (1 + 2 * side) * (1 + 2 * side)
            var params = OutputSharpenParams(
                size: SIMD4(Int32(output.width), Int32(output.height), 0, 0),
                shape: SIMD4(sharpening.amount, 1 / total, side / total, side * side / total),
                luma: lumaWeights(colorSpace),
            )
            encoder.setComputePipelineState(kernels.encodeSRGBSharpened)
            encoder.setTexture(linear, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<OutputSharpenParams>.stride, index: 0)
            encoder.dispatchGrid(width: output.width, height: output.height, pipeline: kernels.encodeSRGBSharpened)
        }
        encoder.endEncoding()
    }

    /// The output primaries' luminance weights (the Y row of their RGB to XYZ matrix).
    static func lumaWeights(_ colorSpace: OutputColorSpace) -> SIMD4<Float> {
        switch colorSpace {
        case .sRGB: SIMD4(0.2126, 0.7152, 0.0722, 0)
        case .displayP3: SIMD4(0.228_975, 0.691_739, 0.079_287, 0)
        }
    }
}
