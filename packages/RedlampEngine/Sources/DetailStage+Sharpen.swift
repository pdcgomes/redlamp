import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd

/// One sharpening pass over a work area.
struct SharpenRequest {
    var session: ImageSession
    var settings: SharpenSettings
    var work: DetailStage.WorkArea
    var source: DetailStage.Source
    /// Masks' amounts per texel, when any mask uses Texture, Clarity, Sharpness or Noise.
    var local: (any MTLTexture)?
    /// A mask's negative Sharpness can make the gain negative; softening then blurs the source.
    var softens: Bool
    var measures: SharpenMeasures
    /// Process 10: the separator keeps the ladder's bands that stand out of the noise instead of
    /// denoising the pyramid.
    var ladder: Ladder?
}

/// Sharpening's analysis of a work area, and the source's log luminance and its blur when a
/// mask softens.
struct SharpenMeasured {
    var analysis: any MTLTexture
    var softening: (log: any MTLTexture, blurred: any MTLTexture)?
}

/// Sharpening's measures of a work area: those given are read, the others measured into their
/// targets.
struct SharpenMeasures {
    var analysis: (any MTLTexture)?
    var separation: (any MTLTexture)?
    var analysisTarget: (any MTLTexture)?
    var separationTarget: (any MTLTexture)?
}

/// Sharpening's analysis of an area depends only on the photo, the area and the Radius, and the
/// separator's clean luminance not even on the Radius. Caching both means dragging Amount, Detail,
/// Masking or a noise slider reruns only the final pass, and dragging Radius skips the separator.
///
/// Owned by the engine's render queue, through `DetailStage`.
final class SharpenCache {
    /// The view and its overview. At 1:1 on a 5K display an area is about 15 MP, and the two
    /// caches hold 10 bytes per texel of it.
    static let maximumEntries = 2

    struct Analysis {
        var session: ObjectIdentifier
        var work: DetailStage.WorkArea
        var sigma: Float
        /// Process 10: the ladder the separator read.
        var ladder: LadderKey?
        /// Keeps the session alive so its identifier can't be reused while cached.
        var owner: ImageSession
        /// x unsharp detail, y deconvolution detail, z blurred log luminance.
        var texture: any MTLTexture
    }

    struct Separation {
        var session: ObjectIdentifier
        var work: DetailStage.WorkArea
        var owner: ImageSession
        /// The separator's clean linear luminance.
        var linear: any MTLTexture
    }

    private let residency: DetailResidency
    private var analyses: [Analysis] = []
    private var separations: [Separation] = []

    init(residency: DetailResidency) {
        self.residency = residency
    }

    var heldTextures: [any MTLTexture] {
        analyses.map(\.texture) + separations.map(\.linear)
    }

    func analysis(
        _ session: ImageSession,
        _ work: DetailStage.WorkArea,
        sigma: Float,
        ladder: LadderKey? = nil,
    ) -> (any MTLTexture)? {
        let identifier = ObjectIdentifier(session)
        guard let index = analyses.firstIndex(where: {
            $0.session == identifier && $0.work == work && $0.sigma == sigma && $0.ladder == ladder
        })
        else { return nil }
        let entry = analyses.remove(at: index)
        guard residency.wake(entry.texture) else { return nil }
        analyses.append(entry)
        return entry.texture
    }

    func store(
        analysis texture: any MTLTexture,
        _ session: ImageSession,
        _ work: DetailStage.WorkArea,
        sigma: Float,
        ladder: LadderKey? = nil,
    ) {
        residency.wake(texture)
        analyses.append(Analysis(
            session: ObjectIdentifier(session),
            work: work,
            sigma: sigma,
            ladder: ladder,
            owner: session,
            texture: texture,
        ))
        if analyses.count > Self.maximumEntries {
            analyses.removeFirst()
        }
    }

    func separation(_ session: ImageSession, _ work: DetailStage.WorkArea) -> (any MTLTexture)? {
        let identifier = ObjectIdentifier(session)
        guard let index = separations.firstIndex(where: { $0.session == identifier && $0.work == work })
        else { return nil }
        let entry = separations.remove(at: index)
        guard residency.wake(entry.linear) else { return nil }
        separations.append(entry)
        return entry.linear
    }

    func store(separation linear: any MTLTexture, _ session: ImageSession, _ work: DetailStage.WorkArea) {
        residency.wake(linear)
        separations.append(Separation(session: ObjectIdentifier(session), work: work, owner: session, linear: linear))
        if separations.count > Self.maximumEntries {
            separations.removeFirst()
        }
    }

