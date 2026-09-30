import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd

/// The Detail panel's noise sliders in rendering units: per à-trous scale, how many noise
/// sigmas of luma and chroma detail to remove.
struct DenoiseSettings: Hashable {
    static let scaleCount = 5

    var thresholds: [SIMD3<Float>]

    var isActive: Bool {
        thresholds.contains { $0 != .zero }
    }

    init(recipe: EditRecipe) {
        let luma = Float(recipe[.noiseLuminance] / 100)
        let lumaDetail = Float(recipe[.noiseLuminanceDetail] / 100)
        let lumaContrast = Float(recipe[.noiseLuminanceContrast] / 100)
        let chroma = Float(recipe[.noiseColor] / 100)
        let chromaDetail = Float(recipe[.noiseColorDetail] / 100)
        let smoothness = Float(recipe[.noiseColorSmoothness] / 100)
        thresholds = (0 ..< Self.scaleCount).map { scale in
            // Detail keeps the finest scales; Contrast keeps the coarser ones.
            let lumaShape = scale < 2 ? 1.4 - 0.8 * lumaDetail : 1 - 0.6 * lumaContrast
            // Color Detail keeps thin color edges; Smoothness reaches into the coarse mottling.
            let chromaShape: Float = scale < 2 ? 1.4 - 0.8 * chromaDetail : scale >= 3 ? 0.5 + smoothness : 1
            let l = 2.5 * luma * lumaShape
            let c = 6 * chroma * chromaShape
            return SIMD3(l, c, c)
        }
    }
}

/// The Detail panel's sharpening sliders in rendering units. Sharpening boosts log-luminance
/// detail, so it is independent of exposure and leaves colours alone.
struct SharpenSettings: Hashable {
    /// Detail gain (Amount).
    var gain: Float
    /// Gaussian sigma in full-resolution pixels (Radius).
    var sigma: Float
    /// Detail beyond about this many stops is boosted less and less, which holds back halos
    /// on strong edges (Detail).
    var haloScale: Float
    /// Local gradient, in stops per texel, below which nothing is sharpened (Masking).
    var edgeThreshold: Float

    init(recipe: EditRecipe) {
        gain = Float(recipe[.sharpenAmount] / 100)
        sigma = Float(recipe[.sharpenRadius]) * 0.8
        let detail = Float(recipe[.sharpenDetail] / 100)
        haloScale = 0.08 + 0.9 * detail * detail
        let masking = Float(recipe[.sharpenMasking] / 100)
        edgeThreshold = 0.3 * masking * masking
    }

    /// The blur sigma in texels of a pyramid level; nil where sharpening is off or too fine to show.
    func sigma(atLevel level: Int) -> Float? {
        let texels = sigma / Float(1 << level)
        return gain > 0 && texels >= 0.3 ? texels : nil
    }
}

/// Texture and Clarity in rendering units: gains on two bands of log-luminance detail, taken
/// from the session's pyramid. Texture's band spans about 2 to 8 full-resolution pixels,
/// Clarity's about 8 to 64; negative values smooth instead.
struct LocalContrastSettings: Hashable {
    static let textureLevels = 1 ... 3
    static let clarityLevels = 3 ... 6

    var texture: Float
    var clarity: Float
    /// Clarity's detail saturates at about this many stops, which holds back halos.
    static let clarityLimit: Float = 0.5

    init(recipe: EditRecipe) {
        let textureAmount = Float(recipe[.texture] / 100)
        // Removing the whole band looks blurred; negative Texture only softens it.
        texture = textureAmount > 0 ? textureAmount : 0.5 * textureAmount
        clarity = Float(recipe[.clarity] / 100) * 0.7
    }

    var isActive: Bool {
        texture != 0 || clarity != 0
    }

    /// A band's pyramid levels when rendering at `level`: detail finer than the rendered
    /// texels drops out, as it would when a full-resolution result is downscaled.
    static func band(_ levels: ClosedRange<Int>, renderedAt level: Int, levelCount: Int) -> ClosedRange<Int>? {
        let fine = max(levels.lowerBound, level)
        let coarse = min(levels.upperBound, levelCount - 1)
        return fine < coarse ? fine ... coarse : nil
    }
}

