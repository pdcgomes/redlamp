import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Synchronization

/// The Detail panel's noise sliders in rendering units: per à-trous scale, how many noise
/// sigmas of luma and chroma detail to remove. Luma is split into a strength, which masks' Noise
/// adds to per pixel, and a threshold per unit of it.
struct DenoiseSettings: Hashable {
    /// Chroma stops averaging across luma differences of about this many of the level's noise
    /// sigmas. Chosen with `NoiseBenchmarkTests`: at 3 (2 is as good, 5 starts letting colour
    /// through) a clipped orange light no longer bleeds into its blue surroundings at high Color.
    static let chromaEdge: Float = 3

    /// Luma detail is shrunk by the energy of its (2r+1)² neighbourhood rather than by its own
    /// magnitude, so texture keeps its coefficients and flat areas lose theirs. Chosen with
    /// `NoiseBenchmarkTests`: radius 1 adds 1.1–1.4 dB at Luminance 50 for the same texture
    /// (2 over-smooths; 0 is the plain per-coefficient garrote).
    static let lumaEnergyRadius: Float = 1

    /// At 1:1 and in exports, luma is then non-local means of the noisy texels, weighted by how
    /// alike the wavelet result's 3×3 patches are within 7×7, with a patch difference of this
    /// many pixel noise sigmas (per unit of Luminance strength) weighing 1/e. Chosen with
    /// `NoiseBenchmarkTests`: at 2, Luminance 50 adds 0.8 dB and keeps 90% of the texture where
    /// the wavelet alone kept 85% (1.5 is better above Luminance 75, worse below; 5×5 patches and
    /// 11×11 windows are no better).
    static let nonLocalWidth: Float = 2
    static let nonLocalSearch: Float = 3

    static let scaleCount = 5

    /// The Luminance slider / 100.
    var luma: Float
    var lumaPerStrength: [Float]
    var chroma: [Float]
    var lumaRadius: Float
    var nonLocalWidth: Float

    var isActive: Bool {
        luma > 0 || chroma.contains { $0 > 0 }
    }

    /// How far around a texel, in work texels, noise reduction at `level` reads.
    func reach(level: Int) -> Int {
        // Each scale's rows and columns read the B3 spline's two taps each way at its spacing; the
        // coarsest scale's detail then has its energy measured over its own neighbourhood.
        let coarsest = 1 << (Self.scaleCount - 1)
        var reach = 2 * (2 * coarsest - 1) + Int(lumaRadius) * coarsest
        if nonLocalWidth > 0, level == 0 {
            // Each search offset compares 3×3 patches.
            reach += Int(Self.nonLocalSearch) + 1
        }
        return reach
    }

    /// Sharpening's separator: noise removed at a fixed number of sigmas per scale, luma and chroma
    /// (sharpening reads Rec. 2020 luminance, which picks up the chroma axes' noise too), so the
    /// detail it boosts is detail, not noise. Chosen by `shp01_calibrate.py`: at 3 sigmas flat
    /// noise grows under 1% at any Detail, where luma alone let it grow 17-29%. It keeps the
    /// per-coefficient garrote that calibration used.
    static let separator = DenoiseSettings(
        luma: 1,
        lumaPerStrength: Array(repeating: 3, count: scaleCount),
        chroma: Array(repeating: 3, count: scaleCount),
        lumaRadius: 0,
        nonLocalWidth: 0,
    )

    private init(luma: Float, lumaPerStrength: [Float], chroma: [Float], lumaRadius: Float, nonLocalWidth: Float) {
        self.luma = luma
        self.lumaPerStrength = lumaPerStrength
        self.chroma = chroma
        self.lumaRadius = lumaRadius
        self.nonLocalWidth = nonLocalWidth
    }

    init(recipe: EditRecipe) {
        let luma = Float(recipe[.noiseLuminance] / 100)
        let lumaDetail = Float(recipe[.noiseLuminanceDetail] / 100)
        let lumaContrast = Float(recipe[.noiseLuminanceContrast] / 100)
        let chroma = Float(recipe[.noiseColor] / 100)
        let chromaDetail = Float(recipe[.noiseColorDetail] / 100)
        let smoothness = Float(recipe[.noiseColorSmoothness] / 100)
        self.luma = luma
        // Detail keeps the finest scales; Contrast keeps the coarser ones.
        lumaPerStrength = (0 ..< Self.scaleCount).map { scale in
            2.5 * (scale < 2 ? 1.4 - 0.8 * lumaDetail : 1 - 0.6 * lumaContrast)
        }
        // Color Detail keeps thin color edges; Smoothness reaches into the coarse mottling.
        self.chroma = (0 ..< Self.scaleCount).map { scale in
            6 * chroma * (scale < 2 ? 1.4 - 0.8 * chromaDetail : scale >= 3 ? 0.5 + smoothness : 1)
        }
        lumaRadius = Self.lumaEnergyRadius
        nonLocalWidth = Self.nonLocalWidth
    }
}

/// The Detail panel's sharpening sliders in rendering units. Sharpening boosts log-luminance
/// detail, so it is independent of exposure and leaves colours alone. The detail is measured on
/// the separator's clean luminance and mixed between an unsharp mask and Richardson-Lucy
/// deconvolution of a Gaussian of the Radius, so noise isn't boosted.
struct SharpenSettings: Hashable {
    /// Richardson-Lucy iterations; fixed, so previews and exports match (`shp01_calibrate.py`:
    /// the gain levels off by 4, and noisy input peaks there).
    static let iterations = 4

    /// Detail gain (Amount).
    var gain: Float
    /// Gaussian sigma in full-resolution pixels (Radius).
    var sigma: Float
    /// Detail beyond about this many stops is boosted less and less, which holds back halos
    /// on strong edges (Detail).
    var haloScale: Float
    /// Detail's share of deconvolution against unsharp masking (Detail).
    var deconvolution: Float
    /// Local gradient, in stops per texel, below which nothing is sharpened (Masking).
    var edgeThreshold: Float
    /// Process 11: the separator is the ladder's bands that stand out of the noise (`Ladder`).
    var decomposition: Bool

    /// Process 11's separator keeps the ladder's detail above this many noise sigmas, as the
    /// pyramid separator does (`DenoiseSettings.separator`).
    static let separatorSigmas: Float = 3

    init(recipe: EditRecipe) {
        gain = Float(recipe[.sharpenAmount] / 100)
        sigma = Float(recipe[.sharpenRadius]) * 0.8
        let detail = Float(recipe[.sharpenDetail] / 100)
        haloScale = 0.08 + 0.9 * detail * detail
        deconvolution = detail
        let masking = Float(recipe[.sharpenMasking] / 100)
        edgeThreshold = 0.3 * masking * masking
        decomposition = recipe.processVersion >= 11
    }

    /// The blur sigma in texels of a pyramid level; nil where it is too fine to show.
    func sigma(atLevel level: Int) -> Float? {
        let texels = sigma / Float(1 << level)
        return texels >= 0.3 ? texels : nil
    }

    /// How many texels the Gaussian of `sigma` texels reaches each way.
    static func blurRadius(sigma: Float) -> Int {
        min(Int((3 * max(sigma, 1e-3)).rounded(.up)), 12)
    }
}

/// Texture and Clarity: gains on two bands of log-luminance detail, taken from the session's
/// pyramid. Texture's band spans about 2 to 8 full-resolution pixels, Clarity's about 8 to 64;
/// negative values smooth instead. Values are slider / 100; the kernel maps them to gains, after
/// adding masks' amounts.
struct LocalContrastSettings: Hashable {
    static let textureLevels = 1 ... 3
    static let clarityLevels = 3 ... 6