    /// Drops the entries holding any of `textures`, which were never rendered.
    func forget(_ textures: Set<ObjectIdentifier>) {
        analyses.removeAll { textures.contains(ObjectIdentifier($0.texture)) }
        separations.removeAll { textures.contains(ObjectIdentifier($0.linear)) }
    }

    func removeAll() {
        analyses.removeAll()
        separations.removeAll()
    }
}

extension DetailStage {
    func encodeSharpen(
        _ request: SharpenRequest,
        into output: any MTLTexture,
        encoder: any MTLComputeCommandEncoder,
    ) throws {
        var passes = try sharpenPasses(request, encoder: encoder)
        let measured = try encodeSharpenMeasures(request, passes: &passes)
        passes.params.size.w = request.local == nil ? 0 : 1
        passes.dispatch(kernels.sharpenApply, [
            request.source.texture, measured.analysis, output, request.local ?? output,
            measured.softening?.log ?? measured.analysis, measured.softening?.blurred ?? measured.analysis,
        ])
    }

    /// What sharpening reads besides the source: its analysis and, when a mask softens, the
    /// source's log luminance and its blur.
    func encodeSharpenMeasures(
        _ request: SharpenRequest,
        encoder: any MTLComputeCommandEncoder,
    ) throws -> SharpenMeasured {
        var passes = try sharpenPasses(request, encoder: encoder)
        return try encodeSharpenMeasures(request, passes: &passes)
    }

    private func sharpenPasses(
        _ request: SharpenRequest,
        encoder: any MTLComputeCommandEncoder,
    ) throws -> SharpenPasses {
        let (session, settings, work, source) = (request.session, request.settings, request.work, request.source)
        let sigma = settings.sigma(atLevel: work.level) ?? 0
        // 0 source log, 1 clean log, 2 blur rows, 3 blurred clean log, 4 blurred source log.
        let blurs = request.measures.analysis == nil || request.softens
        let rows = blurs ? try scratchTexture(.r32Float, 2, work) : nil
        return SharpenPasses(encoder: encoder, kernels: kernels, rows: rows, params: SharpenParams(
            origin: SIMD4(Int32(source.origin.x), Int32(source.origin.y), Int32(source.level), 0),
            size: SIMD4(Int32(work.size.x), Int32(work.size.y), 0, 0),
            luma: Self.luma(session),
            shape: SIMD4(settings.gain, settings.haloScale, settings.edgeThreshold, sigma),
            deconvolution: SIMD4(settings.deconvolution, 0, request.softens ? 1 : 0, 0),
        ))
    }

    private func encodeSharpenMeasures(
        _ request: SharpenRequest,
        passes: inout SharpenPasses,
    ) throws -> SharpenMeasured {
        let work = request.work
        let analysis: any MTLTexture
        if let measured = request.measures.analysis {
            analysis = measured
        } else {
            guard let target = request.measures.analysisTarget else {
                throw EngineError.renderFailed("no texture for sharpening's analysis")
            }
            analysis = target
            try encodeSharpenAnalysis(request, into: analysis, passes: &passes)
        }

        var softening: (log: any MTLTexture, blurred: any MTLTexture)?
        if request.softens {
            let (sourceLog, sourceBlurred) = try (
                scratchTexture(.r32Float, 0, work),
                scratchTexture(.r32Float, 4, work),
            )
            passes.dispatch(kernels.sharpenLog, [request.source.texture, sourceLog])
            try passes.blur(sourceLog, into: sourceBlurred)
            softening = (sourceLog, sourceBlurred)
        }
        return SharpenMeasured(analysis: analysis, softening: softening)
    }