/// The Detail panel, plus Texture and Clarity, as a cached spatial stage in front of the fused
/// develop kernel: noise reduction, then sharpening, then local contrast.
///
/// It works on exact pyramid texels (the level whose texels are at least as dense as the
/// output), so the noise it removes is known from the session's noise model. The develop
/// kernel then samples the result instead of the pyramid.
///
/// Owned by the engine's render queue.
final class DetailStage {
    struct Output {
        let texture: any MTLTexture
        /// The area the texture covers: xy origin, zw size, in normalised source coordinates.
        let area: SIMD4<Float>
    }

    /// Texels of context around the work area, enough for the widest à-trous scale.
    static let margin = 64

    /// Whether the recipe needs the stage at full resolution.
    static func isActive(_ recipe: EditRecipe) -> Bool {
        DenoiseSettings(recipe: recipe).isActive || SharpenSettings(recipe: recipe).sigma(atLevel: 0) != nil
            || LocalContrastSettings(recipe: recipe).isActive
    }

    private let device: any MTLDevice
    private let kernels: KernelLibrary

    private struct Key: Equatable {
        var session: ObjectIdentifier
        var work: WorkArea
        var denoise: DenoiseSettings?
        var sharpen: SharpenSettings?
        var contrast: LocalContrastSettings?
    }

    private struct Entry {
        var key: Key
        /// Keeps the session alive so its identifier can't be reused while cached.
        var session: ImageSession
        var output: Output
    }

    private var entries: [Entry] = []
    /// A region and its overview, and the same for a comparison render.
    private static let maximumEntries = 4
    private var scratch: [MTLPixelFormat: [any MTLTexture]] = [:]

    init(device: any MTLDevice, kernels: KernelLibrary) {
        self.device = device
        self.kernels = kernels
    }

    /// The processed pyramid texels behind `region` rendered at `outputSize`, encoding the work
    /// into `commands` unless it's cached. Nil when the recipe needs none of the stage there.
    func process(
        _ recipe: EditRecipe,
        session: ImageSession,
        region: ImageRect,
        outputSize: PixelSize,
        commands: any MTLCommandBuffer,
        cache: Bool = true,
    ) throws -> Output? {
        guard outputSize.width > 0 else { return nil }
        let work = Self.workArea(session: session, region: region, outputSize: outputSize)
        let denoiseSettings = DenoiseSettings(recipe: recipe)
        let sharpenSettings = SharpenSettings(recipe: recipe)
        let contrastSettings = LocalContrastSettings(recipe: recipe)
        let denoise = denoiseSettings.isActive ? denoiseSettings : nil
        let sharpen = sharpenSettings.sigma(atLevel: work.level) != nil ? sharpenSettings : nil
        let contrast = contrastSettings.isActive ? contrastSettings : nil
        guard denoise != nil || sharpen != nil || contrast != nil else { return nil }
        let key = Key(
            session: ObjectIdentifier(session), work: work, denoise: denoise, sharpen: sharpen, contrast: contrast,
        )
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.output
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: work.size.x, height: work.size.y, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let encoder = commands.makeComputeCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }
        encoder.label = "Detail"
        // Each pass reads the previous one's result; the last writes the output.
        var remaining = [denoise != nil, sharpen != nil, contrast != nil].filter(\.self).count
        var source = Source(texture: session.pyramid, origin: work.origin, level: work.level)
        func target() throws -> any MTLTexture {
            remaining -= 1
            guard remaining > 0 else { return texture }
            let intermediates = try scratchTextures(.rgba16Float, 6, work)
            // Alternate between two intermediates, never the one being read.
            return intermediates[4] === source.texture ? intermediates[5] : intermediates[4]
        }
        if let denoise {
            let output = try target()
            try encodeDenoise(session: session, settings: denoise, work: work, into: output, encoder: encoder)
            source = Source(texture: output, origin: .zero, level: 0)
        }
        if let sharpen {
            let output = try target()
            try encodeSharpen(
                session: session, settings: sharpen, work: work, source: source, into: output, encoder: encoder,
            )
            source = Source(texture: output, origin: .zero, level: 0)
        }
        if let contrast {
            try encodeLocalContrast(
                session: session, settings: contrast, work: work, source: source, into: target(), encoder: encoder,
            )
        }
        encoder.endEncoding()

