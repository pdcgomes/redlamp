import CoreGraphics
import Foundation
import ImageIO
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampMasking

/// What one render binds for its masks: the raster slices of its brush and AI components, and
/// the guide its range components read.
struct MaskBindings {
    var rasters: (any MTLTexture)?
    var guide: (any MTLTexture)?
    var slices: [UUID: Int] = [:]
    /// AI components' edge coefficients (process 13, `MaskEdges`): their slices, and the guide's
    /// offset the kernels take from each pixel's log luminance.
    var edges: (any MTLTexture)?
    var edgeSlices: [UUID: Int] = [:]
    var edgeOffset: Float = 0
    /// Sky masks' colours either side of their edges (process 14, `MaskColors`): each mask's pair
    /// of slices starts at twice its index here.
    var colors: (any MTLTexture)?
    var colorPairs: [UUID: Int] = [:]
    var guideSize = PixelSize.zero
    /// Changes whenever the guide's contents do, for caches of stages that read it.
    var guideGeneration = 0

    static var none: MaskBindings {
        MaskBindings()
    }
}

extension MaskShape {
    /// Range components select on the photo's colours, so they read the edit guide.
    var readsEditGuide: Bool {
        switch self {
        case .luminanceRange, .colorRange: true
        default: false
        }
    }

    var usesAutoMask: Bool {
        if case let .brush(brush) = self {
            return brush.strokes.contains(where: \.autoMask)
        }
        return false
    }
}

/// Brush and AI coverage, kept on the GPU as slices of one texture array in mask space (the
/// oriented frame, at most `rasterLongEdge` on the long side), plus the guides range masks and
/// Auto Mask read.
///
/// A slice is keyed by what it shows (the strokes, or a bitmap's hash), so a render and its
/// comparison can hold different versions of a mask at once. Painting is incremental: the last
/// stroke is redrawn over a copy of the slice without it, so a growing stroke costs one stroke.
///
/// The rasters and guides of photos rendered before the current one are kept aside while their
/// sessions live, so an export of one photo and the canvas of another, rendered in turns, don't
/// redraw each other's masks.
///
/// Owned by the engine's render queue.
final class MaskResources {
    static let rasterLongEdge = 4096
    static let guideLongEdge = 2048
    static let maximumSlices = 32
    /// Segments per stroke dispatch; their points go in a small constant buffer.
    static let segmentsPerDispatch = 16
    /// What one photo kept aside may hold (five 4096 px slices, or three and a guide), and what
    /// all of them may.
    static let parkedBytesPerPhoto = 128 << 20
    static let parkedBytes = 256 << 20

    enum RasterKey: Hashable {
        case brush(BrushMask)
        /// A bitmap's hash, and an AI mask's Feather and Edge, and whether they keep its detail
        /// (`GrayMask.shaped`, from process 14).
        case bitmap(String, feather: Double = 0, edge: Double = 0, keepsDetail: Bool = false)
    }

    /// A photo's AI mask edge coefficients: an array at its analysis image's size, a slice per
    /// mask, keyed as the mask's raster is.
    private final class EdgeMaps {
        weak var session: ImageSession?
        let width: Int
        let height: Int
        let guide: [Float]
        let offset: Float
        var texture: (any MTLTexture)?
        var keys: [RasterKey] = []

        init(session: ImageSession) {
            self.session = session
            width = session.analysis.width
            height = session.analysis.height
            (guide, offset) = MaskEdges.guide(session.analysis)
        }
    }

    /// The photos rendered most recently, newest last.
    private var edgeMaps: [EdgeMaps] = []
    static let edgeSlicesPerPhoto = 16

    /// A photo's AI mask colours (process 14): an array at its analysis image's size, two slices
    /// per mask (the colour inside its edge, then outside), keyed as the mask's raster is.
    private final class ColorMaps {
        weak var session: ImageSession?
        let width: Int
        let height: Int
        var texture: (any MTLTexture)?
        var keys: [RasterKey] = []
        /// Masks nowhere wholly inside or nowhere wholly outside, which have no colours.
        var without: Set<RasterKey> = []

        init(session: ImageSession) {
            self.session = session
            width = session.analysis.width
            height = session.analysis.height
        }
    }

    /// The photos rendered most recently, newest last.
    private var colorMaps: [ColorMaps] = []
    static let colorPairsPerPhoto = 8

    /// The edit guide, the recipe it's for (without its masks), and the photo it was developed
    /// from: with the recipe's spots in, its maps made again once they are (`RetouchStage.Maps`).
    private struct EditGuide {
        var recipe: EditRecipe
        var texture: any MTLTexture
        weak var photo: ImageSession?
    }