    var texture: Float
    var clarity: Float
    /// Process 9: Clarity's band ends at an edge-preserving base (`ClarityBase`) instead of a level.
    var edgeAware: Bool
    /// Process 11: both bands come from the ladder (`Ladder`) of the noise-reduced luminance.
    var decomposition: Bool
    /// Clarity's detail saturates at about this many stops, which holds back halos.
    static let clarityLimit: Float = 0.5
    /// Process 11: Texture's detail saturates at about this many stops, so the step of an edge
    /// isn't boosted into halos while texture, well under it, is. REDLAMP_TEXTURE_LIMIT
    /// overrides it, to tune.
    static let textureLimit = Float(ProcessInfo.processInfo.environment["REDLAMP_TEXTURE_LIMIT"] ?? "") ?? 0.25
    /// Process 11: positive Texture's gain on its band, per unit of the slider, so texture shows
    /// about as strongly as at process 9 though the limit takes some off it. REDLAMP_TEXTURE_GAIN
    /// overrides it, to tune.
    static let textureGain = Float(ProcessInfo.processInfo.environment["REDLAMP_TEXTURE_GAIN"] ?? "") ?? 1.6

    init(recipe: EditRecipe) {
        texture = Float(recipe[.texture] / 100)
        clarity = Float(recipe[.clarity] / 100)
        edgeAware = recipe.processVersion >= 9
        decomposition = recipe.processVersion >= 11
    }

    /// Process 11: Texture's weight when rendering at `level`, where the texels stand in for the
    /// band's finer levels, so a preview shows what a downscaled full-resolution render does
    /// (`PreviewExportTests`).
    static func textureWeight(level: Int) -> Float {
        textureWeights[min(max(level, 0), 4)]
    }

    private static let textureWeights: [Float] = {
        let tuned = (ProcessInfo.processInfo.environment["REDLAMP_TEXTURE_WEIGHTS"] ?? "")
            .split(separator: ",").compactMap { Float($0) }
        return tuned.count == 5 ? tuned : [1, 0.994, 1.11, 0.70, 0.415]
    }()

    var isActive: Bool {
        texture != 0 || clarity != 0
    }

    /// A band's pyramid levels when rendering at `level`: detail finer than the rendered
    /// texels drops out, as it would when a full-resolution result is downscaled. With
    /// `keepsRendered`, a band reaching the rendered level keeps the texels' own detail (the
    /// kernel reads them rather than their smoothed level), down to the band's coarse level: a
    /// downscaled full-resolution result keeps that octave of fine bands such as Texture.
    static func band(
        _ levels: ClosedRange<Int>, renderedAt level: Int, levelCount: Int, keepsRendered: Bool = false,
    ) -> ClosedRange<Int>? {
        let fine = max(levels.lowerBound, level)
        let coarse = min(levels.upperBound, levelCount - 1)
        return fine < coarse || (keepsRendered && fine == coarse && level > 0) ? fine ... coarse : nil
    }
}

/// Masks' Texture, Clarity, Sharpness and Noise: each visible mask using them, with its amounts
/// (slider / 100, scaled by the mask's Amount) in that order.
struct LocalDetail: Hashable {
    struct Layer: Hashable {
        var components: [MaskComponent]
        var amounts: SIMD4<Float>
        var detail: Double = 0
    }

    var layers: [Layer] = []
    /// The masks the layers reuse as components.
    var referenced: [MaskLayer] = []
    /// The edit guide's version, when a range component reads it.
    var guideGeneration = 0

    var readsEditGuide: Bool {
        (layers.flatMap(\.components) + referenced.flatMap(\.components)).contains { $0.shape.readsEditGuide }
    }

    init(recipe: EditRecipe) {
        var components = 0
        for mask in recipe.masks where mask.isVisible && !mask.components.isEmpty {
            let amounts = SIMD4<Float>(
                Float(mask[.localTexture]), Float(mask[.localClarity]),
                Float(mask[.localSharpness]), Float(mask[.localNoise]),
            ) * Float(mask.amount / 100 / 100)
            guard amounts != .zero, layers.count < MaskLayer.maximumLayers,
                  components + mask.components.count <= MaskLayer.maximumComponents
            else {
                continue
            }
            layers.append(Layer(components: mask.components, amounts: amounts, detail: mask.detail))
            components += mask.components.count
        }
        let ids = Set(layers.flatMap { MaskLayer(name: "", components: $0.components).referencedMasks })
        referenced = recipe.masks.filter { ids.contains($0.id) }
    }

    var isEmpty: Bool {
        layers.isEmpty
    }

    /// Whether any mask sets this amount (0 Texture, 1 Clarity, 2 Sharpness, 3 Noise).
    func uses(_ amount: Int) -> Bool {
        layers.contains { $0.amounts[amount] != 0 }
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
        /// Valid only in the command buffer the stage encoded into: once that completes, the
        /// system may reclaim it.
        let texture: any MTLTexture
        /// The area the texture covers: xy origin, zw size, in normalised source coordinates.
        let area: SIMD4<Float>
    }

    /// Texels of context around the work area, enough for the widest à-trous scale. Its luma
    /// energy neighbourhood reaches 16 further, but only through the outermost taps of every
    /// scale, which weigh too little to show in half floats.
    static let margin = 64

    /// Whether the recipe needs the stage at full resolution.
    static func isActive(_ recipe: EditRecipe) -> Bool {
        DenoiseSettings(recipe: recipe).isActive || SharpenSettings(recipe: recipe).gain > 0
            || LocalContrastSettings(recipe: recipe).isActive || !LocalDetail(recipe: recipe).isEmpty
    }

    private let device: any MTLDevice
    let kernels: KernelLibrary

    private struct Key: Equatable {
        var session: ObjectIdentifier
        var work: WorkArea
        var denoise: DenoiseSettings?
        var sharpen: SharpenSettings?
        var contrast: LocalContrastSettings?
        var local: LocalDetail
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
    /// The largest work area whose ladder is cached, 18 bytes a texel: a 5K display's view at
    /// 1:1 with its margins. Larger areas keep only the noise-reduced source, 8 bytes a texel, out
    /// of the scratch budget, and take the ladder on every render.
    var ladderCacheTexels = 16 << 20
    /// Per work area: a comparison's two edits.
    private static let maximumEntriesPerArea = 2

    /// The scratch textures' bytes, whatever the photo and zoom: work areas whose passes would
    /// need more are processed in tiles. A little under 720 MB, for the textures' padding.
    var scratchBudget = 704 << 20
    /// Texels taken off the overlap tiles need, which only a test that the overlap matters sets.
    var haloShortfall = 0

    let residency = DetailResidency()
    let sharpenCache: SharpenCache
    let ladderCache: LadderCache
    /// Process 11's Clarity base per photo, in the ladder's luminance, made when first needed.
    var clarityBases: [(owner: ImageSession, texture: any MTLTexture)] = []
    /// Each format's working textures by slot, allocated as passes first use them, for one photo.
    private var scratch: [MTLPixelFormat: [Int: any MTLTexture]] = [:]
    private var scratchPhoto: PhotoKey?
    /// While tiles are encoded, the largest one's size: every scratch texture is made that size.
    private var scratchFloor: SIMD2<Int>?
    /// The texels a scratch texture may grow to in the render being encoded.
    private var scratchLimit = 0
    private var layout: (key: LayoutKey, tiles: [Tile])?
    /// The command buffer being encoded and the textures cached from it, which `forget` forgets.
    private var encoding: Encoding?
    /// Textures made so far and their bytes.
    private(set) var allocated = (count: 0, bytes: 0)
    /// The tiles the last render was processed in.
    private(set) var tileCount = 0
    /// Noise reductions encoded so far, a tiled one once per tile; sharpening's separator isn't one.
    private(set) var noiseReductions = 0

    private struct PhotoKey: Equatable {
        var url: URL
        var size: PixelSize
    }

    private struct LayoutKey: Equatable {
        var size: SIMD2<Int>
        var halo: Int
        var limit: Int
        var shape: SIMD2<Int>?
    }

    private var emptyMasks: (rasters: any MTLTexture, guide: any MTLTexture, edges: any MTLTexture)?

    init(device: any MTLDevice, kernels: KernelLibrary) {
        self.device = device
        self.kernels = kernels
        sharpenCache = SharpenCache(residency: residency)
        ladderCache = LadderCache(residency: residency)
    }

    /// Every texture the stage keeps between renders.
    var heldTextures: [any MTLTexture] {
        scratch.values.flatMap(\.values) + cachedOutputs + sharpenCache.heldTextures + ladderCache.heldTextures
    }

    var cachedOutputs: [any MTLTexture] {
        entries.map(\.output.texture)
    }