        let levelWidth = Float(max(1, session.pyramid.width >> work.level))
        let levelHeight = Float(max(1, session.pyramid.height >> work.level))
        let output = Output(texture: texture, area: SIMD4(
            Float(work.origin.x) / levelWidth, Float(work.origin.y) / levelHeight,
            Float(work.size.x) / levelWidth, Float(work.size.y) / levelHeight,
        ))
        if cache {
            entries.append(Entry(key: key, session: session, output: output))
            if entries.count > Self.maximumEntries {
                entries.removeFirst()
            }
        }
        return output
    }

    // MARK: - Geometry

    struct WorkArea: Equatable {
        var level: Int
        var origin: SIMD2<Int>
        var size: SIMD2<Int>
    }

    /// The pyramid level and texel rectangle (with margin) behind an oriented region.
    static func workArea(session: ImageSession, region: ImageRect, outputSize: PixelSize) -> WorkArea {
        let full = session.orientedSize
        let scale = region.width * Double(full.width) / Double(max(outputSize.width, 1))
        let level = min(max(Int(floor(log2(max(scale, 1)) + 0.01)), 0), session.pyramid.mipmapLevelCount - 1)
        let levelWidth = max(1, session.pyramid.width >> level)
        let levelHeight = max(1, session.pyramid.height >> level)

        let corners = [
            sourceCoordinate(SIMD2(region.x, region.y), orientation: session.orientation),
            sourceCoordinate(
                SIMD2(region.x + region.width, region.y + region.height),
                orientation: session.orientation,
            ),
        ]
        let low = simd_min(corners[0], corners[1])
        let high = simd_max(corners[0], corners[1])
        let x0 = max(0, Int(floor(low.x * Double(levelWidth))) - margin)
        let y0 = max(0, Int(floor(low.y * Double(levelHeight))) - margin)
        let x1 = min(levelWidth, Int(ceil(high.x * Double(levelWidth))) + margin)
        let y1 = min(levelHeight, Int(ceil(high.y * Double(levelHeight))) + margin)
        return WorkArea(level: level, origin: SIMD2(x0, y0), size: SIMD2(max(1, x1 - x0), max(1, y1 - y0)))
    }

    // MARK: - Encoding

    /// Where a pass reads the work area from: the pyramid at the work level, or an earlier
    /// pass's texture.
    private struct Source {
        var texture: any MTLTexture
        var origin: SIMD2<Int>
        var level: Int
    }

    private func encodeDenoise(
        session: ImageSession,
        settings: DenoiseSettings,
        work: WorkArea,
        into output: any MTLTexture,
        encoder: any MTLComputeCommandEncoder,
    ) throws {
        let textures = try scratchTextures(.rgba16Float, 4, work)
        var params = DenoiseParams(
            origin: SIMD4(Int32(work.origin.x), Int32(work.origin.y), Int32(work.level), 0),
            size: SIMD4(Int32(work.size.x), Int32(work.size.y), 0, 0),
            a: SIMD4(session.noise.a, 0),
            b: SIMD4(session.noise.b, 0),
        )
        var current = textures[0]
        var next = textures[1]
        let rows = textures[2]
        let result = textures[3]

        encoder.setComputePipelineState(kernels.denoisePrepare)
        encoder.setTexture(session.pyramid, index: 0)
        encoder.setTexture(current, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<DenoiseParams>.stride, index: 0)
        encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.denoisePrepare)

        let sigmas = NoiseCalibration.sigmas(sensor: session.sensor, level: work.level)
        for scale in 0 ..< DenoiseSettings.scaleCount {
            let last = scale == DenoiseSettings.scaleCount - 1
            params.scale = SIMD4(Int32(1 << scale), scale == 0 ? 1 : 0, last ? 1 : 0, 0)
            params.threshold = SIMD4(settings.thresholds[scale] * sigmas[scale], 0)

            encoder.setComputePipelineState(kernels.denoiseRows)
            encoder.setTexture(current, index: 0)
            encoder.setTexture(rows, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<DenoiseParams>.stride, index: 0)
            encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.denoiseRows)

            encoder.setComputePipelineState(kernels.denoiseColumns)
            encoder.setTexture(rows, index: 0)
            encoder.setTexture(current, index: 1)
            encoder.setTexture(last ? output : next, index: 2)
            encoder.setTexture(result, index: 3)
            encoder.setBytes(&params, length: MemoryLayout<DenoiseParams>.stride, index: 0)
            encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.denoiseColumns)
            swap(&current, &next)
        }
    }

    private func encodeSharpen(
        session: ImageSession,
        settings: SharpenSettings,
        work: WorkArea,
        source: Source,
        into output: any MTLTexture,
        encoder: any MTLComputeCommandEncoder,
    ) throws {
        let textures = try scratchTextures(.r32Float, 3, work)
        let (logLuma, rows, blurred) = (textures[0], textures[1], textures[2])
        var params = SharpenParams(
            origin: SIMD4(Int32(source.origin.x), Int32(source.origin.y), Int32(source.level), 0),
            size: SIMD4(Int32(work.size.x), Int32(work.size.y), 0, 0),
            luma: Self.luma(session),
            shape: SIMD4(
                settings.gain, settings.haloScale, settings.edgeThreshold,
                settings.sigma(atLevel: work.level) ?? 0,
            ),
        )
        let size = params.size
        func dispatch(_ pipeline: any MTLComputePipelineState, _ textures: [any MTLTexture]) {
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() {
                encoder.setTexture(texture, index: index)
            }
            encoder.setBytes(&params, length: MemoryLayout<SharpenParams>.stride, index: 0)
            encoder.dispatchGrid(width: Int(size.x), height: Int(size.y), pipeline: pipeline)
        }
        dispatch(kernels.sharpenLog, [source.texture, logLuma])
        params.size.z = 0
        dispatch(kernels.sharpenBlur, [logLuma, rows])
        params.size.z = 1
        dispatch(kernels.sharpenBlur, [rows, blurred])
        dispatch(kernels.sharpenApply, [source.texture, logLuma, blurred, output])
    }

    private func encodeLocalContrast(
        session: ImageSession,
        settings: LocalContrastSettings,
        work: WorkArea,
        source: Source,
        into output: any MTLTexture,
        encoder: any MTLComputeCommandEncoder,
    ) {
        let levelCount = session.pyramid.mipmapLevelCount
        let texture = LocalContrastSettings.band(
            LocalContrastSettings.textureLevels, renderedAt: work.level, levelCount: levelCount,
        )
        let clarity = LocalContrastSettings.band(
            LocalContrastSettings.clarityLevels, renderedAt: work.level, levelCount: levelCount,
        )
        var params = LocalContrastParams(
            origin: SIMD4(Int32(source.origin.x), Int32(source.origin.y), Int32(source.level), 0),
            size: SIMD4(Int32(work.size.x), Int32(work.size.y), 0, 0),
            place: SIMD4(Int32(work.origin.x), Int32(work.origin.y), Int32(work.level), 0),
            levels: SIMD4(
                Int32(texture?.lowerBound ?? 0), Int32(texture?.upperBound ?? 0),
                Int32(clarity?.lowerBound ?? 0), Int32(clarity?.upperBound ?? 0),
            ),
            luma: Self.luma(session),
            shape: SIMD4(
                texture == nil ? 0 : settings.texture, clarity == nil ? 0 : settings.clarity,
                LocalContrastSettings.clarityLimit, 0,
            ),
        )
        encoder.setComputePipelineState(kernels.localContrast)
        encoder.setTexture(source.texture, index: 0)
        encoder.setTexture(session.pyramid, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<LocalContrastParams>.stride, index: 0)
        encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.localContrast)
    }

    /// Rec. 2020 luminance weights for the pyramid's camera RGB, and a floor for its log.
    private static func luma(_ session: ImageSession) -> SIMD4<Float> {
        SIMD4(session.cameraToWorking.transpose * SIMD3<Float>(0.2627, 0.6780, 0.0593), 1.0 / 1024)
    }

    /// `count` working textures of `format` covering the work area, reused across renders.
    private func scratchTextures(_ format: MTLPixelFormat, _ count: Int, _ work: WorkArea) throws -> [any MTLTexture] {
        let existing = scratch[format] ?? []
        if existing.count >= count, let first = existing.first,
           first.width >= work.size.x, first.height >= work.size.y {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: max(work.size.x, existing.first?.width ?? 0),
            height: max(work.size.y, existing.first?.height ?? 0),
            mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let textures = try (0 ..< max(count, existing.count)).map { _ in
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
            return texture
        }
        scratch[format] = textures
        return textures
    }
}

