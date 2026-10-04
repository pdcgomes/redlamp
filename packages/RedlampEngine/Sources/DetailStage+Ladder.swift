import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd

/// Process 10's decomposition of a work area (`DetailLadder.metal`): an à-trous B3-spline ladder
/// of the noise-reduced linear luminance, which Texture, Clarity and sharpening's separator all
/// read. Rendering at level L, the texels are the ladder's level 0 and its band j spans
/// full-resolution scales L + j to L + j + 1.
struct Ladder {
    static let scaleCount = 4
    /// How far around a texel, in work texels, the ladder reads: two taps each way per scale.
    static let reach = 2 * ((1 << scaleCount) - 1)

    /// The noise-reduced source, when noise reduction runs; otherwise the pyramid is the source.
    var denoised: (any MTLTexture)?
    /// Band j in channel j.
    var bands: any MTLTexture
    var residual: any MTLTexture

    var textures: [any MTLTexture] {
        [denoised, bands, residual].compactMap(\.self)
    }

    /// The source the ladder was taken from.
    func source(_ session: ImageSession, work: DetailStage.WorkArea) -> DetailStage.Source {
        denoised.map { DetailStage.Source(texture: $0, origin: .zero, level: 0) }
            ?? DetailStage.Source(texture: session.pyramid, origin: work.origin, level: work.level)
    }

    /// Texture's band at work level `level` as ladder indices (0 the texels, 4 the residual):
    /// full-resolution levels 1 to 3, the texels standing in for the finer ones, and at least one
    /// level wide. Nil where the band is too fine to show.
    static func textureBand(level: Int) -> (fine: Int, coarse: Int)? {
        guard level <= 4 else { return nil }
        return (max(1, level) - level, max(3, level + 1) - level)
    }

    /// Clarity's fine level as a ladder index: full-resolution level 3, or the texels.
    static func clarityFine(level: Int) -> Int {
        max(3, level) - level
    }
}

/// What a work area's ladder depends on.
struct LadderKey: Hashable {
    var session: ObjectIdentifier
    var work: DetailStage.WorkArea
    var denoise: DenoiseSettings?
    /// The masks, when any sets Noise, which noise reduction reads.
    var local: LocalDetail?
}

/// A work area's ladder: given, it is read; otherwise it is taken into `target`.
struct LadderMeasures {
    var ladder: Ladder?
    var target: Ladder?
}

/// The ladder of the view and its overview, so dragging Texture, Clarity, sharpening's Amount,
/// Detail or Masking, or a mask's amounts, reruns only the final pass, and dragging Radius only
/// sharpening's analysis.
///
/// Owned by the engine's render queue, through `DetailStage`.
final class LadderCache {
    static let maximumEntries = 2

    private struct Entry {
        var key: LadderKey
        /// Keeps the session alive so its identifier can't be reused while cached.
        var owner: ImageSession
        var ladder: Ladder
    }

    private let residency: DetailResidency
    private var entries: [Entry] = []

    init(residency: DetailResidency) {
        self.residency = residency
    }

    var heldTextures: [any MTLTexture] {
        entries.flatMap(\.ladder.textures)
    }

    func ladder(_ key: LadderKey) -> Ladder? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        guard entry.ladder.textures.allSatisfy({ residency.wake($0) }) else { return nil }
        entries.append(entry)
        return entry.ladder
    }

    func store(_ ladder: Ladder, key: LadderKey, owner: ImageSession) {
        ladder.textures.forEach { residency.wake($0) }
        entries.append(Entry(key: key, owner: owner, ladder: ladder))
        if entries.count > Self.maximumEntries {
            entries.removeFirst()
        }
    }

    /// Drops the entries holding any of `textures`, which were never rendered.
    func forget(_ textures: Set<ObjectIdentifier>) {
        entries.removeAll { $0.ladder.textures.contains { textures.contains(ObjectIdentifier($0)) } }
    }

    func removeAll() {
        entries.removeAll()
    }
}

extension DetailStage {
    /// Process 10's Clarity base for `session`: `ClarityBase` in the ladder's luminance, so
    /// Clarity's band and its base measure the same thing.
    func clarityBase(_ session: ImageSession) throws -> any MTLTexture {
        if let base = clarityBases.first(where: { $0.owner === session }) {
            return base.texture
        }
        let luma = Self.luma(session)
        let texture = try ClarityBase.coefficients(
            session.analysis, fullLongEdge: max(session.info.pixelSize.width, session.info.pixelSize.height),
            weights: SIMD3(luma.x, luma.y, luma.z),
        ).texture(device: kernels.device)
        clarityBases.append((session, texture))
        if clarityBases.count > 2 {
            clarityBases.removeFirst()
        }
        return texture
    }

