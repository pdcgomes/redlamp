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

    /// The refined map's guided-filter window, as a multiple of the patch radius.
    /// REDLAMP_HAZE_RADIUS overrides it, to tune.
    static let refinedRadiusFactor = Float(ProcessInfo.processInfo.environment["REDLAMP_HAZE_RADIUS"] ?? "") ?? 8
    /// The refined map's edge threshold, as a variance of the guide (brightness over the
    /// airlight). REDLAMP_HAZE_EPSILON overrides it, to tune.
    static let refinedEpsilon = Float(ProcessInfo.processInfo.environment["REDLAMP_HAZE_EPSILON"] ?? "") ?? 1e-3

    /// The veil negative Dehaze adds from process 18: the airlight's brightness in a neutral colour
    /// tinted a little cool, as scattered light is. Lightroom's veil is nearly the same colour over
    /// an overcast park, a tungsten-lit bookshelf and a blue foggy road (red over green 0.95 to 0.96
    /// in Display P3), where the scenes' own airlights differ; a veil that followed the fog's blue
    /// swung skin 27° toward magenta at -50 where Lightroom's moved 5°.
    static let veilTint = SIMD3<Float>(0.96, 1, 1.03)

    /// The veil for a scene whose airlight (pyramid camera RGB) is `airlight`.
    static func veil(airlight: SIMD3<Float>) -> SIMD3<Float> {
        max((airlight.x + airlight.y + airlight.z) / 3, 1e-4) * veilTint
    }

    /// How much haze negative Dehaze adds from process 18: the share of the way to the veil is
    /// `1 - exp(-a^exponent * (floor + scale * h))` at the slider's amount `a` (0...1), where `h` is
    /// the added-haze map (`added`) times the veil's brightness in the scene's light (white balance
    /// and exposure applied) to the power `light`. Lightroom's haze reads this way: per pixel, its
    /// -100 is the base blended toward one veil colour, and how far follows the dark channel blurred
    /// over a tenth of the frame (R² 0.85 to 0.95 over a park, a bookshelf, a foggy road and sunlit
    /// blocks of flats) and hardly the pixel's own brightness. The map is relative to the airlight, so
    /// it reads a foggy road, whose airlight is the dim fog, as hazier than Lightroom does, and a
    /// sunlit field, under a bright sky, as clearer; the veil's own light puts them back in step.
    /// The response grows with the amount as `a^1.3`, so -25 and -50 fog as lightly as Lightroom's.
    /// Chosen against Lightroom's 16-bit exports, each app against its own 0, by the change in Oklab
    /// lightness and the chroma kept: the park lifts 0.064, 0.136 and 0.248 at -25, -50 and -100
    /// (Lightroom 0.064, 0.132 and 0.262), the sunlit blocks 0.164 at -100 (0.162), the foggy road
    /// 0.035, 0.076 and 0.112 at -25, -50 and -75 (0.043, 0.090 and 0.138, keeping 0.51 of its
    /// chroma against 0.49), the bookshelf 0.158 at -100 (0.212).
    static let addedHaze: (floor: Float, scale: Float, exponent: Float, light: Float) = (0.03, 7.5, 1.3, 0.7)

    /// How negative Dehaze's veil is blended from process 18: in the scene's light compressed by
    /// `v / (v + compression)`, so shadows lift as they would in linear light while a bright sky's
    /// highlights take less (blended linearly, the park's bright veil fogged it 1.3 times as thickly
    /// as the others against Lightroom; compressed harder, near grass turned milky where Lightroom's
    /// keeps its contrast); `greying` of the way to the blend's own luminance at -100, in proportion
    /// to the haze added, as Lightroom's greys a blue sky; and at most `ceiling` of the way.
    static let veilBlend: (compression: Float, greying: Float, ceiling: Float) = (1, 0.3, 0.97)

    /// The refined map's guide: a pixel's brightness relative to the airlight. The develop kernel
    /// computes it the same way.
    static func guide(_ rgb: SIMD3<Float>, airlight: SIMD3<Float>) -> Float {
        simd_reduce_add(rgb / airlight) / 3
    }

    /// The refined haze map (process 8, TON-27): the patch-minimum dark channel guided by the
    /// photo's brightness, so the haze follows the photo's edges instead of spreading a dark
    /// object's low haze a patch-width into the sky beside it. Per texel, the haze is
    /// `min(a * guide + b, ceiling)` with the pixel's own guide.
    struct Refined {
        let coefficients: GuidedMap
        /// The patch minimum's opening by reconstruction: each region grows back from the patch
        /// minimum as far as its own blocks' darkest channel allows, so the sky beside a dark
        /// object, even around a narrow tip, gets its own haze back, and the object keeps its
        /// own. A bright object beside the sky, which the guide alone would take for haze, can't
        /// have more than its own.
        let ceiling: [Float]

        /// As a texture (a, b, ceiling) for the develop kernel.
        func texture(device: any MTLDevice) throws -> any MTLTexture {
            try coefficients.texture(device: device, third: ceiling)
        }
    }

    /// The refined map from the coarse map's blocks (`encodeMap`).
    static func refined(blocks: any MTLTexture) -> Refined {
        let width = blocks.width
        let height = blocks.height
        let texels = blockTexels(blocks)
        return refined(
            dark: (0 ..< width * height).map { texels[$0 * 4] },
            guide: (0 ..< width * height).map { texels[$0 * 4 + 1] },
            width: width, height: height,
        )
    }

    /// The blocks' texels: per block, its darkest channel, its mean brightness and its pixels'
    /// mean dark channel, relative to the airlight, and a spare.
    private static func blockTexels(_ blocks: any MTLTexture) -> [Float] {
        var texels = [Float](repeating: 0, count: blocks.width * blocks.height * 4)
        texels.withUnsafeMutableBytes { bytes in
            blocks.getBytes(
                bytes.baseAddress!, bytesPerRow: blocks.width * 16,
                from: MTLRegionMake2D(0, 0, blocks.width, blocks.height), mipmapLevel: 0,
            )
        }
        return texels
    }

    /// The added-haze map's dark channel: the blocks' mean dark channel, its minimum over `patch`
    /// blocks around (five by five, about 70 pixels of a 24-megapixel frame), so the gaps in grass
    /// or between books don't read as clear, and blurred by a Gaussian of `sigma` of the map's short
    /// edge. Without the minimum, sunlit grass read as half as hazy as the sky above it and fogged
    /// white; a pixel's own darkest channel in place of the blocks' mean read texture as clear.
    static let addedMap: (patch: Int, sigma: Float) = (2, 0.1)

    /// The added-haze map (process 18): where negative Dehaze adds haze, 0 clear to 1 as hazy as the
    /// airlight, smooth over the frame as Lightroom's is, guided by the photo's brightness over two
    /// blocks so it upsamples without blocks along a strong edge.
    static func added(blocks: any MTLTexture) -> GuidedMap {
        let width = blocks.width
        let height = blocks.height
        let texels = blockTexels(blocks)
        return added(
            haze: (0 ..< width * height).map { texels[$0 * 4 + 2] },
            guide: (0 ..< width * height).map { texels[$0 * 4 + 1] },
            width: width, height: height,
        )
    }

    /// The same from each block's mean dark channel and mean brightness, relative to the airlight.
    static func added(haze: [Float], guide: [Float], width: Int, height: Int) -> GuidedMap {
        let rows = minimum(haze, width: width, height: height, radius: addedMap.patch, alongRows: true)
        let dark = minimum(rows, width: width, height: height, radius: addedMap.patch, alongRows: false)
        let sigma = max(addedMap.sigma * Float(min(width, height)), 0.5)
        let map = DustDetector.blur(dark, width: width, height: height, sigma: sigma)
        return GuidedMap(input: map, guide: guide, width: width, height: height, radius: 2, epsilon: 0.01)
    }

    /// The same from each block's darkest channel and mean brightness, relative to the airlight.
    static func refined(dark blockDark: [Float], guide: [Float], width: Int, height: Int) -> Refined {
        let patchRadius = max(1, Int(Double(max(width, height)) * patchFraction / 2))
        func patchMinimum(_ values: [Float]) -> [Float] {
            let rows = minimum(values, width: width, height: height, radius: patchRadius, alongRows: true)
            return minimum(rows, width: width, height: height, radius: patchRadius, alongRows: false)
        }
        let dark = patchMinimum(blockDark)
        let radius = max(1, Int((Float(patchRadius) * refinedRadiusFactor).rounded()))
        return Refined(
            coefficients: GuidedMap(
                input: dark, guide: guide, width: width, height: height, radius: radius, epsilon: refinedEpsilon,
            ),
            ceiling: reconstruction(of: dark, under: blockDark, width: width, height: height),
        )
    }

    /// Grayscale reconstruction by dilation (L. Vincent, "Morphological grayscale reconstruction
    /// in image analysis", 1993): `marker` grown through its 8 neighbours, never above `mask`,
    /// until it stops changing; forward and backward raster passes.
    static func reconstruction(of marker: [Float], under mask: [Float], width: Int, height: Int) -> [Float] {
        var result = zip(marker, mask).map { min($0, $1) }
        var changed = true
        while changed {
            changed = false
            for backward in [false, true] {
                for row in 0 ..< height {
                    let y = backward ? height - 1 - row : row
                    for column in 0 ..< width {
                        let x = backward ? width - 1 - column : column
                        var largest = result[y * width + x]
                        let dy = backward ? 1 : -1
                        for (nx, ny) in [(x - 1, y + dy), (x, y + dy), (x + 1, y + dy), (backward ? x + 1 : x - 1, y)]
                            where nx >= 0 && nx < width && ny >= 0 && ny < height {
                            largest = max(largest, result[ny * width + nx])
                        }
                        let grown = min(largest, mask[y * width + x])
                        if grown > result[y * width + x] {
                            result[y * width + x] = grown
                            changed = true
                        }
                    }
                }
            }
        }
        return result
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
    /// smoothed so it upsamples without blocks. `blocks` keeps each texel's own darkest channel and
    /// mean brightness, for the refined map, and its pixels' mean dark channel, for the added-haze map.
    static func encodeMap(
        pyramid: any MTLTexture,
        airlight: SIMD3<Float>,
        device: any MTLDevice,
        kernels: KernelLibrary,
        commands: any MTLCommandBuffer,
    ) throws -> (map: any MTLTexture, blocks: any MTLTexture) {
        let block = max(1, Int((Double(max(pyramid.width, pyramid.height)) / Double(mapLongEdge)).rounded(.up)))
        let width = (pyramid.width + block - 1) / block
        let height = (pyramid.height + block - 1) / block
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: width, height: height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let blocksDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false,
        )
        blocksDescriptor.usage = [.shaderRead, .shaderWrite]
        blocksDescriptor.storageMode = .shared
        guard let map = device.makeTexture(descriptor: descriptor),
              let scratch = device.makeTexture(descriptor: descriptor),
              let blocks = device.makeTexture(descriptor: blocksDescriptor),
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
        dispatch(kernels.hazeDark, pyramid, blocks)
        for (mode, radius) in [(Int32(0), Int32(patchRadius)), (1, 9)] {
            params.size.w = radius
            params.mode = SIMD4(mode, 0, 0, 0)
            dispatch(kernels.hazeFilter, mode == 0 ? blocks : map, scratch)
            params.mode = SIMD4(mode, 1, 0, 0)
            dispatch(kernels.hazeFilter, scratch, map)
        }
        encoder.endEncoding()
        return (map, blocks)
    }
}