/// The noise in each à-trous scale of the stabilised opponent image (luma, two chroma axes), for
/// unit noise per raw sample, at pyramid levels 0 to 2.
///
/// Demosaicing correlates the channels and low-passes the noise, and the pyramid's box filter
/// reshapes it again, so these are measured (`DetailStageTests`, with `REDLAMP_CALIBRATE_NOISE=1`)
/// rather than taken from white-noise theory. Linear raw is the white-noise case.
enum NoiseCalibration {
    static let bayer: [[SIMD3<Float>]] = [
        [
            SIMD3(1.153, 0.349, 0.272),
            SIMD3(0.380, 0.241, 0.224),
            SIMD3(0.160, 0.150, 0.128),
            SIMD3(0.0756, 0.0798, 0.0653),
            SIMD3(0.0378, 0.0404, 0.0330),
        ],
        [
            SIMD3(0.790, 0.368, 0.358),
            SIMD3(0.184, 0.167, 0.143),
            SIMD3(0.0781, 0.0820, 0.0672),
            SIMD3(0.0381, 0.0407, 0.0333),
            SIMD3(0.0188, 0.0207, 0.0167),
        ],
        [
            SIMD3(0.405, 0.310, 0.273),
            SIMD3(0.0914, 0.0927, 0.0764),
            SIMD3(0.0395, 0.0419, 0.0343),
            SIMD3(0.0190, 0.0208, 0.0168),
            SIMD3(0.0089, 0.0106, 0.0087),
        ],
    ]