    private func emptyMaskImages() throws -> (rasters: any MTLTexture, guide: any MTLTexture, edges: any MTLTexture) {
        if let emptyMasks {
            return emptyMasks
        }
        let images = try MaskResources.emptyImages(device: device)
        emptyMasks = images
        return images
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
        masks: MaskBindings = .none,
    ) throws -> Output? {
        guard outputSize.width > 0 else { return nil }
        let geometry = GeometryMap(recipe: recipe, imageSize: session.orientedSize, lens: session.info.lensCorrection)
        let work = Self.workArea(session: session, geometry: geometry, region: region, outputSize: outputSize)
        guard let passes = Self.passes(recipe, session: session, level: work.level, masks: masks) else { return nil }
        let key = Key(
            session: ObjectIdentifier(session), work: work, denoise: passes.denoise, sharpen: passes.sharpen,
            contrast: passes.contrast, local: passes.local,
        )
        if residency.hasDropped {
            dropTextures()
        }
        residency.hold(until: commands)
        if encoding?.commands !== commands {
            encoding = Encoding(commands: commands)
        }
        do {
            return try process(key, passes, session: session, work: work, commands: commands, cache: cache)
        } catch {
            abandon(commands)
            throw error
        }
    }

    /// The passes `recipe` needs at a work level: nil when it needs none.
    static func passes(_ recipe: EditRecipe, session: ImageSession, level: Int, masks: MaskBindings) -> Passes? {
        let denoiseSettings = DenoiseSettings(recipe: recipe)
        let sharpenSettings = SharpenSettings(recipe: recipe)
        let contrastSettings = LocalContrastSettings(recipe: recipe)
        var local = LocalDetail(recipe: recipe)
        if local.readsEditGuide {
            local.guideGeneration = masks.guideGeneration
        }
        let denoise = denoiseSettings.isActive || local.uses(3) ? denoiseSettings : nil
        let sharpen = sharpenSettings.sigma(atLevel: level) != nil && (sharpenSettings.gain > 0 || local.uses(2))
            ? sharpenSettings : nil
        let contrast = contrastSettings.isActive || local.uses(0) || local.uses(1) ? contrastSettings : nil
        guard denoise != nil || sharpen != nil || contrast != nil else { return nil }
        return Passes(
            session: session, denoise: denoise, sharpen: sharpen, contrast: contrast, local: local, masks: masks,
        )
    }

    private func process(
        _ key: Key,
        _ passes: Passes,
        session: ImageSession,
        work: WorkArea,
        commands: any MTLCommandBuffer,
        cache: Bool,
    ) throws -> Output {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            if residency.wake(entry.output.texture) {
                entries.append(entry)
                return entry.output
            }
        }
        let photo = PhotoKey(url: session.info.url, size: session.info.pixelSize)
        if photo != scratchPhoto {
            scratch.removeAll()
            layout = nil
            scratchPhoto = photo
        }

        let texture = try makeWorkTexture(.rgba16Float, work)
        let sigma = key.sharpen?.sigma(atLevel: work.level) ?? 0
        let ladderKey = passes.decomposes
            ? LadderKey(session: key.session, work: work, denoise: key.denoise, local: key.local) : nil
        var ladder = ladderKey.map { LadderMeasures(ladder: ladderCache.ladder($0)) }
        let cachesLadder = cache && work.size.x * work.size.y <= ladderCacheTexels
        // Kept only where it leaves at least half the scratch budget for the tiles.
        let keepsDenoised = cache && !cachesLadder && key.denoise != nil && ladder != nil
            && Self.allocatedTexels(work.size) * 8 <= scratchBudget / 2
        if keepsDenoised, ladder?.ladder == nil, let ladderKey {
            ladder?.denoised = ladderCache.denoised(ladderKey)
        }
        // Before process 11, an area the ladder's size keeps its noise-reduced source as process 11's
        // larger areas do, outside the scratch budget as a ladder is.
        let sourceKey = cache && !passes.decomposes && key.denoise != nil && (key.sharpen != nil || key.contrast != nil)
            && work.size.x * work.size.y <= ladderCacheTexels
            ? LadderKey(session: key.session, work: work, denoise: key.denoise, local: key.local) : nil
        var kept = sourceKey.map { KeptSource(given: ladderCache.denoised($0)) }
        if kept != nil, kept?.given == nil {
            kept?.target = try makeWorkTexture(.rgba16Float, work)
        }
        let denoised = kept?.given != nil
        var measures = key.sharpen.map { _ in
            cachedSharpenMeasures(session, work: work, sigma: sigma, ladder: ladderKey)
        }
        // With the analysis cached and nothing else to run, the final pass reads only the texel
        // itself, so it needs no tiles whatever the area.
        let appliesOnly = if ladder != nil {
            ladder?.ladder != nil && key.local.isEmpty && (key.sharpen == nil || measures?.analysis != nil)
        } else {
            key.denoise == nil && key.contrast == nil && key.local.isEmpty && measures?.analysis != nil
        }
        // The noise-reduced source a large area keeps comes out of the scratch budget, so the
        // stage holds no more than it would without it.
        let keeping = keepsDenoised && ladder?.ladder == nil && ladder?.denoised == nil
        scratchLimit = tileLimit(
            passes, measures: measures, ladder: ladder, denoised: denoised,
            reserved: keeping ? Self.allocatedTexels(work.size) * 8 : 0,
        )
        let tiles = appliesOnly ? [Tile(whole: work)] : tileLayout(
            work,
            halo: passes.halo(level: work.level, measures: measures, ladder: ladder, denoised: denoised),
            limit: scratchLimit,
        )
        tileCount = tiles.count
        if tiles.count == 1 {
            if measures != nil, measures?.analysis == nil {
                measures?.analysisTarget = try makeWorkTexture(.rgba16Float, work)
                if measures?.separation == nil {
                    measures?.separationTarget = try cache && ladder == nil
                        ? makeWorkTexture(.r16Float, work) : scratchTexture(.r16Float, 0, work)
                }
            }
            if ladder != nil, ladder?.ladder == nil {
                ladder?.target = try cachesLadder
                    ? makeLadder(work, denoised: key.denoise != nil) : scratchLadder(work, denoised: key.denoise != nil)
                if keepsDenoised {
                    if ladder?.denoised == nil {
                        ladder?.denoisedTarget = try makeWorkTexture(.rgba16Float, work)
                    }
                    let source = ladder?.denoised ?? ladder?.denoisedTarget
                    ladder?.target?.denoised = source
                }
            }
            guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
            encoder.label = "Detail"
            let reduced = try encode(
                passes, work: work, into: texture, measures: measures, ladder: ladder, kept: kept, encoder: encoder,
            )
            encoder.endEncoding()
            if let target = kept?.target, let reduced {
                guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
                blit.copy(from: reduced, origin: .zero, size: work.size, to: target, at: .zero)
                blit.endEncoding()
            }
        } else {
            if cache, measures != nil, measures?.analysis == nil {
                measures?.analysisTarget = try makeWorkTexture(.rgba16Float, work)
                if measures?.separation == nil, ladder == nil {
                    measures?.separationTarget = try makeWorkTexture(.r16Float, work)
                }
            }
            if cachesLadder, ladder != nil, ladder?.ladder == nil {
                ladder?.target = try makeLadder(work, denoised: key.denoise != nil)
            }
            if keepsDenoised, ladder?.ladder == nil, ladder?.denoised == nil {
                ladder?.denoisedTarget = try makeWorkTexture(.rgba16Float, work)
            }
            try encodeTiles(
                tiles, passes, work: work, into: texture, measures: measures, ladder: ladder, kept: kept,
                commands: commands,
            )
        }
        if cache, let measures {
            storeSharpenMeasures(measures, session, work: work, sigma: sigma, ladder: ladderKey)
        }
        if let sourceKey, let target = kept?.target {
            ladderCache.keep(denoised: target, key: sourceKey, owner: session)
            encoding?.cached.insert(ObjectIdentifier(target))
        }
        if cachesLadder, let ladderKey, ladder?.ladder == nil, let target = ladder?.target {
            ladderCache.store(target, key: ladderKey, owner: session)
            target.textures.forEach { encoding?.cached.insert(ObjectIdentifier($0)) }
        }
        if let ladderKey, let denoised = ladder?.denoisedTarget {
            ladderCache.store(denoised: denoised, key: ladderKey, owner: session)
            encoding?.cached.insert(ObjectIdentifier(denoised))
        }