    /// A photo's rasters and guides while another photo renders.
    private struct Parked {
        weak var session: ImageSession?
        var rasters: (any MTLTexture)?
        var keys: [RasterKey?]
        var lastUsed: [UInt64]
        var paintBase: (key: BrushMask, texture: any MTLTexture)?
        var editGuide: EditGuide?
        var editGuideGeneration: Int
        var analysisGuide: (any MTLTexture)?

        var textures: [any MTLTexture] {
            [rasters, paintBase?.texture, editGuide?.texture, analysisGuide].compactMap(\.self)
        }

        var bytes: Int {
            textures.reduce(0) { $0 + $1.allocatedSize }
        }

        /// Makes the textures resident again, dropping any the system purged meanwhile.
        mutating func reclaim() {
            if rasters?.setPurgeableState(.nonVolatile) == .empty {
                rasters = nil
                keys = []
                lastUsed = []
            }
            if paintBase?.texture.setPurgeableState(.nonVolatile) == .empty {
                paintBase = nil
            }
            if editGuide?.texture.setPurgeableState(.nonVolatile) == .empty {
                editGuide = nil
            }
            if analysisGuide?.setPurgeableState(.nonVolatile) == .empty {
                analysisGuide = nil
            }
        }
    }

    private let device: any MTLDevice
    let kernels: KernelLibrary

    private var session: ImageSession?
    private(set) var rasterSize = PixelSize.zero
    private(set) var rasters: (any MTLTexture)?
    private(set) var keys: [RasterKey?] = []
    private var lastUsed: [UInt64] = []
    private var clock: UInt64 = 0
    /// Slices drawn so far (not found on the GPU), for tests.
    private(set) var slicesDrawn = 0
    /// Photos kept aside whose rasters the system purged before they were shown again, for tests.
    private(set) var rastersPurged = 0
    var scratch: (any MTLTexture)?
    /// The most recently painted brush without its last stroke.
    var paintBase: (key: BrushMask, texture: any MTLTexture)?

    private(set) var guideSize = PixelSize.zero
    private var editGuide: EditGuide?
    /// Never reused, since a photo's guide can be dropped and rendered again while caches still
    /// hold its old number.
    private(set) var editGuideGeneration = 0
    private var guideGenerations = 0
    private var analysisGuide: (any MTLTexture)?

    /// Oldest first.
    private var parked: [Parked] = []

    /// What a command buffer recorded here, undone if it fails or is dropped: the slices it drew,
    /// the caches it rendered, and the arrays as they were before it first replaced one with a
    /// larger one whose copy it carries.
    private final class Recording {
        weak var commands: (any MTLCommandBuffer)?
        weak var session: ImageSession?
        var slices: Set<Int> = []
        var rasters: (texture: (any MTLTexture)?, keys: [RasterKey?], lastUsed: [UInt64])?
        var painting = false
        var editGuide = false
        var analysisGuide = false
        var edges: [(maps: EdgeMaps, texture: (any MTLTexture)?, keys: [RasterKey])] = []
        var colors: [(maps: ColorMaps, texture: (any MTLTexture)?, keys: [RasterKey])] = []

        init(commands: any MTLCommandBuffer, session: ImageSession?) {
            self.commands = commands
            self.session = session
        }
    }

    private var recordings: [Recording] = []

    let emptyRasters: any MTLTexture
    let emptyGuide: any MTLTexture
    let emptyEdges: any MTLTexture

    init(device: any MTLDevice, kernels: KernelLibrary) throws {
        self.device = device
        self.kernels = kernels
        (emptyRasters, emptyGuide, emptyEdges) = try Self.emptyImages(device: device)
    }

