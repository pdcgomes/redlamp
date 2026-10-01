import CoreGraphics
import CryptoKit
import Foundation
import Metal
import RedlampEngineAPI
import RedlampMasking

/// AI masks: computed on the analysis render (the photo with no edit, sRGB, 2048 px), so they
/// don't move when the edit changes, and kept in the edit as bitmaps.
extension RedlampEngine {
    static let analysisLongEdge = 2048
    /// Sky: `auto` (the default) seeds Segment Anything inside the classical estimate when that
    /// model is on this Mac, as the bake-off chose (MSK-17); `classical` or `sam` force one.
    static var skyMethod: String {
        ProcessInfo.processInfo.environment["REDLAMP_SKY_METHOD"] ?? "auto"
    }

    func usesSegmentAnythingForSky() async -> Bool {
        switch Self.skyMethod {
        case "sam": return true
        case "classical": return false
        default:
            guard let id = Self.modelID(for: .objects),
                  let manifest = ModelCatalog.offered.first(where: { $0.id == id })
            else { return false }
            return await ModelStore.shared.location(of: manifest) != nil
        }
    }

    /// Draws the recipe's brush and AI rasters and renders the guides its masks read, all ahead
    /// of the develop pass in `commands`.
    func prepareMasks(
        _ recipe: EditRecipe, session: ImageSession, commands: any MTLCommandBuffer, needsGuide: Bool = false,
    ) throws -> MaskBindings {
        let components = recipe.masks.flatMap(\.components)
        let readsGuide = needsGuide || components.contains { $0.shape.readsEditGuide }
        let rasterComponents = components.filter { MaskResources.key(for: $0.shape) != nil }
        guard readsGuide || !rasterComponents.isEmpty else { return .none }
        masks.use(session)
        let size = masks.guideSize
        let render = { [self] (guideRecipe: EditRecipe, texture: any MTLTexture) in
            try encodeDevelop(
                guideRecipe, session: session, into: texture, size: size, encoding: .okLab, showClipping: false,
                commands: commands, cacheDetail: false, detail: false,
            )
        }
        var bindings = MaskBindings()
        if readsGuide {
            bindings.guide = try masks.editGuide(for: recipe, commands: commands, render: render)
            bindings.guideSize = size
            bindings.guideGeneration = masks.editGuideGeneration
        }
        if !rasterComponents.isEmpty {
            let analysis = rasterComponents.contains { $0.shape.usesAutoMask }
                ? try masks.analysisGuide(commands: commands, render: render) : nil
            bindings.slices = try masks.slices(for: rasterComponents, analysisGuide: analysis, commands: commands)
            bindings.rasters = masks.rasters
        }
        return bindings
    }

    /// Reads the edit guide one level down (each texel averages four) at `point`.
    func sampleEditGuide(at point: CGPoint, recipe: EditRecipe, session: ImageSession) throws -> SIMD3<Double> {
        guard let commands = queue.makeCommandBuffer(),
              let buffer = device.makeBuffer(length: 8, options: .storageModeShared)
        else { throw EngineError.gpuUnavailable }
        masks.use(session)
        let size = masks.guideSize
        let guide = try masks.editGuide(for: recipe, commands: commands) { [self] global, texture in
            try encodeDevelop(
                global, session: session, into: texture, size: size, encoding: .okLab, showClipping: false,
                commands: commands, cacheDetail: false, detail: false,
            )
        }
        let level = min(1, guide.mipmapLevelCount - 1)
        let width = max(1, guide.width >> level)
        let height = max(1, guide.height >> level)
        let x = min(max(Int(point.x * Double(width)), 0), width - 1)
        let y = min(max(Int(point.y * Double(height)), 0), height - 1)
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.copy(
            from: guide, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: 8, destinationBytesPerImage: 8,
        )
        blit.endEncoding()
        try finish(commands)
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        return SIMD3(Double(halves[0]), Double(halves[1]), Double(halves[2]))
    }

    public func availableMaskKinds() -> Set<MaskKind> {
        var kinds = VisionMaskProvider.supportedKinds
        kinds.insert(.sky)
        if ModelCatalog.offered.contains(where: { $0.id == Self.modelID(for: .objects) }) {
            kinds.insert(.objects)
        }
        let embeddedDepth = currentSession().map { EmbeddedMattes.available(in: $0.info.url).contains(.depth) } ?? false
        if embeddedDepth || ModelCatalog.offered.contains(where: { $0.id == Self.modelID(for: .depthRange) }) {
            kinds.insert(.depthRange)
        }
        return kinds
    }