        let levelWidth = Float(max(1, session.pyramid.width >> work.level))
        let levelHeight = Float(max(1, session.pyramid.height >> work.level))
        let output = Output(texture: texture, area: SIMD4(
            Float(work.origin.x) / levelWidth, Float(work.origin.y) / levelHeight,
            Float(work.size.x) / levelWidth, Float(work.size.y) / levelHeight,
        ))
        if cache {
            residency.wake(texture)
            encoding?.cached.insert(ObjectIdentifier(texture))
            let sameArea = entries.indices
                .filter { entries[$0].key.session == key.session && entries[$0].key.work == work }
            if sameArea.count >= Self.maximumEntriesPerArea {
                entries.remove(at: sameArea[0])
            }
            entries.append(Entry(key: key, session: session, output: output))
            if entries.count > Self.maximumEntries {
                entries.removeFirst()
            }
        }
        return output
    }

    /// Forgets what was cached from `commands`, which will never run, and stops keeping its
    /// textures resident. For a render that failed after the stage encoded into it.
    func abandon(_ commands: any MTLCommandBuffer) {
        residency.abandon(commands)
        dropTextures()
    }

    /// Forgets what was cached from `commands`, which failed on the GPU, so its textures hold
    /// nothing rendered.
    func forget(_ commands: any MTLCommandBuffer) {
        guard let encoding, encoding.commands === commands else { return }
        entries.removeAll { encoding.cached.contains(ObjectIdentifier($0.output.texture)) }
        sharpenCache.forget(encoding.cached)
        ladderCache.forget(encoding.cached)
        self.encoding = nil
    }

    /// Lets go of every texture, for a command buffer dropped uncommitted. Metal's validation
    /// layer then counts the textures encoded into it as in use for good, and aborts when one is
    /// made volatile, so none of them is parked.
    private func dropTextures() {
        entries.removeAll()
        sharpenCache.removeAll()
        ladderCache.removeAll()
        scratch.removeAll()
        layout = nil
        encoding = nil
        residency.reset()
    }

    /// Weak, so a later command buffer at a released one's address isn't taken for it.
    private struct Encoding {
        weak var commands: (any MTLCommandBuffer)?
        var cached: Set<ObjectIdentifier> = []
    }

    /// What one render of the stage runs, for any work area or tile of it.
    struct Passes {
        var session: ImageSession
        var denoise: DenoiseSettings?
        var sharpen: SharpenSettings?
        var contrast: LocalContrastSettings?
        var local: LocalDetail
        var masks: MaskBindings

        /// Process 11: Texture, Clarity and sharpening read the ladder (`Ladder`).
        var decomposes: Bool {
            (sharpen?.decomposition ?? contrast?.decomposition) ?? false
        }

        var softens: Bool {
            local.layers.contains { $0.amounts[2] < 0 }
        }

        /// How far around a texel, in work texels, the passes read: tiles overlapping by this much
        /// render exactly what one pass over the work area does. Masks' amounts, Texture and
        /// Clarity read their source at the texel itself. What `measures` already holds, each tile
        /// copies rather than computes, and a `denoised` source given it reads in place.
        func halo(
            level: Int,
            measures: SharpenMeasures?,
            ladder: LadderMeasures? = nil,
            denoised: Bool = false,
        ) -> Int {
            if decomposes {
                return decomposedHalo(level: level, measures: measures, ladder: ladder)
            }
            var reach = denoised ? 0 : denoise?.reach(level: level) ?? 0
            if let sigma = sharpen?.sigma(atLevel: level) {
                let blur = SharpenSettings.blurRadius(sigma: sigma)
                // The analysis: the separator's denoising, then two blurs per Richardson-Lucy
                // iteration; the final pass reads its gradient for Masking. Softening blurs the
                // source.
                let separation = measures?.separation == nil ? DenoiseSettings.separator.reach(level: level) : 0
                let analysis = measures?.analysis == nil ? separation + 2 * SharpenSettings.iterations * blur : 0
                reach = max(reach + (softens ? blur : 0), analysis + 1)
            }
            return reach
        }

        /// Process 11: the ladder reads the noise reduction's result, and sharpening's analysis
        /// the ladder; the final pass reads them at the texel, and the analysis's gradient.
        private func decomposedHalo(level: Int, measures: SharpenMeasures?, ladder: LadderMeasures?) -> Int {
            let cached = ladder?.ladder != nil
            let source = cached || ladder?.denoised != nil ? 0 : denoise?.reach(level: level) ?? 0
            let decomposition = cached ? 0 : source + Ladder.reach
            var reach = decomposition
            if let sigma = sharpen?.sigma(atLevel: level) {
                let blur = SharpenSettings.blurRadius(sigma: sigma)
                let analysis = measures?.analysis == nil ? decomposition + 2 * SharpenSettings.iterations * blur : 0
                reach = max(reach, softens ? source + blur : 0, analysis + 1)
            }
            return reach
        }

        /// The scratch textures the passes use when tiled, given what `measures` and `ladder` hold
        /// and whether the `denoised` source is given.
        func scratchSlots(
            measures: SharpenMeasures?, ladder: LadderMeasures? = nil, denoised: Bool = false,
        ) -> Set<ScratchSlot> {
            func rgba(_ indices: Int...) -> [ScratchSlot] {
                indices.map { ScratchSlot(format: .rgba16Float, index: $0) }
            }
            if decomposes {
                // A tile copies a cached ladder into scratch, or takes it there.
                var slots = Set(rgba(9, 11) + [ScratchSlot(format: .r16Float, index: 5)])
                if !local.isEmpty {
                    slots.formUnion(rgba(6))
                }
                if denoise != nil, ladder?.ladder != nil || ladder?.denoised == nil {
                    slots.formUnion(rgba(4))
                }
                if ladder?.ladder == nil {
                    slots.formUnion([1, 2, 3].map { ScratchSlot(format: .r32Float, index: $0) })
                    if denoise != nil, ladder?.denoised == nil {
                        slots.formUnion(rgba(0, 1, 2, 3, 8))
                    }
                }
                guard sharpen != nil else { return slots }
                slots.formUnion(rgba(10) + [ScratchSlot(format: .r16Float, index: 0)])
                if measures?.analysis == nil {
                    slots.formUnion([1, 2, 3].map { ScratchSlot(format: .r32Float, index: $0) })
                    slots.formUnion((1 ... 4).map { ScratchSlot(format: .r16Float, index: $0) })
                }
                if softens {
                    slots.formUnion([0, 2, 4].map { ScratchSlot(format: .r32Float, index: $0) })
                }
                return slots
            }
            var slots = Set(rgba(9))
            let reduces = denoise != nil && !denoised
            let count = [reduces, sharpen != nil, contrast != nil].count(where: \.self)
            slots.formUnion(rgba(4, 5).prefix(max(count - 1, 0)))
            if !local.isEmpty {
                slots.formUnion(rgba(6))
            }
            let separates = sharpen != nil && measures?.analysis == nil && measures?.separation == nil
            if reduces || separates {
                slots.formUnion(rgba(0, 1, 2, 3, 8))
            }
            guard sharpen != nil else { return slots }
            slots.formUnion(rgba(10) + [ScratchSlot(format: .r16Float, index: 0)])
            if separates {
                slots.formUnion(rgba(7))
            }
            if measures?.analysis == nil {
                slots.formUnion([1, 2, 3].map { ScratchSlot(format: .r32Float, index: $0) })
                slots.formUnion((1 ... 4).map { ScratchSlot(format: .r16Float, index: $0) })
            }
            if softens {
                slots.formUnion([0, 2, 4].map { ScratchSlot(format: .r32Float, index: $0) })
            }
            return slots
        }
    }

    struct ScratchSlot: Hashable {
        var format: MTLPixelFormat
        var index: Int