    /// A ladder in work textures of its own, to cache.
    func makeLadder(_ work: WorkArea, denoised: Bool) throws -> Ladder {
        try Ladder(
            denoised: denoised ? makeWorkTexture(.rgba16Float, work) : nil,
            bands: makeWorkTexture(.rgba16Float, work),
            residual: makeWorkTexture(.r16Float, work),
        )
    }

    /// A ladder in scratch textures.
    func scratchLadder(_ work: WorkArea, denoised: Bool) throws -> Ladder {
        try Ladder(
            denoised: denoised ? scratchTexture(.rgba16Float, 4, work) : nil,
            bands: scratchTexture(.rgba16Float, 11, work),
            residual: scratchTexture(.r16Float, 5, work),
        )
    }

    /// Takes the ladder of `source`'s luminance into `ladder`'s bands and residual.
    func encodeLadder(
        session: ImageSession,
        source: Source,
        work: WorkArea,
        into ladder: Ladder,
        encoder: any MTLComputeCommandEncoder,
    ) throws {
        // Sharpening's analysis takes these slots over once the ladder is done.
        let rows = try scratchTexture(.r32Float, 2, work)
        let levels = try [scratchTexture(.r32Float, 1, work), scratchTexture(.r32Float, 3, work)]
        var params = LadderParams(
            origin: SIMD4(Int32(source.origin.x), Int32(source.origin.y), Int32(source.level), 0),
            size: SIMD4(Int32(work.size.x), Int32(work.size.y), 0, 1),
            place: SIMD4(Int32(work.origin.x), Int32(work.origin.y), Int32(work.level), 0),
            luma: Self.luma(session),
        )
        for scale in 0 ..< Ladder.scaleCount {
            params.size.z = Int32(scale)
            params.size.w = Int32(1 << scale)
            // Scale 0 reads the source; each later one the level the one before wrote.
            let (level, next) = (levels[(scale + 1) % 2], levels[scale % 2])
            encoder.setComputePipelineState(kernels.ladderRows)
            encoder.setTexture(source.texture, index: 0)
            encoder.setTexture(level, index: 1)
            encoder.setTexture(rows, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<LadderParams>.stride, index: 0)
            encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.ladderRows)

            encoder.setComputePipelineState(kernels.ladderColumns)
            encoder.setTexture(rows, index: 0)
            encoder.setTexture(source.texture, index: 1)
            encoder.setTexture(level, index: 2)
            encoder.setTexture(next, index: 3)
            encoder.setTexture(ladder.bands, index: 4)
            encoder.setTexture(ladder.residual, index: 5)
            encoder.setBytes(&params, length: MemoryLayout<LadderParams>.stride, index: 0)
            encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.ladderColumns)
        }
    }

    /// Sharpening's separator on the ladder: the clean luminance D, plus the log's floor.
    func encodeLadderSeparation(
        session: ImageSession,
        ladder: Ladder,
        work: WorkArea,
        into linear: any MTLTexture,
        encoder: any MTLComputeCommandEncoder,
    ) {
        let noiseLevel = min(work.level + 2, session.pyramid.mipmapLevelCount - 1)
        var params = LadderParams(
            origin: .zero,
            size: SIMD4(Int32(work.size.x), Int32(work.size.y), 0, 0),
            place: SIMD4(Int32(work.origin.x), Int32(work.origin.y), Int32(work.level), Int32(noiseLevel)),
            luma: Self.luma(session),
            a: SIMD4(session.noise.a, 0),
            b: SIMD4(session.noise.b, 0),
            thresholds: SharpenSettings.separatorSigmas
                * NoiseCalibration.ladderSigmas(sensor: session.sensor, level: work.level),
        )
        encoder.setComputePipelineState(kernels.ladderSeparate)
        encoder.setTexture(ladder.bands, index: 0)
        encoder.setTexture(ladder.residual, index: 1)
        encoder.setTexture(session.pyramid, index: 2)
        encoder.setTexture(session.noiseGain, index: 3)
        encoder.setTexture(linear, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<LadderParams>.stride, index: 0)
        encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.ladderSeparate)
    }

    /// Process 10's passes over `work`: noise reduction and the ladder unless given, sharpening's
    /// analysis unless given, then Texture, Clarity and sharpening in one pass into `output`.
    func encodeDecomposed(
        _ passes: Passes,
        work: WorkArea,
        into output: any MTLTexture,
        measures: SharpenMeasures?,
        ladder measured: LadderMeasures,
        encoder: any MTLComputeCommandEncoder,
    ) throws {
        let session = passes.session
        let amounts = passes.local.isEmpty ? nil : try encodeLocal(
            session: session, local: passes.local, work: work, masks: passes.masks, encoder: encoder,
        )
        let ladder: Ladder
        if let given = measured.ladder {
            ladder = given
        } else {
            guard let target = measured.target else { throw EngineError.renderFailed("no textures for the ladder") }
            if let denoise = passes.denoise, let denoised = target.denoised {
                try encodeDenoise(
                    session: session, settings: denoise, work: work, local: amounts, into: denoised, encoder: encoder,
                )
            }
            try encodeLadder(
                session: session, source: target.source(session, work: work), work: work, into: target,
                encoder: encoder,
            )
            ladder = target
        }
        let source = ladder.source(session, work: work)

        var sharpening: SharpenMeasured?
        if let sharpen = passes.sharpen {
            guard let measures else { throw EngineError.renderFailed("sharpening without its measures") }
            sharpening = try encodeSharpenMeasures(SharpenRequest(
                session: session, settings: sharpen, work: work, source: source, local: amounts,
                softens: passes.softens, measures: measures, ladder: ladder,
            ), encoder: encoder)
        }

        let contrast = passes.contrast
        let levelCount = session.pyramid.mipmapLevelCount
        let texture = contrast.flatMap { _ in Ladder.textureBand(level: work.level) }
        let clarity = contrast != nil && LocalContrastSettings.band(
            LocalContrastSettings.clarityLevels, renderedAt: work.level, levelCount: levelCount,
        ) != nil
        let sharpen = passes.sharpen
        let levelWidth = max(1, session.pyramid.width >> work.level)
        let levelHeight = max(1, session.pyramid.height >> work.level)
        var params = DetailApplyParams(
            origin: SIMD4(Int32(source.origin.x), Int32(source.origin.y), Int32(source.level), 0),
            size: SIMD4(
                Int32(work.size.x), Int32(work.size.y), amounts == nil ? 0 : 1, sharpening?.softening == nil ? 0 : 1,
            ),
            place: SIMD4(Int32(work.origin.x), Int32(work.origin.y), Int32(work.level), 0),
            bands: SIMD4(
                Int32(texture?.fine ?? 1), Int32(texture?.coarse ?? 0),
                Int32(clarity ? Ladder.clarityFine(level: work.level) : 5), sharpen == nil ? 0 : 1,
            ),
            luma: Self.luma(session),
            texture: SIMD4(
                contrast?.texture ?? 0, LocalContrastSettings.textureLimit, LocalContrastSettings.textureGain,
                LocalContrastSettings.textureWeight(level: work.level),
            ),
            clarity: SIMD4(contrast?.clarity ?? 0, LocalContrastSettings.clarityLimit, ClarityBase.gain, 0),
            sharpen: SIMD4(
                sharpen?.gain ?? 0, sharpen?.haloScale ?? 1, sharpen?.edgeThreshold ?? 0, sharpen?.deconvolution ?? 0,
            ),
            frame: SIMD4(Float(levelWidth), Float(levelHeight), 0, 0),
        )
        let analysis = sharpening?.analysis ?? output
        encoder.setComputePipelineState(kernels.detailApply)
        encoder.setTexture(source.texture, index: 0)
        encoder.setTexture(ladder.bands, index: 1)
        encoder.setTexture(ladder.residual, index: 2)
        encoder.setTexture(analysis, index: 3)
        encoder.setTexture(amounts ?? output, index: 4)
        encoder.setTexture(sharpening?.softening?.log ?? analysis, index: 5)
        encoder.setTexture(sharpening?.softening?.blurred ?? analysis, index: 6)
        try encoder.setTexture(clarityBase(session), index: 7)
        encoder.setTexture(output, index: 8)
        encoder.setBytes(&params, length: MemoryLayout<DetailApplyParams>.stride, index: 0)
        encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.detailApply)
    }
}
