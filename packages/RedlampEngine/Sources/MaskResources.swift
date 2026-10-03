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
        case bitmap(String)
    }

    /// A photo's rasters and guides while another photo renders.
    private struct Parked {
        weak var session: ImageSession?
        var rasters: (any MTLTexture)?
        var keys: [RasterKey?]
        var lastUsed: [UInt64]
        var paintBase: (key: BrushMask, texture: any MTLTexture)?
        var editGuide: (recipe: EditRecipe, texture: any MTLTexture)?
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
    var scratch: (any MTLTexture)?
    /// The most recently painted brush without its last stroke.
    var paintBase: (key: BrushMask, texture: any MTLTexture)?

    private(set) var guideSize = PixelSize.zero
    private var editGuide: (recipe: EditRecipe, texture: any MTLTexture)?
    /// Never reused, since a photo's guide can be dropped and rendered again while caches still
    /// hold its old number.
    private(set) var editGuideGeneration = 0
    private var guideGenerations = 0
    private var analysisGuide: (any MTLTexture)?

    /// Oldest first.
    private var parked: [Parked] = []

    let emptyRasters: any MTLTexture
    let emptyGuide: any MTLTexture

    init(device: any MTLDevice, kernels: KernelLibrary) throws {
        self.device = device
        self.kernels = kernels
        (emptyRasters, emptyGuide) = try Self.emptyImages(device: device)
    }

    /// One transparent texel of each, bound when a render has no rasters or guide.
    static func emptyImages(device: any MTLDevice) throws -> (rasters: any MTLTexture, guide: any MTLTexture) {
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
        return (emptyRasters, emptyGuide)
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
        kept?.reclaim()
        rasters = kept?.rasters
        keys = kept?.keys ?? []
        lastUsed = kept?.lastUsed ?? []
        paintBase = kept?.paintBase
        editGuide = kept?.editGuide
        editGuideGeneration = kept?.editGuideGeneration ?? 0
        analysisGuide = kept?.analysisGuide
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

    /// The edit guide for `recipe` (its masks are ignored), rendering it with `render` when the
    /// global edit changed since the last one.
    func editGuide(
        for recipe: EditRecipe,
        commands: any MTLCommandBuffer,
        render: (EditRecipe, any MTLTexture) throws -> Void,
    ) throws -> any MTLTexture {
        var global = recipe
        global.masks = []
        if let editGuide, editGuide.recipe == global {
            return editGuide.texture
        }
        let texture = try editGuide?.texture ?? makeGuide()
        try render(global, texture)
        try generateMipmaps(texture, commands: commands)
        editGuide = (global, texture)
        guideGenerations += 1
        editGuideGeneration = guideGenerations
        return texture
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

    static func key(for shape: MaskShape) -> RasterKey? {
        switch shape {
        case let .brush(brush): .brush(brush)
        case let .ai(mask) where mask.bitmap.png != nil: .bitmap(mask.bitmap.sha256)
        case let .depthRange(range) where range.depth.bitmap.png != nil: .bitmap(range.depth.bitmap.sha256)
        default: nil
        }
    }

    /// The slice of every raster component, drawing the ones not already on the GPU.
    func slices(
        for components: [MaskComponent],
        analysisGuide: (any MTLTexture)?,
        commands: any MTLCommandBuffer,
    ) throws -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var used = Set<Int>()
        for component in components {
            guard let key = Self.key(for: component.shape) else { continue }
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
                try upload(mask.bitmap, avoiding: used, commands: commands)
            case let .depthRange(range):
                try upload(range.depth.bitmap, avoiding: used, commands: commands)
            default:
                nil
            }
            guard let slice = drawn else { continue }
            slicesDrawn += 1
            keys[slice] = key
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

    private func upload(_ bitmap: MaskBitmap, avoiding used: Set<Int>, commands: any MTLCommandBuffer) throws -> Int? {
        guard let png = bitmap.png, let gray = GrayMask.decode(png) else { return nil }
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
}