        var bytesPerTexel: Int {
            switch format {
            case .rgba16Float: 8
            case .r32Float: 4
            default: 2
            }
        }
    }

    /// The scratch slots held now.
    var scratchSlots: Set<ScratchSlot> {
        Set(scratch.flatMap { format, textures in textures.keys.map { ScratchSlot(format: format, index: $0) } })
    }

    /// Metal allocates textures in 64-texel blocks each way.
    static func allocatedTexels(_ size: SIMD2<Int>) -> Int {
        (size.x + 63) / 64 * 64 * ((size.y + 63) / 64 * 64)
    }

    /// The most texels a tile of `passes` may cover, extent included, so the scratch textures
    /// they use, at that size, those held for other passes and `reserved` bytes fit the budget.
    func tileLimit(
        _ passes: Passes, measures: SharpenMeasures?, ladder: LadderMeasures? = nil, denoised: Bool = false,
        reserved: Int = 0,
    ) -> Int {
        let slots = passes.scratchSlots(measures: measures, ladder: ladder, denoised: denoised)
        let others = scratch.flatMap { format, textures in
            textures.filter { !slots.contains(ScratchSlot(format: format, index: $0.key)) }.values
        }
        let available = scratchBudget - reserved - others.reduce(0) { $0 + $1.allocatedSize }
        return max(available, 0) / slots.reduce(0) { $0 + $1.bytesPerTexel }
    }

    /// Before process 11: the noise-reduced source a work area keeps, read at `origin` when given;
    /// otherwise noise is reduced and copied into `target`.
    struct KeptSource {
        var given: (any MTLTexture)?
        var origin: SIMD2<Int> = .zero
        var target: (any MTLTexture)?
    }

    /// Encodes `passes` over `work`, the last writing `output`. Returns the noise reduction's
    /// result, when it ran before process 11.
    @discardableResult
    private func encode(
        _ passes: Passes,
        work: WorkArea,
        into output: any MTLTexture,
        measures: SharpenMeasures?,
        ladder: LadderMeasures?,
        kept: KeptSource? = nil,
        encoder: any MTLComputeCommandEncoder,
    ) throws -> (any MTLTexture)? {
        if let ladder {
            try encodeDecomposed(passes, work: work, into: output, measures: measures, ladder: ladder, encoder: encoder)
            return nil
        }
        let session = passes.session
        let amounts = passes.local.isEmpty ? nil : try encodeLocal(
            session: session,
            local: passes.local,
            work: work,
            masks: passes.masks,
            encoder: encoder,
        )
        // Each pass reads the previous one's result; the last writes the output.
        var remaining = [passes.denoise != nil, passes.sharpen != nil, passes.contrast != nil].filter(\.self).count
        var source = Source(texture: session.pyramid, origin: work.origin, level: work.level)
        func target() throws -> any MTLTexture {
            remaining -= 1
            guard remaining > 0 else { return output }
            // Alternate between two intermediates, never the one being read.
            let first = try scratchTexture(.rgba16Float, 4, work)
            return first === source.texture ? try scratchTexture(.rgba16Float, 5, work) : first
        }
        var reduced: (any MTLTexture)?
        if let given = kept?.given, let origin = kept?.origin {
            remaining -= 1
            source = Source(texture: given, origin: origin, level: 0)
        } else if let denoise = passes.denoise {
            let output = try target()
            try encodeDenoise(
                session: session, settings: denoise, work: work, local: amounts, into: output, encoder: encoder,
            )
            source = Source(texture: output, origin: .zero, level: 0)
            reduced = output
        }
        if let sharpen = passes.sharpen {
            guard let measures else { throw EngineError.renderFailed("sharpening without its measures") }
            let output = try target()
            try encodeSharpen(SharpenRequest(
                session: session, settings: sharpen, work: work, source: source, local: amounts,
                softens: passes.softens, measures: measures,
            ), into: output, encoder: encoder)
            source = Source(texture: output, origin: .zero, level: 0)
        }
        if let contrast = passes.contrast {
            try encodeLocalContrast(
                session: session, settings: contrast, work: work, source: source, local: amounts, into: target(),
                encoder: encoder,
            )
        }
        return reduced
    }

    /// What sharpening has cached of `work`: its analysis, or failing that its separation.
    private func cachedSharpenMeasures(
        _ session: ImageSession,
        work: WorkArea,
        sigma: Float,
        ladder: LadderKey?,
    ) -> SharpenMeasures {
        if let analysis = sharpenCache.analysis(session, work, sigma: sigma, ladder: ladder) {
            return SharpenMeasures(analysis: analysis)
        }
        // Process 11's separation comes from the ladder in one pass, so it isn't cached.
        return SharpenMeasures(separation: ladder == nil ? sharpenCache.separation(session, work) : nil)
    }

    private func storeSharpenMeasures(
        _ measures: SharpenMeasures,
        _ session: ImageSession,
        work: WorkArea,
        sigma: Float,
        ladder: LadderKey?,
    ) {
        guard measures.analysis == nil, let analysis = measures.analysisTarget else { return }
        sharpenCache.store(analysis: analysis, session, work, sigma: sigma, ladder: ladder)
        encoding?.cached.insert(ObjectIdentifier(analysis))
        if ladder == nil, measures.separation == nil, let separation = measures.separationTarget {
            sharpenCache.store(separation: separation, session, work)
            encoding?.cached.insert(ObjectIdentifier(separation))
        }
    }

    // MARK: - Tiles

    struct Tile {
        /// The texels the tile renders, relative to the work area's origin.
        var interior: (origin: SIMD2<Int>, size: SIMD2<Int>)
        /// The interior with the halo around it, clamped to the work area.
        var extent: (origin: SIMD2<Int>, size: SIMD2<Int>)

        init(interior: (origin: SIMD2<Int>, size: SIMD2<Int>), extent: (origin: SIMD2<Int>, size: SIMD2<Int>)) {
            self.interior = interior
            self.extent = extent
        }

        init(whole work: WorkArea) {
            self.init(interior: (.zero, work.size), extent: (.zero, work.size))
        }
    }

    /// The tiles for `work`, preferring ones that fit the scratch textures already made and
    /// reusable at `limit`; the last layout is kept, since a drag asks for the same one every frame.
    private func tileLayout(_ work: WorkArea, halo: Int, limit: Int) -> [Tile] {
        let shape = scratch.values.flatMap(\.values).map { SIMD2($0.width, $0.height) }.filter { $0.x * $0.y <= limit }
            .reduce(nil) { shape, size in shape.map { simd_min($0, size) } ?? size }
        let key = LayoutKey(size: work.size, halo: max(halo - haloShortfall, 0), limit: limit, shape: shape)
        if let layout, layout.key == key {
            return layout.tiles
        }
        let tiles = Self.tiles(work, halo: key.halo, limit: key.limit, fitting: shape)
        layout = (key, tiles)
        return tiles
    }