    static let xTrans: [[SIMD3<Float>]] = [
        [
            SIMD3(0.565, 0.383, 0.653),
            SIMD3(0.315, 0.279, 0.242),
            SIMD3(0.135, 0.148, 0.118),
            SIMD3(0.0706, 0.0785, 0.0615),
            SIMD3(0.0362, 0.0400, 0.0309),
        ],
        [
            SIMD3(0.534, 0.454, 0.428),
            SIMD3(0.152, 0.165, 0.133),
            SIMD3(0.0726, 0.0807, 0.0634),
            SIMD3(0.0365, 0.0403, 0.0311),
            SIMD3(0.0185, 0.0201, 0.0160),
        ],
        [
            SIMD3(0.332, 0.326, 0.274),
            SIMD3(0.0829, 0.0914, 0.0723),
            SIMD3(0.0375, 0.0414, 0.0321),
            SIMD3(0.0186, 0.0202, 0.0161),
            SIMD3(0.0087, 0.0096, 0.0076),
        ],
    ]

    /// B3-spline à-trous detail noise for unit white noise (Starck & Murtagh); each pyramid level
    /// averages four texels, halving it.
    static let white: [[SIMD3<Float>]] = (0 ... 2).map { level in
        [0.8908, 0.2007, 0.0856, 0.0413, 0.0205].map { SIMD3(repeating: Float($0) / Float(1 << level)) }
    }

    static func sigmas(sensor: SensorKind, level: Int) -> [SIMD3<Float>] {
        let table = switch sensor {
        case .bayer: bayer
        case .xTrans: xTrans
        case .linear, .bitmap: white
        }
        // Beyond level 2 the noise is close to white and halves per level.
        let attenuation = 1 / Float(1 << max(level - 2, 0))
        return table[min(level, 2)].map { $0 * attenuation }
    }
}