    public func computeMasks(_ request: MaskRequest) async throws -> [AIMask] {
        guard let session = currentSession() else { throw EngineError.noImageOpen }
        let analysis = try await analysisImage(for: session)
        let url = session.info.url
        if request.kind == .sky, await usesSegmentAnythingForSky(), EmbeddedMattes.read(.sky, from: url) == nil,
           let seeds = try? SkyEstimator.seeds(analysis.image) {
            // The bake-off's auto-prompted candidate: Segment Anything seeded inside the estimate.
            var objects = try await computeMasks(MaskRequest(kind: .objects, prompts: seeds))
            for index in objects.indices {
                objects[index].kind = .sky
            }
            return objects
        }
        if request.kind == .depthRange, !EmbeddedMattes.available(in: url).contains(.depth) {
            let estimator = try await depthEstimator()
            let image = analysis.image
            let depth = try await Task.detached(priority: .userInitiated) { try estimator.depth(of: image) }.value
            guard let bitmap = depth.bitmap() else { throw MaskComputationError.unsupported(.depthRange) }
            return [AIMask(
                kind: .depthRange, provider: estimator.manifest.provider, revision: estimator.manifest.version,
                analysisHash: analysis.hash, center: ImagePoint(x: 0.5, y: 0.5), bitmap: bitmap,
            )]
        }
        if request.kind == .objects {
            let size = PixelSize(width: analysis.image.width, height: analysis.image.height)
                .fitted(within: PixelSize(
                    width: VisionMaskProvider.partsLongEdge,
                    height: VisionMaskProvider.partsLongEdge,
                ))
            let segmenter = try await objectSegmenter()
            let embedding = try await objectEmbedding(analysis, segmenter: segmenter)
            let image = analysis.image
            let mask = try await Task.detached(priority: .userInitiated) {
                let raw = try segmenter.mask(
                    embedding,
                    included: request.prompts,
                    excluded: request.excluded,
                    size: size,
                )
                return GuidedFilter.refine(raw, guide: image, radius: 4, epsilon: 1e-3)
            }.value
            guard mask.coveredFraction > 0.0005, let bitmap = mask.bitmap() else {
                throw MaskComputationError.nothingFound(.objects)
            }
            return [AIMask(
                kind: .objects, provider: segmenter.manifest.provider, revision: segmenter.manifest.version,
                prompts: request.prompts, excludedPrompts: request.excluded.isEmpty ? nil : request.excluded,
                analysisHash: analysis.hash, center: request.prompts.first ?? mask.centroid, bitmap: bitmap,
            )]
        }
        var provided = try await Task.detached(priority: .userInitiated) {
            try Self.provideMasks(request, image: analysis.image, url: url)
        }.value
        if request.combined, var first = provided.first, provided.count > 1 {
            first.mask = provided.dropFirst().reduce(first.mask) { $0.union($1.mask) }
            first.instance = nil
            provided = [first]
        }
        let osBuild = ProcessInfo.processInfo.operatingSystemVersionString
        return provided.compactMap { mask in
            guard let bitmap = mask.mask.bitmap() else { return nil }
            return AIMask(
                kind: mask.kind, provider: mask.provider, revision: mask.revision, osBuild: osBuild,
                instance: mask.instance, part: mask.part?.rawValue, prompts: request.prompts,
                analysisHash: analysis.hash, center: mask.mask.centroid, bitmap: bitmap,
            )
        }
    }

    public func previewObjectMask(_ request: MaskRequest) async throws -> MaskBitmap? {
        guard request.kind == .objects, !request.prompts.isEmpty, let session = currentSession() else { return nil }
        let analysis = try await analysisImage(for: session)
        let segmenter = try await objectSegmenter()
        let embedding = try await objectEmbedding(analysis, segmenter: segmenter)
        let size = PixelSize(width: analysis.image.width, height: analysis.image.height)
            .fitted(within: PixelSize(width: 512, height: 512))
        return try segmenter.mask(embedding, included: request.prompts, excluded: request.excluded, size: size).bitmap()
    }

    public func refineMaskEdges(_ bitmap: MaskBitmap) async throws -> MaskBitmap {
        guard let session = currentSession() else { throw EngineError.noImageOpen }
        guard let png = bitmap.png,
              let mask = GrayMask.decode(png) else { throw MaskComputationError.nothingFound(.subject) }
        let analysis = try await analysisImage(for: session)
        let image = analysis.image
        let refined = await Task.detached(priority: .userInitiated) {
            GuidedFilter.refine(mask, guide: image, radius: max(4, mask.width / 128), epsilon: 4e-4)
        }.value
        guard let result = refined.bitmap() else { throw MaskComputationError.nothingFound(.subject) }
        return result
    }