    /// The fewest tiles covering `work`, then the fewest texels in all, whose largest extent
    /// (the size of the scratch textures) covers at most `limit` texels: the whole of it when it
    /// fits. Every tile costs a few passes' fixed overhead. Of those, a layout whose tiles fit in
    /// `shape` is taken when it costs at most a quarter more texels. Interior edges and extents'
    /// starts fall on multiples of 32: non-local means decides per block of texels within each
    /// 32×32 group whether to search, so a tile must group texels as the whole area does.
    static func tiles(_ work: WorkArea, halo: Int, limit: Int, fitting shape: SIMD2<Int>? = nil) -> [Tile] {
        func edges(_ length: Int, _ count: Int) -> [Int] {
            let step = (length + count - 1) / count
            let aligned = (step + 31) / 32 * 32
            return Array(Set((0 ... count).map { min($0 * aligned, length) })).sorted()
        }
        func layout(_ columns: Int, _ rows: Int) -> [Tile] {
            let xs = edges(work.size.x, columns), ys = edges(work.size.y, rows)
            return zip(ys, ys.dropFirst()).flatMap { y0, y1 in
                zip(xs, xs.dropFirst()).map { x0, x1 in
                    let low = SIMD2(max(0, x0 - halo) / 32 * 32, max(0, y0 - halo) / 32 * 32)
                    let high = SIMD2(min(work.size.x, x1 + halo), min(work.size.y, y1 + halo))
                    return Tile(interior: (SIMD2(x0, y0), SIMD2(x1 - x0, y1 - y0)), extent: (low, high &- low))
                }
            }
        }
        let allocated = Self.allocatedTexels
        guard allocated(work.size) > limit else { return [Tile(whole: work)] }
        let candidates = (1 ... 16).flatMap { columns in (1 ... 16).map { layout(columns, $0) } }.filter { tiles in
            allocated(tiles.map(\.extent.size).reduce(.zero, simd_max)) <= limit
        }
        func texels(_ tiles: [Tile]) -> Int {
            tiles.reduce(0) { $0 + $1.extent.size.x * $1.extent.size.y }
        }
        guard let count = candidates.map(\.count).min() else { return [Tile(whole: work)] }
        let fewest = candidates.filter { $0.count == count }.map { (texels: texels($0), tiles: $0) }
        let best = fewest.min { $0.texels < $1.texels }
        let fitting = fewest.filter { candidate in
            shape.map { shape in
                candidate.tiles.allSatisfy { $0.extent.size.x <= shape.x && $0.extent.size.y <= shape.y }
            } ?? false
        }.min { $0.texels < $1.texels }
        if let best, let fitting, fitting.texels * 4 <= best.texels * 5 {
            return fitting.tiles
        }
        return best?.tiles ?? [Tile(whole: work)]
    }

    /// Encodes `passes` tile by tile, copying each tile's interior into `output`, and into the
    /// sharpening measures' and kept source's targets when there are any.
    private func encodeTiles(
        _ tiles: [Tile],
        _ passes: Passes,
        work: WorkArea,
        into output: any MTLTexture,
        measures whole: SharpenMeasures?,
        ladder wholeLadder: LadderMeasures?,
        kept wholeKept: KeptSource?,
        commands: any MTLCommandBuffer,
    ) throws {
        scratchFloor = tiles.map(\.extent.size).reduce(.zero, simd_max)
        defer { scratchFloor = nil }
        for tile in tiles {
            let area = WorkArea(level: work.level, origin: work.origin &+ tile.extent.origin, size: tile.extent.size)
            let rendered = try scratchTexture(.rgba16Float, 9, area)
            var measures: SharpenMeasures?
            if let whole {
                let analysis = try scratchTexture(.rgba16Float, 10, area)
                let separation = try scratchTexture(.r16Float, 0, area)
                let given = whole.analysis.map { ($0, analysis) } ?? whole.separation.map { ($0, separation) }
                if let (cached, copy) = given {
                    guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
                    blit.copy(from: cached, origin: tile.extent.origin, size: tile.extent.size, to: copy, at: .zero)
                    blit.endEncoding()
                }
                measures = SharpenMeasures(
                    analysis: whole.analysis == nil ? nil : analysis,
                    separation: whole.separation == nil ? nil : separation,
                    analysisTarget: analysis,
                    separationTarget: separation,
                )
            }
            var ladder: LadderMeasures?
            if let wholeLadder {
                let kept = wholeLadder.ladder == nil ? wholeLadder.denoised : nil
                var tileLadder = try scratchLadder(area, denoised: passes.denoise != nil && kept == nil)
                if let cached = wholeLadder.ladder {
                    guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
                    for (texture, copy) in zip(cached.textures, tileLadder.textures) {
                        blit.copy(
                            from: texture,
                            origin: tile.extent.origin,
                            size: tile.extent.size,
                            to: copy,
                            at: .zero,
                        )
                    }
                    blit.endEncoding()
                    ladder = LadderMeasures(ladder: tileLadder)
                } else if let kept {
                    tileLadder.denoised = kept
                    tileLadder.denoisedOrigin = tile.extent.origin
                    ladder = LadderMeasures(target: tileLadder, denoised: kept)
                } else {
                    ladder = LadderMeasures(target: tileLadder)
                }
            }
            guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
            encoder.label = "Detail tile"
            let reduced = try encode(
                passes, work: area, into: rendered, measures: measures, ladder: ladder,
                kept: wholeKept?.given.map { KeptSource(given: $0, origin: tile.extent.origin) }, encoder: encoder,
            )
            encoder.endEncoding()

            guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
            let inside = tile.interior.origin &- tile.extent.origin
            blit.copy(from: rendered, origin: inside, size: tile.interior.size, to: output, at: tile.interior.origin)
            if let whole = wholeKept?.target, let reduced {
                blit.copy(from: reduced, origin: inside, size: tile.interior.size, to: whole, at: tile.interior.origin)
            }
            if let whole = wholeLadder?.denoisedTarget, let tileDenoised = ladder?.target?.denoised {
                blit.copy(
                    from: tileDenoised, origin: inside, size: tile.interior.size, to: whole, at: tile.interior.origin,
                )
            }
            if let whole = wholeLadder?.target, let tileLadder = ladder?.target {
                for (texture, copy) in zip(tileLadder.textures, whole.textures) {
                    blit.copy(
                        from: texture,
                        origin: inside,
                        size: tile.interior.size,
                        to: copy,
                        at: tile.interior.origin,
                    )
                }
            }
            if let whole, let measures {
                if let analysis = whole.analysisTarget, let tileAnalysis = measures.analysisTarget {
                    blit.copy(
                        from: tileAnalysis, origin: inside, size: tile.interior.size, to: analysis,
                        at: tile.interior.origin,
                    )
                }
                if let separation = whole.separationTarget, let tileSeparation = measures.separationTarget {
                    blit.copy(
                        from: tileSeparation, origin: inside, size: tile.interior.size, to: separation,
                        at: tile.interior.origin,
                    )
                }
            }
            blit.endEncoding()
        }
    }

    // MARK: - Geometry

    struct WorkArea: Hashable {
        var level: Int
        var origin: SIMD2<Int>
        var size: SIMD2<Int>
    }

    /// The pyramid level and texel rectangle (with margin) behind a region of the developed
    /// frame: the bounds of its corners and edge midpoints mapped into the photo (a homography
    /// keeps lines straight; lens distortion bends them a little).
    static func workArea(
        session: ImageSession,
        geometry: GeometryMap,
        region: ImageRect,
        outputSize: PixelSize,
    ) -> WorkArea {
        let developed = geometry.outputSize
        let scale = region.width * Double(developed.width) / Double(max(outputSize.width, 1)) * geometry.pixelScale
        let level = min(max(Int(floor(log2(max(scale, 1)) + 0.01)), 0), session.pyramid.mipmapLevelCount - 1)
        let levelWidth = max(1, session.pyramid.width >> level)
        let levelHeight = max(1, session.pyramid.height >> level)

        let corners = [
            SIMD2(region.x, region.y), SIMD2(region.x + region.width, region.y),
            SIMD2(region.x, region.y + region.height), SIMD2(region.x + region.width, region.y + region.height),
            SIMD2(region.x + region.width / 2, region.y), SIMD2(region.x + region.width / 2, region.y + region.height),
            SIMD2(region.x, region.y + region.height / 2), SIMD2(region.x + region.width, region.y + region.height / 2),
        ].map { corner in
            let image = geometry.imagePoint(corner).map { simd_clamp($0, SIMD2(repeating: 0), SIMD2(repeating: 1)) }
            return sourceCoordinate(image ?? corner, orientation: session.orientation)
        }
        let low = corners.dropFirst().reduce(corners[0], simd_min)
        let high = corners.dropFirst().reduce(corners[0], simd_max)
        let x0 = max(0, Int(floor(low.x * Double(levelWidth))) - margin)
        let y0 = max(0, Int(floor(low.y * Double(levelHeight))) - margin)
        let x1 = min(levelWidth, Int(ceil(high.x * Double(levelWidth))) + margin)
        let y1 = min(levelHeight, Int(ceil(high.y * Double(levelHeight))) + margin)
        return WorkArea(level: level, origin: SIMD2(x0, y0), size: SIMD2(max(1, x1 - x0), max(1, y1 - y0)))
    }

    // MARK: - Encoding