    /// What sharpening measures on the separator's clean luminance D: the unsharp detail
    /// (log D minus its blur), the deconvolution detail (log of Richardson-Lucy's estimate minus
    /// log D) and the blurred log D that Masking reads, packed into `analysis`.
    private func encodeSharpenAnalysis(
        _ request: SharpenRequest,
        into analysis: any MTLTexture,
        passes: inout SharpenPasses,
    ) throws {
        let (session, work) = (request.session, request.work)
        let (logLuma, blurred) = try (scratchTexture(.r32Float, 1, work), scratchTexture(.r32Float, 3, work))
        // The deconvolution reads a texture for every tap of every pass, so its images are half
        // floats (half the traffic); its detail changes by under 1/1000 of a stop. The log detail
        // stays in 32-bit floats: the unsharp mask measures differences of hundredths of a stop.
        // Slot 0 holds an uncached separation.
        let halves = try (1 ... 4).map { try scratchTexture(.r16Float, $0, work) }
        let (rows, ratio) = (halves[3], halves[2])
        let estimates = [halves[0], halves[1]]
        let linear: any MTLTexture
        if let measured = request.measures.separation {
            linear = measured
        } else {
            guard let target = request.measures.separationTarget else {
                throw EngineError.renderFailed("no texture for sharpening's separation")
            }
            linear = target
            if let ladder = request.ladder {
                encodeLadderSeparation(
                    session: session,
                    ladder: ladder,
                    work: work,
                    into: linear,
                    encoder: passes.encoder,
                )
            } else {
                // The separator denoises from the pyramid, whatever the user's own noise reduction did.
                let separated = try scratchTexture(.rgba16Float, 7, work)
                try encodeDenoise(
                    session: session, settings: .separator, work: work, local: nil, into: separated,
                    encoder: passes.encoder,
                )
                passes.dispatch(kernels.sharpenLuma, [separated, linear, logLuma])
            }
        }
        // The log always comes from the stored half-float luminance, so a cached separation renders
        // exactly what a fresh one does: the luma kernel on it (weights 1, 0, 0, no floor).
        let weights = passes.params.luma
        passes.params.luma = SIMD4(1, 0, 0, 0)
        passes.dispatch(kernels.sharpenLuma, [linear, estimates[1], logLuma])
        passes.params.luma = weights

        // Richardson-Lucy from the observed clean luminance: estimate *= blur(D / blur(estimate)).
        var estimate = linear
        for iteration in 0 ..< SharpenSettings.iterations {
            let next = estimates[iteration % 2]
            passes.params.size.z = 0
            passes.dispatch(kernels.sharpenBlur, [estimate, rows])
            passes.params.deconvolution.y = 0
            passes.dispatch(kernels.deconvolveColumns, [rows, linear, ratio])
            passes.params.size.z = 0
            passes.dispatch(kernels.sharpenBlur, [ratio, rows])
            passes.params.deconvolution.y = 1
            passes.dispatch(kernels.deconvolveColumns, [rows, estimate, next])
            estimate = next
        }
        try passes.blur(logLuma, into: blurred)
        passes.dispatch(kernels.sharpenAnalysis, [logLuma, blurred, estimate, analysis])
    }
}

/// Encodes sharpening's passes over one work area with shared parameters.
private struct SharpenPasses {
    let encoder: any MTLComputeCommandEncoder
    let kernels: KernelLibrary
    /// Scratch for the first direction of a blur, when the passes blur at all.
    let rows: (any MTLTexture)?
    var params: SharpenParams
    /// The blurs' Gaussian, once per area instead of per tap: the radius, then the normalised
    /// weight at each offset 0 ... radius.
    private var weights: [Float]

    init(
        encoder: any MTLComputeCommandEncoder,
        kernels: KernelLibrary,
        rows: (any MTLTexture)?,
        params: SharpenParams,
    ) {
        self.encoder = encoder
        self.kernels = kernels
        self.rows = rows
        self.params = params
        let sigma = max(params.shape.w, 1e-3)
        let radius = SharpenSettings.blurRadius(sigma: sigma)
        let raw = (0 ... radius).map { exp(-0.5 * Float($0 * $0) / (sigma * sigma)) }
        let total = raw.dropFirst().reduce(raw[0]) { $0 + 2 * $1 }
        weights = [Float(radius)] + raw.map { $0 / total }
    }

    mutating func dispatch(_ pipeline: any MTLComputePipelineState, _ textures: [any MTLTexture]) {
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        encoder.setBytes(&params, length: MemoryLayout<SharpenParams>.stride, index: 0)
        encoder.setBytes(weights, length: weights.count * MemoryLayout<Float>.stride, index: 1)
        encoder.dispatchGrid(width: Int(params.size.x), height: Int(params.size.y), pipeline: pipeline)
    }

    /// A separable Gaussian blur of the Radius's sigma.
    mutating func blur(_ input: any MTLTexture, into result: any MTLTexture) throws {
        guard let rows else { throw EngineError.renderFailed("a sharpening blur without its scratch") }
        params.size.z = 0
        dispatch(kernels.sharpenBlur, [input, rows])
        params.size.z = 1
        dispatch(kernels.sharpenBlur, [rows, result])
    }
}