    /// One transparent texel of each, bound when a render has no rasters, guide or edges.
    static func emptyImages(
        device: any MTLDevice,
    ) throws -> (rasters: any MTLTexture, guide: any MTLTexture, edges: any MTLTexture) {
        let rasters = MTLTextureDescriptor()
        rasters.textureType = .type2DArray
        rasters.pixelFormat = .r16Float
        rasters.width = 1
        rasters.height = 1
        rasters.arrayLength = 1
        rasters.usage = .shaderRead
        let guide = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 1,
            height: 1,
            mipmapped: false,
        )
        guide.usage = .shaderRead
        guard let emptyRasters = device.makeTexture(descriptor: rasters),
              let emptyGuide = device.makeTexture(descriptor: guide)
        else { throw EngineError.gpuUnavailable }
        var zero: UInt16 = 0
        emptyRasters.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &zero,
            bytesPerRow: 2, bytesPerImage: 2,
        )
        var zeros = [UInt16](repeating: 0, count: 4)
        emptyGuide.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zeros, bytesPerRow: 8)
        guard let emptyEdges = device.makeTexture(descriptor: edgesDescriptor(width: 1, height: 1, slices: 1)) else {
            throw EngineError.gpuUnavailable
        }
        emptyEdges.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &zeros, bytesPerRow: 8,
            bytesPerImage: 8,
        )
        return (emptyRasters, emptyGuide, emptyEdges)
    }

    private static func edgesDescriptor(width: Int, height: Int, slices: Int) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = width
        descriptor.height = height
        descriptor.arrayLength = slices
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return descriptor
    }

    /// The edge coefficients of `components`' AI masks for `session` (process 13), computing the
    /// ones it doesn't have. Up to `edgeSlicesPerPhoto` masks are refined; with `growing`
    /// (process 14) the slices grow to every mask's.
    func edges(
        for components: [MaskComponent], session: ImageSession, process: Int = EditRecipe.currentProcessVersion,
        commands: any MTLCommandBuffer, growing: Bool = false,
    ) throws -> (texture: any MTLTexture, slices: [UUID: Int], offset: Float)? {
        let stored = session.orientedSize.fitted(
            within: PixelSize(width: Self.rasterLongEdge, height: Self.rasterLongEdge),
        ).longEdge
        // A mask solved per pixel at the size masks are stored at is drawn as it is: fitted to the
        // photo's luminance on the coarser analysis grid, twigs, wires and strands would be lost.
        let masks = components.compactMap { component -> (UUID, AIMask)? in
            if case let .ai(mask) = component.shape, mask.bitmap.png != nil,
               Double(max(mask.bitmap.width, mask.bitmap.height)) < 0.98 * Double(stored) {
                (component.id, mask)
            } else {
                nil
            }
        }
        guard !masks.isEmpty else { return nil }
        edgeMaps.removeAll { $0.session == nil }
        let photo = edgeMaps.first { $0.session === session } ?? EdgeMaps(session: session)
        edgeMaps.removeAll { $0 === photo }
        edgeMaps.append(photo)
        if edgeMaps.count > 2 {
            edgeMaps.removeFirst()
        }
        let limit = growing ? max(Self.edgeSlicesPerPhoto, masks.count) : Self.edgeSlicesPerPhoto
        if photo.keys.count > limit {
            photo.keys.removeLast(photo.keys.count - limit)
        }
        var slices: [UUID: Int] = [:]
        for (id, mask) in masks {
            guard let key = Self.key(for: .ai(mask), process: process) else { continue }
            if let slice = photo.keys.firstIndex(of: key) {
                slices[id] = slice
                continue
            }
            guard let png = mask.bitmap.png, let gray = GrayMask.decode(png) else { continue }
            let shaped = gray.shaped(
                feather: mask.feather, edge: mask.edge, reach: MaskEdges.reach(gray), keepingDetail: process >= 14,
            )
            let texels = MaskEdges.texels(
                for: shaped, guide: photo.guide, width: photo.width, height: photo.height,
                orientation: session.orientation,
            )
            let slice: Int
            if photo.keys.count < limit {
                slice = photo.keys.count
                photo.keys.append(key)
            } else {
                let used = Set(slices.values)
                guard let free = photo.keys.indices.first(where: { !used.contains($0) }) else { continue }
                slice = free
                photo.keys[slice] = key
            }
            if (photo.texture?.arrayLength ?? 0) <= slice {
                guard let grown = device.makeTexture(descriptor: Self.edgesDescriptor(
                    width: photo.width, height: photo.height, slices: min(max(4, slice * 2), limit),
                )) else { throw EngineError.gpuUnavailable }
                if let old = photo.texture {
                    guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
                    blit.copy(
                        from: old, sourceSlice: 0, sourceLevel: 0, to: grown, destinationSlice: 0,
                        destinationLevel: 0, sliceCount: old.arrayLength, levelCount: 1,
                    )
                    blit.endEncoding()
                }
                let recorded = recording(commands)
                if !recorded.edges.contains(where: { $0.maps === photo }) {
                    recorded.edges.append((photo, photo.texture, Array(photo.keys.prefix(slice))))
                }
                photo.texture = grown
            }
            texels.withUnsafeBytes { bytes in
                photo.texture?.replace(
                    region: MTLRegionMake2D(0, 0, photo.width, photo.height), mipmapLevel: 0, slice: slice,
                    withBytes: bytes.baseAddress!, bytesPerRow: photo.width * 8,
                    bytesPerImage: photo.width * photo.height * 8,
                )
            }
            slices[id] = slice
        }
        guard let texture = photo.texture else { return nil }
        return (texture, slices, photo.offset)
    }

    /// The colours either side of the edges of `components`' Sky masks for `session` (process 14),
    /// computing the ones it doesn't have: each mask's pair of slices starts at twice its index.
    func colors(
        for components: [MaskComponent], session: ImageSession, process: Int = EditRecipe.currentProcessVersion,
        commands: any MTLCommandBuffer,
    ) throws -> (texture: any MTLTexture, pairs: [UUID: Int])? {
        let masks = components.compactMap { component -> (UUID, AIMask)? in
            if case let .ai(mask) = component.shape, MaskColors.splits(mask) {
                (component.id, mask)
            } else {
                nil
            }
        }
        guard !masks.isEmpty else { return nil }
        colorMaps.removeAll { $0.session == nil }
        let photo = colorMaps.first { $0.session === session } ?? ColorMaps(session: session)
        colorMaps.removeAll { $0 === photo }
        colorMaps.append(photo)
        if colorMaps.count > 2 {
            colorMaps.removeFirst()
        }
        var pairs: [UUID: Int] = [:]
        for (id, mask) in masks {
            guard let key = Self.key(for: .ai(mask), process: process), !photo.without.contains(key) else { continue }
            if let pair = photo.keys.firstIndex(of: key) {
                pairs[id] = pair
                continue
            }
            guard let png = mask.bitmap.png, let gray = GrayMask.decode(png) else { continue }
            let shaped = gray.shaped(
                feather: mask.feather, edge: mask.edge, reach: MaskEdges.reach(gray), keepingDetail: process >= 14,
            )
            guard let texels = MaskColors.texels(
                for: shaped, analysis: session.analysis, orientation: session.orientation,
            ) else {
                photo.without.insert(key)
                continue
            }
            let pair: Int
            if photo.keys.count < Self.colorPairsPerPhoto {
                pair = photo.keys.count
                photo.keys.append(key)
            } else {
                let used = Set(pairs.values)
                guard let free = photo.keys.indices.first(where: { !used.contains($0) }) else { continue }
                pair = free
                photo.keys[pair] = key
            }
            if (photo.texture?.arrayLength ?? 0) < 2 * pair + 2 {
                let slices = min(max(4, 4 * (pair + 1)), 2 * Self.colorPairsPerPhoto)
                guard let grown = device.makeTexture(descriptor: Self.edgesDescriptor(
                    width: photo.width, height: photo.height, slices: slices,
                )) else { throw EngineError.gpuUnavailable }
                if let old = photo.texture {
                    guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
                    blit.copy(
                        from: old, sourceSlice: 0, sourceLevel: 0, to: grown, destinationSlice: 0,
                        destinationLevel: 0, sliceCount: old.arrayLength, levelCount: 1,
                    )
                    blit.endEncoding()
                }
                let recorded = recording(commands)
                if !recorded.colors.contains(where: { $0.maps === photo }) {
                    recorded.colors.append((photo, photo.texture, Array(photo.keys.prefix(pair))))
                }
                photo.texture = grown
            }
            for (offset, side) in [texels.inside, texels.outside].enumerated() {
                side.withUnsafeBytes { bytes in
                    photo.texture?.replace(
                        region: MTLRegionMake2D(0, 0, photo.width, photo.height), mipmapLevel: 0,
                        slice: 2 * pair + offset, withBytes: bytes.baseAddress!, bytesPerRow: photo.width * 8,
                        bytesPerImage: photo.width * photo.height * 8,
                    )
                }
            }
            pairs[id] = pair
        }
        guard let texture = photo.texture else { return nil }
        return (texture, pairs)
    }

    /// Switches to `next`'s rasters and guides, keeping the current photo's aside.
    func use(_ next: ImageSession, commands: (any MTLCommandBuffer)? = nil) {
        parked.removeAll { $0.session == nil }
        guard session !== next else { return }
        var kept = parked.firstIndex { $0.session === next }.map { parked.remove(at: $0) }
        if let session {
            park(session, queue: commands?.commandQueue)
        }
        session = next
        rasterSize = next.orientedSize.fitted(
            within: PixelSize(width: Self.rasterLongEdge, height: Self.rasterLongEdge),
        )
        guideSize = next.orientedSize.fitted(within: PixelSize(width: Self.guideLongEdge, height: Self.guideLongEdge))
        scratch = nil
        let hadRasters = kept?.rasters != nil
        kept?.reclaim()
        if hadRasters, kept?.rasters == nil {
            rastersPurged += 1
        }
        rasters = kept?.rasters
        keys = kept?.keys ?? []
        lastUsed = kept?.lastUsed ?? []
        paintBase = kept?.paintBase
        editGuide = kept?.editGuide
        editGuideGeneration = kept?.editGuideGeneration ?? 0
        analysisGuide = kept?.analysisGuide
    }

    /// Lets go of the photo rendered last unless it's `kept`, keeping its rasters and guides aside
    /// as `use(_:commands:)` does, and of what is kept for photos that are gone.
    func keepOnly(_ kept: ImageSession, queue: any MTLCommandQueue) {
        parked.removeAll { $0.session == nil }
        edgeMaps.removeAll { $0.session == nil }
        colorMaps.removeAll { $0.session == nil }
        guard let session, session.original !== kept.original else { return }
        park(session, queue: queue)
        self.session = nil
        rasterSize = .zero
        guideSize = .zero
        scratch = nil
        rasters = nil
        keys = []
        lastUsed = []
        paintBase = nil
        editGuide = nil
        editGuideGeneration = 0
        analysisGuide = nil
    }

    /// The bytes each photo kept aside holds, oldest first.
    var parkedSizes: [Int] {
        parked.map(\.bytes)
    }

    /// The slices of each photo kept aside, oldest first.
    var parkedRasterSlices: [Int] {
        parked.compactMap { $0.rasters?.arrayLength }
    }

    var parkedTextures: [any MTLTexture] {
        parked.flatMap(\.textures)
    }

    /// Every photo's textures: the current one's, those kept aside, and edge and colour maps.
    var heldTextures: [any MTLTexture] {
        [rasters, scratch, paintBase?.texture, editGuide?.texture, analysisGuide].compactMap(\.self) + parkedTextures
            + edgeMaps.compactMap(\.texture) + colorMaps.compactMap(\.texture)
    }

    /// Fits the photo within its share, dropping in order unused slices, the painting cache, the
    /// guides (each one render) and then the least recently used slices (each maybe a PNG decode).
    private func park(_ session: ImageSession, queue: (any MTLCommandQueue)?) {
        parked.removeAll { $0.session === session }
        var photo = Parked(
            session: session, rasters: rasters, keys: keys, lastUsed: lastUsed, paintBase: paintBase,
            editGuide: editGuide, editGuideGeneration: editGuideGeneration, analysisGuide: analysisGuide,
        )
        var slices = photo.keys.indices.filter { photo.keys[$0] != nil }
            .sorted { photo.lastUsed[$0] > photo.lastUsed[$1] }
        let arrayLength = rasters?.arrayLength ?? 0
        func rasterBytes(_ count: Int) -> Int {
            guard count > 0 else { return 0 }
            if count == arrayLength, let rasters {
                return rasters.allocatedSize
            }
            return device.heapTextureSizeAndAlign(descriptor: arrayDescriptor(slices: count)).size
        }
        func fits(_ count: Int) -> Bool {
            photo.bytes - (photo.rasters?.allocatedSize ?? 0) + rasterBytes(count) <= Self.parkedBytesPerPhoto
        }
        if !fits(arrayLength) {
            if !fits(slices.count) {
                photo.paintBase = nil
            }
            if !fits(slices.count) {
                photo.analysisGuide = nil
            }
            if !fits(slices.count) {
                photo.editGuide = nil
            }
            while !slices.isEmpty, !fits(slices.count) {
                slices.removeLast()
            }
            if slices.count < arrayLength {
                compact(&photo, to: slices, queue: queue)
            }
        }
        guard photo.bytes > 0 else { return }
        for texture in photo.textures {
            texture.setPurgeableState(.volatile)
        }
        parked.append(photo)
        while parked.reduce(0, { $0 + $1.bytes }) > Self.parkedBytes {
            parked.removeFirst()
        }
    }

    /// Copies `slices` into an array of just those, on a command buffer of its own, so the copy
    /// doesn't depend on the next photo's render running; drops the rasters if it can't.
    private func compact(_ photo: inout Parked, to slices: [Int], queue: (any MTLCommandQueue)?) {
        guard let source = photo.rasters else { return }
        photo.rasters = nil
        guard !slices.isEmpty, let commands = queue?.makeCommandBuffer(),
              let compacted = try? makeArray(slices: slices.count), let blit = commands.makeBlitCommandEncoder()
        else {
            photo.keys = []
            photo.lastUsed = []
            return
        }
        for (slice, from) in slices.enumerated() {
            blit.copy(
                from: source, sourceSlice: from, sourceLevel: 0, to: compacted, destinationSlice: slice,
                destinationLevel: 0, sliceCount: 1, levelCount: 1,
            )
        }
        blit.endEncoding()
        commands.commit()
        // Kept textures are made volatile, which the GPU mustn't be writing.
        commands.waitUntilCompleted()
        guard commands.status == .completed else {
            photo.keys = []
            photo.lastUsed = []
            return
        }
        photo.rasters = compacted
        photo.keys = slices.map { photo.keys[$0] }
        photo.lastUsed = slices.map { photo.lastUsed[$0] }
    }

    // MARK: - Guides

    /// The edit guide for `recipe` (its masks are ignored), developed from `photo`, rendering it
    /// with `render` when the global edit or the photo changed since the last one.
    func editGuide(
        for recipe: EditRecipe,
        from photo: ImageSession,
        commands: any MTLCommandBuffer,
        render: (EditRecipe, any MTLTexture) throws -> Void,
    ) throws -> any MTLTexture {
        let global = Self.guideRecipe(for: recipe)
        if let editGuide, editGuide.recipe == global, editGuide.photo === photo {
            return editGuide.texture
        }
        let texture = try editGuide?.texture ?? makeGuide()
        recording(commands).editGuide = true
        try render(global, texture)
        try generateMipmaps(texture, commands: commands)
        editGuide = EditGuide(recipe: global, texture: texture, photo: photo)
        guideGenerations += 1
        editGuideGeneration = guideGenerations
        return texture
    }

    /// What the edit guide's render never reads: the detail stage's settings, which it skips, and
    /// grain, which a guide leaves out (`DevelopParameters`). Left at their defaults, so moving them
    /// doesn't render the guide again.
    static let unreadByGuide: [ParameterID] = [
        .sharpenAmount, .sharpenRadius, .sharpenDetail, .sharpenMasking, .noiseLuminance, .noiseLuminanceDetail,
        .noiseLuminanceContrast, .noiseColor, .noiseColorDetail, .noiseColorSmoothness, .texture, .clarity,
        .grainAmount, .grainSize, .grainRoughness, .grainColor,
    ]

    /// The global edit the edit guide develops, and is kept for. Masks read the guide at the photo
    /// point behind each pixel, so from process 14 it covers the whole EXIF-oriented photo: no
    /// orientation, crop, angle, Transform or distortion, while the profile's vignetting, a matter
    /// of tone, stays.
    static func guideRecipe(for recipe: EditRecipe) -> EditRecipe {
        var global = recipe
        global.masks = []
        let defaults = EditRecipe()
        for parameter in unreadByGuide {
            global[parameter] = defaults[parameter]
        }
        return recipe.processVersion >= 14 ? unframed(global) : global
    }

    /// `recipe` over the whole EXIF-oriented photo, so a render's pixels sit at the photo points
    /// behind them: no orientation, crop, angle, Transform or distortion. The profile's
    /// vignetting, a matter of tone, stays.
    static func unframed(_ recipe: EditRecipe) -> EditRecipe {
        var unframed = recipe
        let defaults = EditRecipe()
        unframed.orientation = .identity
        unframed.crop = .full
        for parameter in EditRecipe.geometryParameters where parameter != .lensProfile {
            unframed[parameter] = defaults[parameter]
        }
        unframed[.lensProfileDistortion] = 0
        return unframed
    }

    /// OKLab of the default develop (as-shot white balance, no edits), which never changes with
    /// the edit: what Auto Mask and AI masks see.
    func analysisGuide(
        commands: any MTLCommandBuffer,
        render: (EditRecipe, any MTLTexture) throws -> Void,
    ) throws -> any MTLTexture {
        if let analysisGuide {
            return analysisGuide
        }
        let texture = try makeGuide()
        recording(commands).analysisGuide = true
        try render(EditRecipe(), texture)
        try generateMipmaps(texture, commands: commands)
        analysisGuide = texture
        return texture
    }

    private func makeGuide() throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: guideSize.width, height: guideSize.height, mipmapped: true,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        return texture
    }

    private func generateMipmaps(_ texture: any MTLTexture, commands: any MTLCommandBuffer) throws {
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
    }

    // MARK: - Rasters

    static func key(for shape: MaskShape, process: Int = EditRecipe.currentProcessVersion) -> RasterKey? {
        switch shape {
        case let .brush(brush): .brush(brush)
        case let .ai(mask) where mask.bitmap.png != nil:
            .bitmap(
                mask.bitmap.sha256, feather: mask.feather, edge: mask.edge,
                keepsDetail: process >= 14 && (mask.feather != 0 || mask.edge != 0),
            )
        case let .depthRange(range) where range.depth.bitmap.png != nil: .bitmap(range.depth.bitmap.sha256)
        default: nil
        }
    }

    /// The slice of every raster component, drawing the ones not already on the GPU.
    func slices(
        for components: [MaskComponent],
        process: Int = EditRecipe.currentProcessVersion,
        analysisGuide: (any MTLTexture)?,
        commands: any MTLCommandBuffer,
    ) throws -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var used = Set<Int>()
        for component in components {
            guard let key = Self.key(for: component.shape, process: process) else { continue }
            if let slice = keys.firstIndex(of: key) {
                clock += 1
                lastUsed[slice] = clock
                used.insert(slice)
                result[component.id] = slice
                continue
            }
            let drawn: Int? = switch component.shape {
            case let .brush(brush):
                try drawBrush(brush, avoiding: used, guide: analysisGuide, commands: commands)
            case let .ai(mask):
                try upload(
                    mask.bitmap, feather: mask.feather, edge: mask.edge, keepingDetail: process >= 14, avoiding: used,
                    commands: commands,
                )
            case let .depthRange(range):
                try upload(range.depth.bitmap, avoiding: used, commands: commands)
            default:
                nil
            }
            guard let slice = drawn else { continue }
            slicesDrawn += 1
            keys[slice] = key
            recording(commands).slices.insert(slice)
            clock += 1
            lastUsed[slice] = clock
            used.insert(slice)
            result[component.id] = slice
        }
        return result
    }

    /// A slice to draw into: an unused one, the least recently used one not needed by this
    /// render, or a new one. `nil` once every slice is in use.
    func freeSlice(
        avoiding used: Set<Int>,
        preferring preferred: Int? = nil,
        commands: any MTLCommandBuffer,
    ) throws -> Int? {
        if let preferred, !used.contains(preferred) {
            return preferred
        }
        if let empty = keys.firstIndex(where: { $0 == nil }) {
            return empty
        }
        let candidates = keys.indices.filter { !used.contains($0) }
        if keys.count >= Self.maximumSlices || (!candidates.isEmpty && keys.count >= 8) {
            return candidates.min { lastUsed[$0] < lastUsed[$1] }
        }
        try grow(to: max(4, keys.count * 2), commands: commands)
        return keys.firstIndex(where: { $0 == nil })
    }

    private func grow(to count: Int, commands: any MTLCommandBuffer) throws {
        let count = min(count, Self.maximumSlices)
        let next = try makeArray(slices: count)
        if let rasters {
            guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
            for slice in 0 ..< rasters.arrayLength {
                blit.copy(
                    from: rasters, sourceSlice: slice, sourceLevel: 0, to: next, destinationSlice: slice,
                    destinationLevel: 0, sliceCount: 1, levelCount: 1,
                )
            }
            blit.endEncoding()
        }
        let recorded = recording(commands)
        if recorded.rasters == nil {
            recorded.rasters = (rasters, keys, lastUsed)
        }
        rasters = next
        keys += [RasterKey?](repeating: nil, count: count - keys.count)
        lastUsed += [UInt64](repeating: 0, count: count - lastUsed.count)
    }

    private func makeArray(slices: Int) throws -> any MTLTexture {
        guard let texture = device.makeTexture(descriptor: arrayDescriptor(slices: slices)) else {
            throw EngineError.gpuUnavailable
        }
        return texture
    }

    private func arrayDescriptor(slices: Int) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .r16Float
        descriptor.width = rasterSize.width
        descriptor.height = rasterSize.height
        descriptor.arrayLength = slices
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return descriptor
    }

    func makeSingle() throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .r16Float
        descriptor.width = rasterSize.width
        descriptor.height = rasterSize.height
        descriptor.arrayLength = 1
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        return texture
    }

    func clear(_ slice: Int, commands: any MTLCommandBuffer) throws {
        guard let rasters else { return }
        try clear(rasters, slice: slice, commands: commands)
    }

    func clear(_ texture: any MTLTexture, slice: Int, commands: any MTLCommandBuffer) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        var params = MaskRasterParams(
            box: SIMD4(0, 0, Int32(texture.width), Int32(texture.height)),
            info: SIMD4(Int32(slice), 0, 0, 0),
            raster: SIMD4(Float(texture.width), Float(texture.height), 0, 0),
        )
        encoder.setComputePipelineState(kernels.maskClear)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<MaskRasterParams>.stride, index: 0)
        encoder.dispatchGrid(width: texture.width, height: texture.height, pipeline: kernels.maskClear)
        encoder.endEncoding()
    }

    func copy(
        _ source: any MTLTexture, slice sourceSlice: Int, to destination: any MTLTexture, slice destinationSlice: Int,
        commands: any MTLCommandBuffer,
    ) throws {
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.copy(
            from: source, sourceSlice: sourceSlice, sourceLevel: 0, to: destination,
            destinationSlice: destinationSlice, destinationLevel: 0, sliceCount: 1, levelCount: 1,
        )
        blit.endEncoding()
    }

    // MARK: Bitmaps

    private func upload(
        _ bitmap: MaskBitmap, feather: Double = 0, edge: Double = 0, keepingDetail: Bool = false,
        avoiding used: Set<Int>, commands: any MTLCommandBuffer,
    ) throws -> Int? {
        guard let png = bitmap.png, let decoded = GrayMask.decode(png) else { return nil }
        let gray = decoded.shaped(
            feather: feather, edge: edge, reach: MaskEdges.reach(decoded), keepingDetail: keepingDetail,
        )
        guard let slice = try freeSlice(avoiding: used, commands: commands), let rasters else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: gray.width, height: gray.height, mipmapped: false,
        )
        descriptor.usage = .shaderRead
        guard let source = device.makeTexture(descriptor: descriptor),
              let encoder = commands.makeComputeCommandEncoder()
        else { throw EngineError.gpuUnavailable }
        gray.pixels.withUnsafeBytes { bytes in
            source.replace(
                region: MTLRegionMake2D(0, 0, gray.width, gray.height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: gray.width,
            )
        }
        var params = MaskRasterParams(
            box: SIMD4(0, 0, Int32(rasterSize.width), Int32(rasterSize.height)),
            info: SIMD4(Int32(slice), 0, 0, 0),
            raster: SIMD4(Float(rasterSize.width), Float(rasterSize.height), 0, 0),
        )
        encoder.setComputePipelineState(kernels.maskUpload)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(rasters, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<MaskRasterParams>.stride, index: 0)
        encoder.dispatchGrid(width: rasterSize.width, height: rasterSize.height, pipeline: kernels.maskUpload)
        encoder.endEncoding()
        return slice
    }

    // MARK: - Failures

    private func recording(_ commands: any MTLCommandBuffer) -> Recording {
        if let recorded = recordings.last(where: { $0.commands === commands }) {
            return recorded
        }
        recordings.removeAll { $0.commands == nil || $0.commands?.status == .completed }
        let recorded = Recording(commands: commands, session: session)
        recordings.append(recorded)
        return recorded
    }

    /// The painting cache and the scratch stroke texture, zero only once a stroke applies, are in
    /// `commands`.
    func recordPainting(in commands: any MTLCommandBuffer) {
        recording(commands).painting = true
    }
}

extension MaskResources: CommandBufferRollback {
    /// The same whether `commands` was dropped or failed on the GPU, which may have run part of it.
    func rollBack(_ commands: any MTLCommandBuffer, after _: CommandBufferFailure) {
        guard let index = recordings.firstIndex(where: { $0.commands === commands }) else { return }
        let recorded = recordings.remove(at: index)
        for (maps, texture, keys) in recorded.edges {
            maps.texture = texture
            maps.keys = keys
        }
        for (maps, texture, keys) in recorded.colors {
            maps.texture = texture
            maps.keys = keys
        }
        guard recorded.session === session else {
            parked.removeAll { $0.session === recorded.session }
            return
        }
        if let (texture, keys, lastUsed) = recorded.rasters {
            rasters = texture
            self.keys = keys
            self.lastUsed = lastUsed
        }
        for slice in recorded.slices where slice < keys.count {
            keys[slice] = nil
        }
        if recorded.painting {
            paintBase = nil
            scratch = nil
        }
        if recorded.editGuide {
            editGuide = nil
        }
        if recorded.analysisGuide {
            analysisGuide = nil
        }
    }
}