    /// Where a pass reads the work area from: the pyramid at the work level, or an earlier
    /// pass's texture.
    struct Source {
        var texture: any MTLTexture
        var origin: SIMD2<Int>
        var level: Int
    }

    func encodeDenoise(
        session: ImageSession,
        settings: DenoiseSettings,
        work: WorkArea,
        local: (any MTLTexture)?,
        into output: any MTLTexture,
        encoder: any MTLComputeCommandEncoder,
    ) throws {
        if settings != .separator {
            noiseReductions += 1
        }
        // 0-3 here, 4-5 the passes' intermediates, 6 masks' amounts, 7 sharpening's separation,
        // 8 each scale's detail, 9-10 a tile's result and sharpening analysis.
        let textures = try (0 ..< 4).map { try scratchTexture(.rgba16Float, $0, work) }
        let details = try scratchTexture(.rgba16Float, 8, work)
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
        encoder.setTexture(session.noiseGain, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<DenoiseParams>.stride, index: 0)
        encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.denoisePrepare)

        // The energy pass costs about 1 ms at 1:1, so it runs only when luma is shrunk at all.
        let lumaRadius = settings.luma > 0 || local != nil ? settings.lumaRadius : 0
        // Non-local means is for full resolution, where its texture shows and noise is strongest.
        let nonLocal = settings.nonLocalWidth > 0 && work.level == 0 && (settings.luma > 0 || local != nil)
        let sigmas = NoiseCalibration.sigmas(sensor: session.sensor, level: work.level)
        for scale in 0 ..< DenoiseSettings.scaleCount {
            let last = scale == DenoiseSettings.scaleCount - 1
            params.scale = SIMD4(Int32(1 << scale), scale == 0 ? 1 : 0, last ? 1 : 0, local == nil ? 0 : 1)
            params.threshold = SIMD4(
                settings.lumaPerStrength[scale] * sigmas[scale].x, settings.chroma[scale] * sigmas[scale].y,
                settings.chroma[scale] * sigmas[scale].z, settings.luma,
            )
            // This level's luma noise: its own detail and every coarser one's, in quadrature.
            let levelNoise = sigmas[scale...].map { $0.x * $0.x }.reduce(0, +).squareRoot()
            params.edge = SIMD4(DenoiseSettings.chromaEdge * levelNoise, lumaRadius, nonLocal ? 1 : 0, 0)
            if scale == 0 {
                params.nonLocal = SIMD4(DenoiseSettings.nonLocalSearch, 0, settings.nonLocalWidth * levelNoise, 0)
            }

            encoder.setComputePipelineState(kernels.denoiseRows)
            encoder.setTexture(current, index: 0)
            encoder.setTexture(rows, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<DenoiseParams>.stride, index: 0)
            encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.denoiseRows)

            encoder.setComputePipelineState(kernels.denoiseColumns)
            encoder.setTexture(rows, index: 0)
            encoder.setTexture(current, index: 1)
            encoder.setTexture(last && lumaRadius == 0 ? output : next, index: 2)
            encoder.setTexture(result, index: 3)
            encoder.setTexture(local ?? output, index: 4)
            encoder.setTexture(session.pyramid, index: 5)
            encoder.setTexture(session.noiseGain, index: 6)
            encoder.setTexture(details, index: 7)
            encoder.setBytes(&params, length: MemoryLayout<DenoiseParams>.stride, index: 0)
            encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.denoiseColumns)
            if lumaRadius > 0 {
                encoder.setComputePipelineState(kernels.denoiseShrink)
                encoder.setTexture(details, index: 0)
                encoder.setTexture(next, index: 1)
                encoder.setTexture(result, index: 2)
                encoder.setTexture(output, index: 3)
                encoder.setTexture(local ?? output, index: 4)
                encoder.setTexture(session.pyramid, index: 5)
                encoder.setTexture(session.noiseGain, index: 6)
                encoder.setBytes(&params, length: MemoryLayout<DenoiseParams>.stride, index: 0)
                encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.denoiseShrink)
            }
            swap(&current, &next)
        }
        guard nonLocal else { return }
        encoder.setComputePipelineState(kernels.denoiseNonLocal)
        encoder.setTexture(result, index: 0)
        encoder.setTexture(session.pyramid, index: 1)
        encoder.setTexture(session.noiseGain, index: 2)
        encoder.setTexture(local ?? output, index: 3)
        encoder.setTexture(output, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<DenoiseParams>.stride, index: 0)
        // 32×32 tiles, a 2×4 block per thread (see rl_denoise_nonlocal).
        encoder.dispatchThreadgroups(
            MTLSize(width: (work.size.x + 31) / 32, height: (work.size.y + 31) / 32, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1),
        )
    }

    private func encodeLocalContrast(
        session: ImageSession,
        settings: LocalContrastSettings,
        work: WorkArea,
        source: Source,
        local: (any MTLTexture)?,
        into output: any MTLTexture,
        encoder: any MTLComputeCommandEncoder,
    ) {
        let levelCount = session.pyramid.mipmapLevelCount
        let texture = LocalContrastSettings.band(
            LocalContrastSettings.textureLevels, renderedAt: work.level, levelCount: levelCount, keepsRendered: true,
        )
        let clarity = LocalContrastSettings.band(
            LocalContrastSettings.clarityLevels, renderedAt: work.level, levelCount: levelCount,
        )
        var params = LocalContrastParams(
            origin: SIMD4(Int32(source.origin.x), Int32(source.origin.y), Int32(source.level), 0),
            size: SIMD4(Int32(work.size.x), Int32(work.size.y), local == nil ? 0 : 1, 0),
            place: SIMD4(Int32(work.origin.x), Int32(work.origin.y), Int32(work.level), 0),
            levels: SIMD4(
                Int32(texture?.lowerBound ?? 0), Int32(texture?.upperBound ?? 0),
                Int32(clarity?.lowerBound ?? 0), Int32(clarity?.upperBound ?? 0),
            ),
            luma: Self.luma(session),
            shape: SIMD4(
                settings.texture,
                settings.clarity,
                LocalContrastSettings.clarityLimit,
                settings.edgeAware ? ClarityBase.gain : 0,
            ),
        )
        encoder.setComputePipelineState(kernels.localContrast)
        encoder.setTexture(source.texture, index: 0)
        encoder.setTexture(session.pyramid, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setTexture(local ?? output, index: 3)
        encoder.setTexture(session.clarityBase, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<LocalContrastParams>.stride, index: 0)
        encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.localContrast)
    }

    /// Masks' amounts for every work texel, in a scratch texture.
    func encodeLocal(
        session: ImageSession,
        local: LocalDetail,
        work: WorkArea,
        masks: MaskBindings,
        encoder: any MTLComputeCommandEncoder,
    ) throws -> any MTLTexture {
        let output = try scratchTexture(.rgba16Float, 6, work)
        let aspect = session.orientedSize.aspectRatio
        var layers: [MaskLayerGPU] = []
        var maskComponents = MaskComponentEncoder(aspect: aspect, masks: masks, layers: local.referenced)
        let detailLevel = DevelopParameters.detailLevel(session)
        for layer in local.layers {
            let first = maskComponents.components.count
            layer.components.forEach { maskComponents.append($0) }
            layers.append(MaskLayerGPU(
                color: layer.amounts, tone: .zero,
                tone2: SIMD4(0, 0, Float(first), Float(maskComponents.components.count - first)),
                detail: SIMD4(0, Float(layer.detail / 100), Float(detailLevel), 0),
            ))
        }
        var components = maskComponents.finished()
        var params = DetailLocalParams(
            place: SIMD4(Int32(work.origin.x), Int32(work.origin.y), Int32(work.level), Int32(session.orientation)),
            size: SIMD4(Int32(work.size.x), Int32(work.size.y), Int32(layers.count), 0),
            geometry: SIMD4(Float(aspect), 0, 0, 0),
        )
        encoder.setComputePipelineState(kernels.detailLocal)
        encoder.setTexture(session.pyramid, index: 0)
        encoder.setTexture(output, index: 1)
        let empty = try emptyMaskImages()
        encoder.setTexture(masks.rasters ?? empty.rasters, index: 2)
        encoder.setTexture(masks.guide ?? empty.guide, index: 3)
        encoder.setTexture(masks.edges ?? empty.edges, index: 4)
        if components.isEmpty {
            components = [.empty]
        }
        encoder.setBytes(&params, length: MemoryLayout<DetailLocalParams>.stride, index: 0)
        encoder.setBytes(&layers, length: layers.count * MemoryLayout<MaskLayerGPU>.stride, index: 1)
        try encoder.setArray(components, index: 2, device: device)
        encoder.dispatchGrid(width: work.size.x, height: work.size.y, pipeline: kernels.detailLocal)
        return output
    }

    /// Rec. 2020 luminance weights for the pyramid's camera RGB, and a floor for its log.
    static func luma(_ session: ImageSession) -> SIMD4<Float> {
        SIMD4(session.cameraToWorking.transpose * SIMD3<Float>(0.2627, 0.6780, 0.0593), 1.0 / 1024)
    }

    /// Working texture `slot` of `format`, covering the work area, reused across renders. It grows
    /// to cover every area it has served unless that would take more than the render's tiles may;
    /// one larger than that, made for larger tiles, is replaced.
    func scratchTexture(_ format: MTLPixelFormat, _ slot: Int, _ work: WorkArea) throws -> any MTLTexture {
        let existing = scratch[format]?[slot]
        if let existing, existing.width >= work.size.x, existing.height >= work.size.y,
           existing.width * existing.height <= scratchLimit {
            residency.wake(existing)
            return existing
        }
        let needed = simd_max(work.size, scratchFloor ?? .zero)
        var size = simd_max(needed, existing.map { SIMD2($0.width, $0.height) } ?? .zero)
        if size.x * size.y > scratchLimit {
            size = needed
        }
        let texture = try makeWorkTexture(format, WorkArea(level: work.level, origin: work.origin, size: size))
        scratch[format, default: [:]][slot] = texture
        residency.wake(texture)
        return texture
    }

    /// A private texture covering the work area.
    func makeWorkTexture(_ format: MTLPixelFormat, _ work: WorkArea) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: work.size.x, height: work.size.y, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        allocated = (allocated.count + 1, allocated.bytes + texture.allocatedSize)
        return texture
    }
}

