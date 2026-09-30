import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd

/// Dehaze's per-session data: the airlight and the haze map, from the dark channel prior (K. He,
/// J. Sun & X. Tang, "Single image haze removal using dark channel prior", CVPR 2009). Both are
/// in the pyramid's camera RGB, so Dehaze applies before white balance and exposure.
enum Haze {
    /// The haze map's long edge, in texels.
    static let mapLongEdge = 512
    /// The dark channel's patch, as a fraction of the image's long edge.
    static let patchFraction = 0.025

    /// The airlight: among the 0.1% of unclipped pixels with the haziest dark channel, the mean
    /// colour of the brightest tenth. Clipped (or rebuilt) highlights don't show the haze's colour.
    static func airlight(_ image: AnalysisImage) -> SIMD3<Float> {
        let step = 2
        let width = max(1, image.width / step)
        let height = max(1, image.height / step)
        let colours = (0 ..< width * height).map { index in
            image.pixel(x: (index % width) * step, y: (index / width) * step)
        }
        var dark = colours.map { $0.min() }
        let radius = max(1, Int(Double(max(width, height)) * patchFraction / 2))
        dark = minimum(dark, width: width, height: height, radius: radius, alongRows: true)
        dark = minimum(dark, width: width, height: height, radius: radius, alongRows: false)
        let unclipped = dark.indices.filter { colours[$0].max() < 0.95 }
        let candidates = unclipped.isEmpty ? Array(dark.indices) : unclipped
        let haziest = candidates.sorted { dark[$0] > dark[$1] }.prefix(max(1, candidates.count / 1000))
        let brightest = haziest.sorted { colours[$0].sum() > colours[$1].sum() }.prefix(max(1, haziest.count / 10))
        let mean = brightest.map { colours[$0] }.reduce(SIMD3<Float>.zero, +) / Float(brightest.count)
        return simd_max(mean, SIMD3(repeating: 1e-3))
    }

    private static func minimum(
        _ values: [Float],
        width: Int,
        height: Int,
        radius: Int,
        alongRows: Bool,
    ) -> [Float] {
        var result = values
        for y in 0 ..< height {
            for x in 0 ..< width {
                var darkest = Float.greatestFiniteMagnitude
                for i in -radius ... radius {
                    let qx = alongRows ? min(max(x + i, 0), width - 1) : x
                    let qy = alongRows ? y : min(max(y + i, 0), height - 1)
                    darkest = min(darkest, values[qy * width + qx])
                }
                result[y * width + x] = darkest
            }
        }
        return result
    }

    /// The haze map: per texel, the darkest channel relative to the airlight over a patch, then
    /// smoothed so it upsamples without blocks.
    static func encodeMap(
        pyramid: any MTLTexture,
        airlight: SIMD3<Float>,
        device: any MTLDevice,
        kernels: KernelLibrary,
        commands: any MTLCommandBuffer,
    ) throws -> any MTLTexture {
        let block = max(1, Int((Double(max(pyramid.width, pyramid.height)) / Double(mapLongEdge)).rounded(.up)))
        let width = (pyramid.width + block - 1) / block
        let height = (pyramid.height + block - 1) / block
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: width, height: height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let map = device.makeTexture(descriptor: descriptor),
              let scratch = device.makeTexture(descriptor: descriptor),
              let encoder = commands.makeComputeCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }
        encoder.label = "Haze map"
        let patchRadius = max(1, Int(Double(max(width, height)) * patchFraction / 2))
        var params = HazeParams(
            size: SIMD4(Int32(width), Int32(height), Int32(block), Int32(patchRadius)),
            airlight: SIMD4(airlight, 3),
        )
        func dispatch(_ pipeline: any MTLComputePipelineState, _ input: any MTLTexture, _ output: any MTLTexture) {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<HazeParams>.stride, index: 0)
            encoder.dispatchGrid(width: width, height: height, pipeline: pipeline)
        }
        dispatch(kernels.hazeDark, pyramid, map)
        for (mode, radius) in [(Int32(0), Int32(patchRadius)), (1, 9)] {
            params.size.w = radius
            params.mode = SIMD4(mode, 0, 0, 0)
            dispatch(kernels.hazeFilter, map, scratch)
            params.mode = SIMD4(mode, 1, 0, 0)
            dispatch(kernels.hazeFilter, scratch, map)
        }
        encoder.endEncoding()
        return map
    }
}
