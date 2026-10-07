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
    /// Sky's method. `auto` (the default) uses what's on this Mac, best first, as the bake-off
    /// (MSK-17) measured it: Segment Anything (seeded inside the classical estimate, with the sky
    /// between bare branches given back) and Depth Anything 3's sky, arbitrated (IoU 0.945);
    /// either alone (0.940, 0.931); else the classical estimate (0.898). `sam`, `da3` and
    /// `classical` force one. Whichever it is, `SkyMatte` then solves its edges at the size
    /// masks are stored at.
    static var skyMethod: String {
        ProcessInfo.processInfo.environment["REDLAMP_SKY_METHOD"] ?? "auto"
    }

    /// Sky from the models or the classical estimate, its edges solved per pixel on `session`,
    /// the photo `analysis` was rendered from, whichever photo is open by then; nil if neither
    /// finds any.
    func modelSky(
        _ analysis: (image: CGImage, hash: String), session: ImageSession,
    ) async throws -> AIMask? {
        let method = Self.skyMethod
        let image = analysis.image
        var da3: GrayMask?
        if method == "auto" || method == "da3", let model = await depthAnything3() {
            da3 = try? await depthAnything3Result(analysis, model: model).sky
        }
        var sam: GrayMask?
        // Seeded inside the classical estimate, or inside Depth Anything 3's sky when the
        // estimate finds none (a small patch between buildings).
        if method == "auto" || method == "sam", await isReady(Self.modelID(for: .objects)),
           let seeds = (try? SkyEstimator.seeds(image)) ?? da3.flatMap({ try? SkyEstimator.seeds(inside: $0) }),
           let (raw, _) = try? await segmentObject(MaskRequest(kind: .objects, prompts: seeds), analysis: analysis) {
            // SAM cuts around bare tree crowns; give back the sky seen through them. SkyMatte
            // solves the edges afterwards.
            sam = await Task.detached(priority: .userInitiated) {
                let mask = GuidedFilter.refine(raw, guide: image, radius: 4, epsilon: 1e-3)
                return SkyEstimator.refineBetweenBranches(mask, image: image)
            }.value
        }
        let coarse: GrayMask
        let provider: String
        switch (sam, da3) {
        case let (sam?, da3?):
            (coarse, provider) = (SkyEstimator.arbitrate(sam, da3), "redlamp.sky.sam2.1-tiny+depth-anything-3")
        case let (sam?, nil):
            (coarse, provider) = (sam, "redlamp.sky.sam2.1-tiny")
        case let (nil, da3?):
            (coarse, provider) = (da3, "redlamp.sky.depth-anything-3")
        case (nil, nil):
            guard let estimate = try? SkyEstimator.estimate(image) else { return nil }
            (coarse, provider) = (estimate.mask, estimate.provider)
        }
        guard coarse.coveredFraction > 0.001 else { return nil }
        var sky = coarse
        // REDLAMP_SKY_MATTE=off keeps the models' edges, to compare.
        if ProcessInfo.processInfo.environment["REDLAMP_SKY_MATTE"] != "off",
           let full = try? await matteImage(for: session) {
            sky = await Task.detached(priority: .userInitiated) { SkyMatte.refine(coarse, image: full) }.value
        }
        guard let bitmap = sky.bitmap() else { return nil }
        return AIMask(
            kind: .sky, provider: provider, revision: 3, analysisHash: analysis.hash, center: sky.centroid,
            bitmap: bitmap,
        )
    }

    func isReady(_ id: String?) async -> Bool {
        guard let id, let manifest = ModelCatalog.offered.first(where: { $0.id == id }) else { return false }
        return await ModelStore.shared.location(of: manifest) != nil
    }

    /// Depth Anything 3, when it's on this Mac and offered (it is evaluation only).
    func depthAnything3() async -> DepthAnything3? {
        if let loaded = depthAnything3Model.withLock({ $0 }) {
            return loaded
        }
        guard let manifest = ModelCatalog.offered.first(where: { $0.id == Self.depthAnything3ID }),
              let directory = await ModelStore.shared.location(of: manifest),
              let loaded = try? await Task.detached(priority: .userInitiated, operation: {
                  try DepthAnything3(manifest: manifest, directory: directory)
              }).value
        else { return nil }
        depthAnything3Model.withLock { $0 = loaded }
        return loaded
    }

    static let depthAnything3ID = "depth-anything-3-mono-large"

    /// ViTMatte, when it's on this Mac and offered: Subject, Background and People edges then
    /// gain the strands it finds beyond closed-form matting's (MSK-32).
    func vitMatte() async -> ViTMatte? {
        if let loaded = vitMatteModel.withLock({ $0 }) {
            return loaded
        }
        guard let manifest = ModelCatalog.offered.first(where: { $0.id == Self.vitMatteID }),
              let directory = await ModelStore.shared.location(of: manifest),
              let loaded = try? await Task.detached(priority: .userInitiated, operation: {
                  try ViTMatte(manifest: manifest, directory: directory)
              }).value
        else { return nil }
        vitMatteModel.withLock { $0 = loaded }
        return loaded
    }

    static let vitMatteID = "vitmatte-base"

    /// SAM 3, when it's on this Mac and offered (it is evaluation only).
    func sam3() async -> SAM3Concepts? {
        if let loaded = sam3Model.withLock({ $0 }) {
            return loaded
        }
        guard let manifest = ModelCatalog.offered.first(where: { $0.id == Self.sam3ID }),
              let directory = await ModelStore.shared.location(of: manifest),
              let loaded = try? await Task.detached(priority: .userInitiated, operation: {
                  try SAM3Concepts(manifest: manifest, directory: directory)
              }).value
        else { return nil }
        sam3Model.withLock { $0 = loaded }
        return loaded
    }

    /// The open photo's SAM 3 encoding, which Landscape and people parts share.
    func sam3Encoding(
        _ analysis: (image: CGImage, hash: String), model: SAM3Concepts,
    ) async throws -> SAM3Concepts.Features {
        if let cached = sam3Features.withLock({ $0 }), cached.hash == analysis.hash {
            return cached.features
        }
        let image = analysis.image
        let features = try await Task.detached(priority: .userInitiated) { try model.features(of: image) }.value
        sam3Features.withLock { $0 = (analysis.hash, features) }
        return features
    }

    /// Every Landscape class's mask for the open photo: every prompt decoded, kept.
    func landscapeClasses(
        _ analysis: (image: CGImage, hash: String), model: SAM3Concepts,
    ) async throws -> [LandscapeClass: GrayMask] {
        if let cached = landscapeCache.withLock({ $0 }), cached.hash == analysis.hash {
            return cached.classes
        }
        let features = try await sam3Encoding(analysis, model: model)
        let classes = try await Task.detached(priority: .userInitiated) { try model.classes(features) }.value
        landscapeCache.withLock { $0 = (analysis.hash, classes) }
        return classes
    }

    /// Hair, facial hair, clothes and body skin for everyone in the open photo, kept.
    func peopleParts(
        _ analysis: (image: CGImage, hash: String), model: SAM3Concepts,
    ) async throws -> SAM3Concepts.PeopleParts {
        if let cached = peoplePartsCache.withLock({ $0 }), cached.hash == analysis.hash {
            return cached.parts
        }
        let features = try await sam3Encoding(analysis, model: model)
        let parts = try await Task.detached(priority: .userInitiated) { try model.peopleParts(features) }.value
        peoplePartsCache.withLock { $0 = (analysis.hash, parts) }
        return parts
    }

    /// One inference gives both depth and sky; kept for the open photo.
    func depthAnything3Result(
        _ analysis: (image: CGImage, hash: String), model: DepthAnything3,
    ) async throws -> DepthAnything3.Result {
        if let cached = depthAnything3Cache.withLock({ $0 }), cached.hash == analysis.hash {
            return cached.result
        }
        let image = analysis.image
        let result = try await Task.detached(priority: .userInitiated) { try model.predict(image) }.value
        depthAnything3Cache.withLock { $0 = (analysis.hash, result) }
        return result
    }

    /// Draws the recipe's brush and AI rasters and renders the guides its masks read, all ahead
    /// of the develop pass in `commands`. The edit guide is `retouched`, the photo that pass reads
    /// (`retouched(_:session:commands:maps:)` with `retouchMaps`), developed.
    func prepareMasks(
        _ recipe: EditRecipe, session: ImageSession, retouched: ImageSession, commands: any MTLCommandBuffer,
        needsGuide: Bool = false, retouchMaps: RetouchStage.Maps = .current,
    ) throws -> MaskBindings {
        let components = recipe.masks.flatMap(\.components)
        let readsGuide = needsGuide || components.contains { $0.shape.readsEditGuide }
        let process = recipe.processVersion
        let rasterComponents = components.filter { MaskResources.key(for: $0.shape, process: process) != nil }
        guard readsGuide || !rasterComponents.isEmpty else { return .none }
        masks.use(session, commands: commands)
        let size = masks.guideSize
        let render = { [self] (guideRecipe: EditRecipe, texture: any MTLTexture) in
            try encodeDevelop(
                guideRecipe, session: session, into: texture, size: size, encoding: .okLab, showClipping: false,
                commands: commands, cacheDetail: false, detail: false, retouchMaps: retouchMaps,
            )
        }
        var bindings = MaskBindings()
        if readsGuide {
            bindings.guide = try masks.editGuide(for: recipe, from: retouched, commands: commands, render: render)
            bindings.guideSize = size
            bindings.guideGeneration = masks.editGuideGeneration
        }
        if !rasterComponents.isEmpty {
            let analysis = rasterComponents.contains { $0.shape.usesAutoMask }
                ? try masks.analysisGuide(commands: commands, render: render) : nil
            bindings.slices = try masks.slices(
                for: rasterComponents, process: process, analysisGuide: analysis, commands: commands,
            )
            bindings.rasters = masks.rasters
            if process >= 13,
               let edges = try masks.edges(
                   for: rasterComponents, session: session, process: process, commands: commands,
                   growing: process >= 14,
               ) {
                bindings.edges = edges.texture
                bindings.edgeSlices = edges.slices
                bindings.edgeOffset = edges.offset
            }
            // Edge-aware application (MSK-27): a mask of several components keeps blending.
            let single = recipe.masks.compactMap { $0.components.count == 1 ? $0.components[0] : nil }
            if process >= 14,
               let colors = try masks.colors(for: single, session: session, process: process, commands: commands) {
                bindings.colors = colors.texture
                bindings.colorPairs = colors.pairs
            }
        }
        return bindings
    }

    /// Reads the edit guide one level down (each texel averages four) at `point`.
    func sampleEditGuide(at point: CGPoint, recipe: EditRecipe, session: ImageSession) throws -> SIMD3<Double> {
        guard let commands = queue.makeCommandBuffer(),
              let buffer = device.makeBuffer(length: 8, options: .storageModeShared)
        else { throw EngineError.gpuUnavailable }
        try encoding(commands) {
            masks.use(session, commands: commands)
            let size = masks.guideSize
            let retouched = try retouched(recipe, session: session, commands: commands, maps: .refreshLater)
            let guide = try masks
                .editGuide(for: recipe, from: retouched, commands: commands) { [self] global, texture in
                    try encodeDevelop(
                        global, session: session, into: texture, size: size, encoding: .okLab, showClipping: false,
                        commands: commands, cacheDetail: false, detail: false, retouchMaps: .refreshLater,
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
        }
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
        if ModelCatalog.offered.contains(where: { $0.id == Self.sam3ID }) {
            kinds.insert(.landscape)
        }
        let embeddedDepth = currentSession()?.embeddedMattes.contains(.depth) ?? false
        let depthModels = [Self.modelID(for: .depthRange), Self.depthAnything3ID]
        if embeddedDepth || ModelCatalog.offered.contains(where: { depthModels.contains($0.id) }) {
            kinds.insert(.depthRange)
        }
        return kinds
    }

    /// Vision's parts and Hair (from iPhone mattes) everywhere; with SAM 3, its parts too.
    public func availablePersonParts() -> Set<PersonPart> {
        var parts = Set(PersonPart.allCases).subtracting(SAM3Concepts.partPrecedence)
        parts.insert(.hair)
        if ModelCatalog.offered.contains(where: { $0.id == Self.sam3ID }) {
            parts.formUnion(SAM3Concepts.partPrecedence)
        }
        return parts
    }

    public func computeMasks(_ request: MaskRequest) async throws -> [AIMask] {
        guard let session = currentSession() else { throw EngineError.noImageOpen }
        let analysis = try await analysisImage(for: session)
        let url = session.info.url
        if request.kind == .sky, EmbeddedMattes.read(.sky, from: url) == nil,
           let sky = try await modelSky(analysis, session: session) {
            return [sky]
        }
        if request.kind == .depthRange, !session.embeddedMattes.contains(.depth) {
            let image = analysis.image
            let depth: GrayMask
            let provider: String
            let revision: Int
            if let model = await depthAnything3(),
               let result = try? await depthAnything3Result(analysis, model: model) {
                (depth, provider, revision) = (result.depth, model.manifest.provider, model.manifest.version)
            } else {
                let estimator = try await depthEstimator()
                depth = try await Task.detached(priority: .userInitiated) { try estimator.depth(of: image) }.value
                (provider, revision) = (estimator.manifest.provider, estimator.manifest.version)
            }
            guard let bitmap = depth.bitmap() else { throw MaskComputationError.unsupported(.depthRange) }
            return [AIMask(
                kind: .depthRange, provider: provider, revision: revision,
                analysisHash: analysis.hash, center: ImagePoint(x: 0.5, y: 0.5), bitmap: bitmap,
            )]
        }
        if request.kind == .landscape {
            return try await landscapeMask(request, analysis: analysis, session: session)
        }
        // An iPhone's own hair matte beats SAM 3's.
        if request.kind == .people, SAM3Concepts.partPrecedence.contains(request.part),
           request.part != .hair || EmbeddedMattes.read(.hair, from: url) == nil,
           await isReady(Self.sam3ID), let model = await sam3() {
            return try await personPartMasks(request, analysis: analysis, session: session, model: model)
        }
        if request.kind == .objects {
            let (raw, segmenter) = try await segmentObject(request, analysis: analysis)
            let image = analysis.image
            // Edges solved per pixel at the size masks are stored at (the hover preview keeps the
            // model's, to stay instant). REDLAMP_EDGE_MATTE=off keeps the guided filter's.
            let full = ProcessInfo.processInfo.environment["REDLAMP_EDGE_MATTE"] == "off"
                ? nil : try? await matteImage(for: session)
            let mask = await Task.detached(priority: .userInitiated) {
                guard let full else { return GuidedFilter.refine(raw, guide: image, radius: 4, epsilon: 1e-3) }
                return ClosedFormMatte.refine(raw, image: full)
            }.value
            guard mask.coveredFraction > 0.0005, let bitmap = mask.bitmap() else {
                throw MaskComputationError.nothingFound(.objects)
            }
            return [AIMask(
                kind: .objects, provider: segmenter.manifest.provider + (full == nil ? "" : "+closed-form"),
                revision: segmenter.manifest.version,
                prompts: request.prompts, excludedPrompts: request.excluded.isEmpty ? nil : request.excluded,
                box: request.box,
                analysisHash: analysis.hash, center: request.prompts.first ?? mask.centroid, bitmap: bitmap,
            )]
        }
        func aiMasks(_ provided: [ProvidedMask]) -> [AIMask] {
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
        let edgeMatte = ProcessInfo.processInfo.environment["REDLAMP_EDGE_MATTE"]
        var subjectKey: SubjectMatteKey?
        if request.kind == .subject || request.kind == .background {
            let key = await SubjectMatteKey(
                analysisHash: analysis.hash, edgeMatte: edgeMatte, strands: isReady(Self.vitMatteID),
            )
            if let solved = subjectMatte.withLock({ $0?.key == key ? $0?.mask : nil }) {
                return aiMasks([solved.matte(as: request.kind)])
            }
            subjectKey = key
        }
        let part = request.kind == .people && request.part != .entirePerson ? request.part : nil
        var provided: [ProvidedMask]
        do {
            provided = try await Task.detached(priority: .userInitiated) {
                try Self.provideMasks(request, image: analysis.image, url: url)
            }.value
        } catch MaskComputationError.nothingFound(.people) where part != nil {
            // No face, so none of the part: say which part.
            throw MaskComputationError.notFound(request.part)
        } catch MaskComputationError.unsupported(.people) where part == .hair {
            throw MaskComputationError.needsHairMatte
        } catch MaskComputationError.unsupported(.people) where part.map(SAM3Concepts.partPrecedence.contains) == true {
            throw MaskComputationError.needsSAM3(request.part)
        }
        guard !provided.isEmpty else {
            throw part.map(MaskComputationError.notFound) ?? MaskComputationError.nothingFound(request.kind)
        }
        if request.combined, var first = provided.first, provided.count > 1 {
            first.mask = provided.dropFirst().reduce(first.mask) { $0.union($1.mask) }
            first.instance = nil
            provided = [first]
        }
        // Stray hairs and beard curls, per pixel at the size masks are stored at: by closed-form
        // matting, with the strands ViTMatte finds beyond it once it's downloaded. Embedded mattes
        // (iPhone) are already fine, and face parts are drawn shapes. REDLAMP_EDGE_MATTE=off keeps
        // Vision's edges, and =closed-form skips ViTMatte, to compare.
        if edgeMatte != "off",
           provided.contains(where: Self.takesClosedFormMatte), let full = try? await matteImage(for: session) {
            let masks = provided
            let matte = edgeMatte == "closed-form" ? nil : await vitMatte()
            provided = await Task.detached(priority: .userInitiated) {
                masks.map { mask in
                    guard Self.takesClosedFormMatte(mask) else { return mask }
                    var refined = mask
                    refined.mask = Self.closedForm(mask, image: full)
                    refined.provider += "+closed-form"
                    if let matte, let strands = try? Self.vitMatteStrands(
                        mask,
                        closedForm: refined.mask,
                        image: full,
                        model: matte,
                    ) {
                        refined.mask = strands
                        refined.provider += "+vitmatte-strands"
                    }
                    return refined
                }
            }.value
        }
        if let subjectKey, provided.count == 1, provided[0].provider.contains("+closed-form") {
            let subject = provided[0].matte(as: .subject)
            subjectMatte.withLock { $0 = (subjectKey, subject) }
        }
        return aiMasks(provided)
    }

    /// Subject doubts more of Vision's edge (`ClosedFormMatte.subjectInner`), and Background is
    /// solved as the Subject it is the inverse of: hair pokes out of the subject, so the wide
    /// band belongs outside the subject's edge, not the background's.
    static func closedForm(_ mask: ProvidedMask, image: CGImage) -> GrayMask {
        switch mask.kind {
        case .subject:
            ClosedFormMatte.refine(mask.mask, image: image, inner: ClosedFormMatte.subjectInner)
        case .background:
            ClosedFormMatte.refine(mask.mask.inverted, image: image, inner: ClosedFormMatte.subjectInner).inverted
        default:
            ClosedFormMatte.refine(mask.mask, image: image)
        }
    }

    /// `closedForm`'s matte with the strands ViTMatte finds beyond it (`ViTMatte.strands`).
    /// Background is solved as the Subject it is the inverse of, as `closedForm` solves it.
    static func vitMatteStrands(
        _ mask: ProvidedMask, closedForm: GrayMask, image: CGImage, model: ViTMatte,
    ) throws -> GrayMask {
        if mask.kind == .background {
            let subject = try model.refine(mask.mask.inverted, image: image)
            return ViTMatte.strands(of: subject, addedTo: closedForm.inverted).inverted
        }
        return try ViTMatte.strands(of: model.refine(mask.mask, image: image), addedTo: closedForm)
    }

    /// Subject, Background and whole people from Vision; not embedded mattes or face parts.
    static func takesClosedFormMatte(_ mask: ProvidedMask) -> Bool {
        [.subject, .background, .people].contains(mask.kind) && (mask.part ?? .entirePerson) == .entirePerson
            && !mask.provider.hasPrefix("apple.embedded")
    }

    /// A People part from SAM 3's map of everyone's, cut between the people Vision finds (each
    /// pixel to the nearest, within reach), one mask per person who has any (one for all when
    /// `combined`). Where the part meets the background its edge is the person's matte, solved per
    /// pixel (stray hairs); where it meets their skin, face or clothes it is SAM 3's, snapped to
    /// the photo's (a guided filter): solving those per pixel bleeds hair into the forehead and
    /// a beard over the lip. REDLAMP_EDGE_MATTE=off keeps SAM 3's everywhere.
    func personPartMasks(
        _ request: MaskRequest, analysis: (image: CGImage, hash: String), session: ImageSession,
        model: SAM3Concepts,
    ) async throws -> [AIMask] {
        let part = request.part
        let found = try await peopleParts(analysis, model: model)
        guard let map = found.parts[part], let others = found.others[part], Self.selected(map) > 0.0002 else {
            throw MaskComputationError.notFound(part)
        }
        // SAM 3 leaves a faint haze (a tenth) where it isn't sure: none of the part.
        let coarse = GrayMask(width: map.width, height: map.height, coverage: map.coverage.map {
            max($0 - 0.1, 0) / 0.9
        })
        let image = analysis.image
        let size = PixelSize(width: image.width, height: image.height)
        let people = await Task.detached(priority: .userInitiated) {
            (try? VisionMaskProvider().masks(for: MaskRequest(kind: .people), in: image)) ?? []
        }.value
        let full = ProcessInfo.processInfo.environment["REDLAMP_EDGE_MATTE"] == "off" || people.isEmpty
            ? nil : try? await matteImage(for: session)
        var mattes: [GrayMask] = []
        if let full {
            mattes = await personMattes(analysis, people: people, image: full)
        }
        let pieces = await Task.detached(priority: .userInitiated) {
            let mask = GuidedFilter.refine(coarse.resized(to: size), guide: image, radius: 4, epsilon: 1e-3)
            guard !people.isEmpty else { return [mask] }
            // Stray hairs reach a little beyond a person's mask; further is someone Vision missed.
            let split = mask.split(among: people.map { $0.mask.resized(to: size) }, reach: size.longEdge / 25)
            guard mattes.count == split.count else { return split }
            return zip(split, mattes).map { piece, matte in
                Self.selected(piece) > 0.0002
                    ? SAM3Concepts.edges(of: piece, others: others, person: matte, reach: size.longEdge / 50) : piece
            }
        }.value
        let instances: [Int?] = people.isEmpty ? [nil] : Array(pieces.indices)
        var kept: [(instance: Int?, mask: GrayMask)] = zip(instances, pieces)
            .filter { Self.selected($0.1) > 0.0002 }
            .map { (instance: $0.0, mask: $0.1) }
        if request.combined, let first = kept.first {
            kept = [(nil, kept.dropFirst().reduce(first.mask) { $0.union($1.mask) })]
        }
        let osBuild = ProcessInfo.processInfo.operatingSystemVersionString
        let provider = model.manifest.provider + (mattes.isEmpty ? "" : "+closed-form")
        let masks = kept.compactMap { piece -> AIMask? in
            piece.mask.bitmap().map { bitmap in
                AIMask(
                    kind: .people, provider: provider, revision: model.manifest.version, osBuild: osBuild,
                    instance: piece.instance, part: part.rawValue, analysisHash: analysis.hash,
                    center: piece.mask.centroid, bitmap: bitmap,
                )
            }
        }
        guard !masks.isEmpty else { throw MaskComputationError.notFound(part) }
        return masks
    }

    /// Each person's matte, solved per pixel at `image`'s size (the size masks are stored at), for
    /// the open photo.
    func personMattes(
        _ analysis: (image: CGImage, hash: String), people: [ProvidedMask], image: CGImage,
    ) async -> [GrayMask] {
        if let cached = personMatteCache.withLock({ $0 }), cached.hash == analysis.hash,
           cached.mattes.count == people.count {
            return cached.mattes
        }
        let matte = ProcessInfo.processInfo.environment["REDLAMP_EDGE_MATTE"] == "closed-form" ? nil : await vitMatte()
        let mattes = await Task.detached(priority: .userInitiated) {
            people.map { person in
                let closed = ClosedFormMatte.refine(person.mask, image: image)
                return matte
                    .flatMap { try? ViTMatte.strands(of: $0.refine(person.mask, image: image), addedTo: closed) }
                    ?? closed
            }
        }.value
        personMatteCache.withLock { $0 = (analysis.hash, mattes) }
        return mattes
    }

    /// The share of `mask` over half covered.
    static func selected(_ mask: GrayMask) -> Double {
        Double(mask.pixels.count { $0 > 127 }) / Double(max(mask.pixels.count, 1))
    }

    /// One Landscape class, from SAM 3's at its output size, its edges solved per pixel at the
    /// size masks are stored at (REDLAMP_EDGE_MATTE=off keeps the model's).
    func landscapeMask(
        _ request: MaskRequest, analysis: (image: CGImage, hash: String), session: ImageSession,
    ) async throws -> [AIMask] {
        guard let model = await sam3() else { throw MaskComputationError.unsupported(.landscape) }
        let classes = try await landscapeClasses(analysis, model: model)
        guard let coarse = classes[request.landscape], coarse.coveredFraction > 0.001 else {
            throw MaskComputationError.notFound(request.landscape)
        }
        let size = PixelSize(width: analysis.image.width, height: analysis.image.height)
        let full = ProcessInfo.processInfo.environment["REDLAMP_EDGE_MATTE"] == "off"
            ? nil : try? await matteImage(for: session)
        let mask = await Task.detached(priority: .userInitiated) {
            let resized = coarse.resized(to: size)
            return full.map { ClosedFormMatte.refine(resized, image: $0) } ?? resized
        }.value
        guard mask.coveredFraction > 0.001, let bitmap = mask.bitmap() else {
            throw MaskComputationError.notFound(request.landscape)
        }
        return [AIMask(
            kind: .landscape, provider: model.manifest.provider + (full == nil ? "" : "+closed-form"),
            revision: model.manifest.version, part: request.landscape.rawValue, analysisHash: analysis.hash,
            center: mask.centroid, bitmap: bitmap,
        )]
    }

    /// Segment Anything's mask for `request`'s prompts as it gives it, at the analysis size within
    /// the parts' long edge.
    func segmentObject(
        _ request: MaskRequest, analysis: (image: CGImage, hash: String),
    ) async throws -> (mask: GrayMask, segmenter: SAMSegmenter) {
        let size = PixelSize(width: analysis.image.width, height: analysis.image.height)
            .fitted(within: PixelSize(
                width: VisionMaskProvider.partsLongEdge,
                height: VisionMaskProvider.partsLongEdge,
            ))
        let segmenter = try await objectSegmenter()
        let embedding = try await objectEmbedding(analysis, segmenter: segmenter)
        let mask = try await Task.detached(priority: .userInitiated) {
            try segmenter.mask(
                embedding, included: request.prompts, excluded: request.excluded, box: request.box, size: size,
            )
        }.value
        return (mask, segmenter)
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

    public func withShadowAndReflection(_ mask: AIMask) async -> AIMask {
        guard let session = currentSession(), let png = mask.bitmap.png, let gray = GrayMask.decode(png),
              let analysis = try? await analysisImage(for: session)
        else { return mask }
        let image = analysis.image
        let extended = await Task.detached(priority: .userInitiated) {
            RemovalRegion.extended(gray, image: image)
        }.value
        guard extended.shadow || extended.reflection, let bitmap = extended.mask.bitmap() else { return mask }
        var result = mask
        result.bitmap = bitmap
        return result
    }

    /// Solved again per pixel at the size masks are stored at, from the mask as it is, as masks of
    /// its kind are made: the sky's matte for Sky; closed-form matting for the rest, with ViTMatte's
    /// strands for Subject, Background and whole people. A mask made since edges were solved per
    /// pixel comes back much as it was, and an older one gains its strands. On hair_bench's heads:
    /// an error of 0.089 around the edge and 49% of strands kept from today's mattes, 0.076 and 31%
    /// from coarse masks, where the guided filter this replaces gave 0.136 and 16%
    /// (`refine_edges.py`, MSK-31). People's parts keep that filter: solved per pixel, hair bleeds
    /// into the forehead.
    public func refineMaskEdges(_ mask: AIMask) async throws -> MaskBitmap {
        guard let session = currentSession() else { throw EngineError.noImageOpen }
        guard let png = mask.bitmap.png,
              let coarse = GrayMask.decode(png) else { throw MaskComputationError.nothingFound(mask.kind) }
        let part = mask.part.flatMap(PersonPart.init(rawValue:))
        let refined: GrayMask
        if mask.kind == .people, let part, part != .entirePerson {
            let image = try await analysisImage(for: session).image
            refined = await Task.detached(priority: .userInitiated) {
                GuidedFilter.refine(coarse, guide: image, radius: max(4, coarse.width / 128), epsilon: 4e-4)
            }.value
        } else {
            let full = try await matteImage(for: session)
            let provided = ProvidedMask(kind: mask.kind, provider: mask.provider, revision: mask.revision, mask: coarse)
            let strands = Self.takesClosedFormMatte(provided) ? await vitMatte() : nil
            refined = await Task.detached(priority: .userInitiated) {
                switch mask.kind {
                case .sky:
                    return SkyMatte.refine(coarse, image: full)
                case .subject, .background, .people:
                    let closed = Self.closedForm(provided, image: full)
                    guard let strands else { return closed }
                    return (try? Self.vitMatteStrands(provided, closedForm: closed, image: full, model: strands))
                        ?? closed
                default:
                    return ClosedFormMatte.refine(coarse, image: full)
                }
            }.value
        }
        guard let result = refined.bitmap() else { throw MaskComputationError.nothingFound(mask.kind) }
        return result
    }

    public func refineMaskEdges(_ bitmap: MaskBitmap, along strokes: [BrushStroke]) async throws -> MaskBitmap {
        guard let session = currentSession() else { throw EngineError.noImageOpen }
        guard !strokes.isEmpty else { return bitmap }
        guard let png = bitmap.png,
              let mask = GrayMask.decode(png) else { throw MaskComputationError.nothingFound(.subject) }
        let image = try await matteImage(for: session)
        let refined = await Task.detached(priority: .userInitiated) {
            ClosedFormMatte.refine(mask, image: image, along: strokes)
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

    /// The analysis render at the size masks are stored at, for edges finer than the models see.
    func matteImage(for session: ImageSession) async throws -> CGImage {
        if let cached = matteCache.withLock({ $0 }), cached.session === session {
            return cached.image
        }
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(with: Result {
                    try renderStillNow(
                        StillRequest(
                            recipe: EditRecipe(),
                            maxLongEdge: MaskResources.rasterLongEdge,
                            colorSpace: .sRGB,
                        ),
                        session: session,
                    )
                })
            }
        }
        matteCache.withLock { $0 = AnalysisCache(session: session, image: image, hash: "") }
        return image
    }

    // MARK: - Warming up

    public func warmUpMasks() {
        masksWanted.withLock { $0 = true }
        if let session = currentSession() {
            warm(session)
        }
    }

    func warmIfWanted(_ session: ImageSession) {
        if masksWanted.withLock({ $0 }) {
            warm(session)
        }
    }

    /// The renders, models and embeddings `session`'s AI masks need, each cached, at low priority
    /// and after a moment, so the canvas's own frame goes first. Stops if another photo opens.
    func warm(_ session: ImageSession) {
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard currentSession() === session, let analysis = try? await analysisImage(for: session) else { return }
            guard currentSession() === session, await (try? matteImage(for: session)) != nil else { return }
            if await isReady(Self.modelID(for: .objects)), currentSession() === session,
               let segmenter = try? await objectSegmenter(),
               let embedding = try? await objectEmbedding(analysis, segmenter: segmenter) {
                // One throwaway decode: Core ML prepares the decoder's GPU work on its first.
                _ = try? segmenter.mask(
                    embedding, included: [ImagePoint(x: 0.5, y: 0.5)], excluded: [],
                    size: PixelSize(width: 64, height: 64),
                )
            }
            if currentSession() === session, let model = await depthAnything3() {
                _ = try? await depthAnything3Result(analysis, model: model)
            }
            if await isReady(Self.sam3ID), currentSession() === session, let model = await sam3() {
                _ = try? await landscapeClasses(analysis, model: model)
            }
        }
    }
}

struct AnalysisCache: @unchecked Sendable {
    let session: ImageSession
    let image: CGImage
    let hash: String
}

/// What a Subject matte was solved from: the analysis render, the edge setting
/// (REDLAMP_EDGE_MATTE) and whether ViTMatte is on this Mac.
struct SubjectMatteKey: Equatable {
    let analysisHash: String
    let edgeMatte: String?
    let strands: Bool
}

private extension ProvidedMask {
    /// This Subject or Background matte as `kind`: itself, or its inverse as the other.
    func matte(as kind: MaskKind) -> ProvidedMask {
        guard kind != self.kind else { return self }
        var other = self
        other.kind = kind
        other.mask = mask.inverted
        return other
    }
}