private extension MTLBlitCommandEncoder {
    func copy(
        from source: any MTLTexture, origin: SIMD2<Int>, size: SIMD2<Int>, to destination: any MTLTexture,
        at destinationOrigin: SIMD2<Int>,
    ) {
        copy(
            from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: origin.x, y: origin.y, z: 0),
            sourceSize: MTLSize(width: size.x, height: size.y, depth: 1), to: destination, destinationSlice: 0,
            destinationLevel: 0, destinationOrigin: MTLOrigin(x: destinationOrigin.x, y: destinationOrigin.y, z: 0),
        )
    }
}

/// Keeps the detail stage's textures resident while a command buffer using them is being encoded
/// or run, and for a moment after the last one, so a drag doesn't toggle them every frame; then
/// they are volatile, so the system can reclaim them without a memory warning. A cached texture
/// it reclaimed is rendered again.
final class DetailResidency: Sendable {
    /// Only its purgeable state is changed off the render queue, which Metal allows from any thread.
    private struct Resident: @unchecked Sendable {
        weak var texture: (any MTLTexture)?
    }

    /// Weak, so holding doesn't keep a dropped command buffer alive: one released uncommitted
    /// runs its completed handlers, which release its hold.
    private struct Hold: @unchecked Sendable {
        weak var commands: (any MTLCommandBuffer)?
    }

    private struct State {
        var holds: [ObjectIdentifier: Hold] = [:]
        var awake: [ObjectIdentifier: Resident] = [:]
        /// Counts holds, so a park scheduled before the latest one is skipped.
        var generation = 0
        /// A held command buffer was dropped uncommitted: nothing is parked until `reset`.
        var dropped = false

        mutating func dropReleased() {
            awake = awake.filter { $0.value.texture != nil }
        }
    }

    private let state = Mutex(State())
    private let parkDelay: DispatchTimeInterval

    init(parkDelay: DispatchTimeInterval = .milliseconds(500)) {
        self.parkDelay = parkDelay
    }

    /// Whether nothing is held and every texture woken since has been made volatile again.
    var isParked: Bool {
        state.withLock { state in
            state.dropReleased()
            return state.holds.isEmpty && state.awake.isEmpty
        }
    }

    /// Keeps the textures woken from now on resident until `commands` completes or is abandoned.
    func hold(until commands: any MTLCommandBuffer) {
        let hold = Hold(commands: commands)
        let key = ObjectIdentifier(commands)
        let first = state.withLock { state in
            state.generation += 1
            guard state.holds[key]?.commands !== hold.commands else { return false }
            state.holds[key] = hold
            return true
        }
        if first {
            // Also run when a buffer is released uncommitted.
            commands.addCompletedHandler { [self] commands in
                release(key, dropped: commands.status != .completed && commands.status != .error)
            }
        }
    }

    /// Stops holding for `commands`, which will never be committed.
    func abandon(_ commands: any MTLCommandBuffer) {
        release(ObjectIdentifier(commands), dropped: true)
    }

    /// Whether a command buffer was dropped uncommitted since `reset`.
    var hasDropped: Bool {
        state.withLock(\.dropped)
    }

    /// Stops tracking the textures woken so far, which the stage has let go of.
    func reset() {
        state.withLock { state in
            state.awake.removeAll()
            state.dropped = false
        }
    }

    /// Makes `texture` resident for the commands being encoded. False when the system had
    /// reclaimed it, so its contents are gone.
    @discardableResult
    func wake(_ texture: any MTLTexture) -> Bool {
        let resident = Resident(texture: texture)
        return state.withLock { state in
            guard let texture = resident.texture else { return false }
            let key = ObjectIdentifier(texture)
            guard state.awake[key]?.texture !== texture else { return true }
            state.awake[key] = resident
            return texture.setPurgeableState(.nonVolatile) != .empty
        }
    }

    private func release(_ key: ObjectIdentifier, dropped: Bool) {
        let generation: Int? = state.withLock { state in
            let held = state.holds.removeValue(forKey: key) != nil
            state.dropped = state.dropped || held && dropped
            state.dropReleased()
            return state.holds.isEmpty ? state.generation : nil
        }
        guard let generation else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + parkDelay) { [self] in
            park(ifStill: generation)
        }
    }

    private func park(ifStill generation: Int) {
        state.withLock { state in
            state.dropReleased()
            guard state.generation == generation, state.holds.isEmpty, !state.dropped else { return }
            for resident in state.awake.values {
                resident.texture?.setPurgeableState(.volatile)
            }
            state.awake.removeAll()
        }
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

    /// Process 11: the noise in each band of the ladder of linear luminance, per unit of the
    /// luminance's own noise (`Ladder`), at pyramid levels 0 to 2. Measured as the table above
    /// (`DetailStageTests`, with `REDLAMP_CALIBRATE_NOISE=1`).
    static let ladderBayer: [SIMD4<Float>] = [
        SIMD4(0.7641, 0.2736, 0.1244, 0.0613),
        SIMD4(0.5492, 0.1426, 0.0634, 0.0311),
        SIMD4(0.3042, 0.0735, 0.0321, 0.0161),
    ]

    static let ladderXTrans: [SIMD4<Float>] = [
        SIMD4(0.7614, 0.3129, 0.1073, 0.0546),
        SIMD4(0.5567, 0.1216, 0.0559, 0.0275),
        SIMD4(0.3051, 0.0649, 0.0285, 0.0140),
    ]

    /// B3-spline à-trous detail noise for unit white noise, halving per level.
    static let ladderWhite: [SIMD4<Float>] = (0 ... 2).map { level in
        SIMD4(0.8908, 0.2007, 0.0856, 0.0413) / Float(1 << level)
    }

    static func ladderSigmas(sensor: SensorKind, level: Int) -> SIMD4<Float> {
        let table = switch sensor {
        case .bayer: ladderBayer
        case .xTrans: ladderXTrans
        case .linear, .bitmap: ladderWhite
        }
        return table[min(level, 2)] / Float(1 << max(level - 2, 0))
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