    func depthEstimator() async throws -> DepthEstimator {
        if let loaded = depthModel.withLock({ $0 }) {
            return loaded
        }
        guard let id = Self.modelID(for: .depthRange),
              let manifest = ModelCatalog.offered.first(where: { $0.id == id }),
              let directory = await ModelStore.shared.location(of: manifest)
        else { throw MaskComputationError.unsupported(.depthRange) }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try DepthEstimator(manifest: manifest, directory: directory)
        }.value
        depthModel.withLock { $0 = loaded }
        return loaded
    }

    func objectSegmenter() async throws -> SAMSegmenter {
        if let loaded = segmenter.withLock({ $0 }) {
            return loaded
        }
        guard let id = Self.modelID(for: .objects), let manifest = ModelCatalog.manifest(id),
              let directory = await ModelStore.shared.location(of: manifest)
        else { throw MaskComputationError.unsupported(.objects) }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try SAMSegmenter(manifest: manifest, directory: directory)
        }.value
        segmenter.withLock { $0 = loaded }
        return loaded
    }

    /// The photo's SAM embedding: in memory for the open photo, then the Caches directory.
    func objectEmbedding(
        _ analysis: (image: CGImage, hash: String), segmenter: SAMSegmenter,
    ) async throws -> SAMSegmenter.Embedding {
        if let cached = objectEmbeddingCache.withLock({ $0 }), cached.hash == analysis.hash {
            return cached.embedding
        }
        let key = EmbeddingCache.key(model: segmenter.manifest, analysisHash: analysis.hash)
        let embedding: SAMSegmenter.Embedding
        if let data = await EmbeddingCache.shared.data(for: key), let stored = try? SAMSegmenter.Embedding(data: data) {
            embedding = stored
        } else {
            let image = analysis.image
            embedding = try await Task.detached(priority: .userInitiated) { try segmenter.embedding(for: image) }.value
            await EmbeddingCache.shared.store(embedding.data(), for: key)
        }
        objectEmbeddingCache.withLock { $0 = (analysis.hash, embedding) }
        return embedding
    }

    /// Embedded mattes win when the file has the one asked for; otherwise the providers.
    static func provideMasks(_ request: MaskRequest, image: CGImage, url: URL) throws -> [ProvidedMask] {
        let size = PixelSize(width: image.width, height: image.height)
        func embedded(_ matte: EmbeddedMatte, kind: MaskKind, part: PersonPart? = nil) -> ProvidedMask? {
            EmbeddedMattes.read(matte, from: url).map { mask in
                ProvidedMask(
                    kind: kind, provider: "apple.embedded.\(matte.rawValue)", revision: 1, part: part,
                    mask: mask.resized(to: size.fitted(within: PixelSize(
                        width: VisionMaskProvider.partsLongEdge, height: VisionMaskProvider.partsLongEdge,
                    ))),
                )
            }
        }
        switch request.kind {
        case .sky:
            if let sky = embedded(.sky, kind: .sky) {
                return [sky]
            }
            return try [SkyEstimator.estimate(image)]
        case .people where request.part == .hair:
            guard let hair = embedded(.hair, kind: .people, part: .hair) else {
                throw MaskComputationError.unsupported(.people)
            }
            return [hair]
        case .people where request.part == .teeth:
            if let teeth = embedded(.teeth, kind: .people, part: .teeth) {
                return [teeth]
            }
            return try VisionMaskProvider().masks(for: request, in: image)
        case .depthRange:
            guard let depth = embedded(.depth, kind: .depthRange)
            else { throw MaskComputationError.unsupported(.depthRange) }
            return [depth]
        default:
            return try VisionMaskProvider().masks(for: request, in: image)
        }
    }

    /// The current photo with the default develop, as AI models see it, and a hash of its pixels.
    func analysisImage(for session: ImageSession) async throws -> (image: CGImage, hash: String) {
        if let cached = analysisCache.withLock({ $0 }), cached.session === session {
            return (cached.image, cached.hash)
        }
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(with: Result {
                    try renderStillNow(
                        StillRequest(recipe: EditRecipe(), maxLongEdge: Self.analysisLongEdge, colorSpace: .sRGB),
                        session: session,
                    )
                })
            }
        }
        let bytes = image.dataProvider?.data as Data? ?? Data()
        let hash = SHA256.hash(data: bytes).prefix(16).map { String(format: "%02x", $0) }.joined()
        analysisCache.withLock { $0 = AnalysisCache(session: session, image: image, hash: hash) }
        return (image, hash)
    }
}

struct AnalysisCache: @unchecked Sendable {
    let session: ImageSession
    let image: CGImage
    let hash: String
}
