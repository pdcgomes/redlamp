import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd

/// Remove, Heal and Clone spots baked into a copy of the session's pyramid (see `Retouch.metal`).
/// The copy stands in for the photo everywhere after it: Detail, the develop kernel and its masks.
///
/// Owned by the engine's render queue.
final class RetouchStage {
    /// Points on a circle's rim for Heal.
    static let rimSamples = 256
    /// The most points on a brushed spot's outline, and on its stroke.
    static let maximumOutline = 1024
    static let maximumStroke = 512
    /// A recipe and the one it's compared with.
    private static let maximumEntries = 2

    /// Where a spot lands in the pyramid, in level-0 texels.
    struct Placement: Equatable {
        /// The stroke, the spot's own point first; one point for a circle.
        var points: [SIMD2<Float>]
        /// From the spot to its source.
        var offset: SIMD2<Float>
        var radius: Float
        var origin: SIMD2<Int>
        var size: SIMD2<Int>

        var center: SIMD2<Float> {
            points[0]
        }

        var source: SIMD2<Float> {
            points[0] + offset
        }
    }

    private struct Entry {
        var original: ImageSession
        var spots: [RetouchSpot]
        var retouched: ImageSession
    }

    /// A Remove spot's fill: where each texel of a region at the working level copies from.
    struct FillMap {
        var level: Int
        /// The region, in the working level's texels.
        var origin: SIMD2<Int>
        var size: SIMD2<Int>
        /// Per texel of the region, the move to copy from, in level-0 texels.
        var offsets: [SIMD2<Float>]
        /// Keeps the session alive so its identifier can't be reused while cached.
        var owner: ImageSession
    }

    /// A Remove spot and the spots before it, which its fill depends on.
    private struct FillKey: Hashable {
        var session: ObjectIdentifier
        var spots: [RetouchSpot]
    }

    /// Fills are kept across rebuilds, so moving another spot doesn't fill this one again.
    private static let maximumFills = 32
    /// The working level makes a hole at most this many texels across.
    static let fillExtent: Double = 96

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let kernels: KernelLibrary
    private var entries: [Entry] = []
    private var fills: [FillKey: FillMap] = [:]
    private var fillOrder: [FillKey] = []
    private lazy var filler = ContentAwareFill(device: device, queue: queue, kernels: kernels)
    /// Fills computed so far (not found in the cache), for tests.
    private(set) var fillsComputed = 0

    init(device: any MTLDevice, kernels: KernelLibrary, queue: any MTLCommandQueue) {
        self.device = device
        self.kernels = kernels
        self.queue = queue
    }

    /// `session` with the recipe's spots in its pyramid, encoding the work into `commands`
    /// unless it's cached. The session itself when the recipe has none.
    func session(
        for recipe: EditRecipe, base session: ImageSession, commands: any MTLCommandBuffer,
    ) throws -> ImageSession {
        let original = session.original
        let spots = recipe.spots.filter { !$0.isEmpty }
        guard !spots.isEmpty else { return original }
        if let index = entries.firstIndex(where: { $0.original === original && $0.spots == spots }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.retouched
        }
        // Renders wait for their commands, so an evicted copy is free to reuse.
        var reusable: (any MTLTexture)?
        if entries.count >= Self.maximumEntries {
            let evicted = entries.removeFirst()
            if evicted.original === original {
                reusable = evicted.retouched.pyramid
            }
        }
        let pyramid = original.pyramid
        let texture = try reusable ?? makeCopy(of: pyramid)
        // A Remove spot not filled before reads the photo as the spots before it left it, so the
        // spots are then applied in command buffers of their own, each waited for.
        let keys = spots.indices.map { index in
            spots[index]
                .mode == .remove ? FillKey(session: ObjectIdentifier(original), spots: Array(spots[...index])) : nil
        }
        let synchronous = keys.contains { $0.map { fills[$0] == nil } ?? false }
        var buffer = synchronous ? try makeCommandBuffer() : commands
        guard let blit = buffer.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.label = "Retouch copy"
        blit.copy(
            from: pyramid, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: pyramid.width, height: pyramid.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(),
        )
        blit.endEncoding()
        for (index, spot) in spots.enumerated() {
            guard let placement = Self.placement(
                spot, orientation: original.orientation, width: pyramid.width, height: pyramid.height,
            ) else { continue }
            guard let key = keys[index] else {
                try encode(spot, placement: placement, into: texture, commands: buffer)
                continue
            }
            if fills[key] == nil {
                try generateMipmaps(texture, commands: buffer)
                try finish(buffer)
                fills[key] = try computeFill(placement, texture: texture, owner: original)
                fillOrder.append(key)
                if fillOrder.count > Self.maximumFills {
                    fills[fillOrder.removeFirst()] = nil
                }
                buffer = try makeCommandBuffer()
            }
            if let map = fills[key] {
                try encodeFill(spot, placement: placement, map: map, into: texture, commands: buffer)
            }
        }
        try generateMipmaps(texture, commands: buffer)
        if synchronous {
            try finish(buffer)
        }
        let retouched = ImageSession(retouching: original, pyramid: texture)
        entries.append(Entry(original: original, spots: spots, retouched: retouched))
        return retouched
    }

    /// Nil when the spot misses the photo.
    static func placement(_ spot: RetouchSpot, orientation: Int, width: Int, height: Int) -> Placement? {
        func texel(_ point: ImagePoint) -> SIMD2<Float> {
            let source = sourceCoordinate(SIMD2(point.x, point.y), orientation: orientation)
            return SIMD2(Float(source.x * Double(width)), Float(source.y * Double(height)))
        }
        let orientedHeight = orientation >= 5 ? width : height
        let radius = Float(min(max(spot.radius, 0), 1) * Double(orientedHeight))
        var points = spot.points().map(texel)
        if points.count > maximumStroke {
            let stride = Double(points.count - 1) / Double(maximumStroke - 1)
            points = (0 ..< maximumStroke).map { points[Int((Double($0) * stride).rounded())] }
        }
        let source = texel(spot.source)
        let finite = { (point: SIMD2<Float>) in
            point.x.isFinite && point.y.isFinite && simd_reduce_max(simd_abs(point)) < 1e7
        }
        guard radius.isFinite, radius > 0, points.allSatisfy(finite), finite(source) else { return nil }
        let low = points.dropFirst().reduce(points[0], simd_min) - radius
        let high = points.dropFirst().reduce(points[0], simd_max) + radius
        let origin = SIMD2(max(Int(floor(low.x)) - 1, 0), max(Int(floor(low.y)) - 1, 0))
        let end = SIMD2(min(Int(ceil(high.x)) + 1, width), min(Int(ceil(high.y)) + 1, height))
        guard end.x > origin.x, end.y > origin.y else { return nil }
        return Placement(
            points: points,
            offset: source - points[0],
            radius: radius,
            origin: origin,
            size: end &- origin,
        )
    }

    /// Points on the edge of the spot's shape, about evenly spaced, and their spacing: a circle's
    /// rim, or the outline of the discs along a stroke (a quarter radius apart).
    static func outline(_ placement: Placement) -> (points: [SIMD2<Float>], spacing: Float) {
        let radius = placement.radius
        guard placement.points.count > 1 else {
            let count = rimSamples
            let points = (0 ..< count).map { index in
                let angle = 2 * Float.pi * (Float(index) + 0.5) / Float(count)
                return placement.center + radius * SIMD2(cos(angle), sin(angle))
            }
            return (points, 2 * .pi * radius / Float(count))
        }
        var dabs = [placement.points[0]]
        for next in placement.points.dropFirst() {
            let last = dabs[dabs.count - 1]
            let steps = max(Int(ceil(simd_distance(last, next) / (radius / 4))), 1)
            for step in 1 ... steps {
                dabs.append(last + (next - last) * Float(step) / Float(steps))
            }
        }
        let perDab = min(max(Int(ceil(2 * Float.pi * radius)), 32), 128)
        let directions = (0 ..< perDab).map { index in
            let angle = 2 * Float.pi * (Float(index) + 0.5) / Float(perDab)
            return radius * SIMD2(cos(angle), sin(angle))
        }
        var points: [SIMD2<Float>] = []
        let reach2 = 4 * radius * radius, inside2 = radius * radius * 0.998
        for (index, dab) in dabs.enumerated() {
            let neighbours = dabs.indices.filter { $0 != index && simd_distance_squared(dabs[$0], dab) < reach2 }
            for direction in directions {
                let point = dab + direction
                if neighbours.allSatisfy({ simd_distance_squared(dabs[$0], point) >= inside2 }) {
                    points.append(point)
                }
            }
        }
        var spacing = 2 * .pi * radius / Float(perDab)
        if points.count > maximumOutline {
            let stride = Float(points.count) / Float(maximumOutline)
            points = (0 ..< maximumOutline).map { points[min(Int(Float($0) * stride), points.count - 1)] }
            spacing *= stride
        }
        return (points, spacing)
    }

    private func makeCopy(of pyramid: any MTLTexture) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pyramid.pixelFormat, width: pyramid.width, height: pyramid.height, mipmapped: true,
        )
        descriptor.mipmapLevelCount = pyramid.mipmapLevelCount
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        texture.label = "Retouched pyramid"
        return texture
    }

    private func makeCommandBuffer() throws -> any MTLCommandBuffer {
        guard let buffer = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        buffer.label = "Retouch"
        return buffer
    }

    private func finish(_ buffer: any MTLCommandBuffer) throws {
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }
    }

    private func generateMipmaps(_ texture: any MTLTexture, commands: any MTLCommandBuffer) throws {
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
    }

    /// How far `point` is from the stroke (from the point, for a circle).
    static func strokeDistance(_ point: SIMD2<Float>, _ stroke: [SIMD2<Float>]) -> Float {
        var nearest = simd_distance(point, stroke[0])
        for index in stroke.indices.dropFirst() {
            let a = stroke[index - 1], ab = stroke[index] - a
            let t = min(max(simd_dot(point - a, ab) / max(simd_length_squared(ab), 1e-6), 0), 1)
            nearest = min(nearest, simd_distance(point, a + ab * t))
        }
        return nearest
    }

    /// Fills the spot's hole (`ContentAwareFill`) on the pyramid level where it's at most
    /// `fillExtent` texels across, from the photo up to twice its size around it, read back from
    /// `texture` as it now is.
    private func computeFill(_ placement: Placement, texture: any MTLTexture, owner: ImageSession) throws -> FillMap? {
        fillsComputed += 1
        let extent = Double(max(placement.size.x, placement.size.y))
        let level = min(max(Int(ceil(log2(extent / Self.fillExtent))), 0), texture.mipmapLevelCount - 1)
        let scale = Float(1 << level)
        let levelWidth = max(1, texture.width >> level), levelHeight = max(1, texture.height >> level)
        let low = SIMD2<Float>(Float(placement.origin.x), Float(placement.origin.y)) / scale
        let high = SIMD2<Float>(
            Float(placement.origin.x + placement.size.x),
            Float(placement.origin.y + placement.size.y),
        )
            / scale
        let margin = max(Int(ceil(simd_reduce_max(high - low) * 2)), 24)
        let x0 = max(Int(floor(low.x)) - margin, 0), y0 = max(Int(floor(low.y)) - margin, 0)
        let x1 = min(Int(ceil(high.x)) + margin, levelWidth), y1 = min(Int(ceil(high.y)) + margin, levelHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        let (width, height) = (x1 - x0, y1 - y0)
        guard let readback = device.makeBuffer(length: width * height * 8, options: .storageModeShared) else {
            throw EngineError.gpuUnavailable
        }
        let commands = try makeCommandBuffer()
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
            destinationBytesPerRow: width * 8, destinationBytesPerImage: width * height * 8,
        )
        blit.endEncoding()
        try finish(commands)
        let halves = readback.contents().assumingMemoryBound(to: Float16.self)
        var pixels: [SIMD3<Float>] = []
        var hole: [Bool] = []
        pixels.reserveCapacity(width * height)
        hole.reserveCapacity(width * height)
        // Texels whose centre is inside the spot, or within three quarters of a texel of its edge.
        let reach = placement.radius + 0.75 * scale
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let rgb = SIMD3(Float(halves[index]), Float(halves[index + 1]), Float(halves[index + 2]))
                pixels.append(simd_max(rgb, .zero).squareRoot())
                let centre = (SIMD2(Float(x0 + x), Float(y0 + y)) + 0.5) * scale
                hole.append(Self.strokeDistance(centre, placement.points) < reach)
            }
        }
        let moves = try filler.fill(ContentAwareFill.Region(width: width, height: height, pixels: pixels, hole: hole))
        // Around the hole, each texel takes the nearest hole texel's move, so the fill reaches
        // the spot's rim, where Heal's seams are measured.
        var offsets = moves.map { SIMD2(Float($0.x), Float($0.y)) * scale }
        var assigned = hole
        for _ in 0 ..< 8 {
            let before = assigned
            for y in 0 ..< height {
                for x in 0 ..< width where !before[y * width + x] {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let (nx, ny) = (x + dx, y + dy)
                        guard nx >= 0, ny >= 0, nx < width, ny < height, before[ny * width + nx] else { continue }
                        offsets[y * width + x] = offsets[ny * width + nx]
                        assigned[y * width + x] = true
                        break
                    }
                }
            }
        }
        return FillMap(
            level: level, origin: SIMD2(x0, y0), size: SIMD2(width, height), offsets: offsets, owner: owner,
        )
    }

    /// Renders the fill at full resolution from its moves (`rl_fill_render`), then blends it in as
    /// Heal does, so its edge matches the photo around it.
    private func encodeFill(
        _ spot: RetouchSpot, placement: Placement, map: FillMap, into texture: any MTLTexture,
        commands: any MTLCommandBuffer,
    ) throws {
        let scale = 1 << map.level
        let margin = 8
        let origin = SIMD2(max(placement.origin.x - margin, 0), max(placement.origin.y - margin, 0))
        let end = SIMD2(
            min(placement.origin.x + placement.size.x + margin, texture.width),
            min(placement.origin.y + placement.size.y + margin, texture.height),
        )
        guard end.x > origin.x, end.y > origin.y else { return }
        let size = end &- origin
        let offsetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: map.size.x, height: map.size.y, mipmapped: false,
        )
        offsetDescriptor.usage = [.shaderRead]
        offsetDescriptor.storageMode = .shared
        let fillDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: size.x, height: size.y, mipmapped: false,
        )
        fillDescriptor.usage = [.shaderRead, .shaderWrite]
        fillDescriptor.storageMode = .private
        guard let offsets = device.makeTexture(descriptor: offsetDescriptor),
              let fill = device.makeTexture(descriptor: fillDescriptor),
              let encoder = commands.makeComputeCommandEncoder()
        else { throw EngineError.gpuUnavailable }
        map.offsets.withUnsafeBytes { bytes in
            offsets.replace(
                region: MTLRegionMake2D(0, 0, map.size.x, map.size.y), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: map.size.x * MemoryLayout<SIMD2<Float>>.stride,
            )
        }
        encoder.label = "Fill"
        var params = FillRenderParams(
            box: SIMD4(Int32(origin.x), Int32(origin.y), Int32(size.x), Int32(size.y)),
            offsets: SIMD4(
                Int32(map.origin.x * scale), Int32(map.origin.y * scale), Int32(map.size.x), Int32(map.size.y),
            ),
            scale: SIMD4(Float(scale), 0, 0, 0),
        )
        encoder.setComputePipelineState(kernels.fillRender)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(offsets, index: 1)
        encoder.setTexture(fill, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<FillRenderParams>.stride, index: 0)
        encoder.dispatchGrid(width: size.x, height: size.y, pipeline: kernels.fillRender)
        encoder.endEncoding()
        try encode(spot, placement: placement, into: texture, commands: commands, fill: (fill, origin))
    }

    /// Writes the spot into a scratch texture, then copies that over the pyramid, so a source
    /// overlapping the destination reads the photo before the spot. With `fill`, the replacement
    /// comes from that texture (placed at its origin) and is always healed in.
    private func encode(
        _ spot: RetouchSpot, placement: Placement, into texture: any MTLTexture, commands: any MTLCommandBuffer,
        fill: (texture: any MTLTexture, origin: SIMD2<Int>)? = nil,
    ) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: placement.size.x, height: placement.size.y, mipmapped: false,
        )
        descriptor.usage = [.shaderWrite]
        descriptor.storageMode = .private
        let heal = spot.mode == .heal || fill != nil
        let outline = heal ? Self.outline(placement) : (points: [placement.center], spacing: 1)
        let point = MemoryLayout<SIMD2<Float>>.stride
        let ratioLength = outline.points.count * MemoryLayout<SIMD4<Float>>.stride
        guard let scratch = device.makeTexture(descriptor: descriptor),
              let ratios = device.makeBuffer(length: ratioLength, options: .storageModePrivate),
              let filtered = device.makeBuffer(length: ratioLength, options: .storageModePrivate),
              let rim = device.makeBuffer(
                  bytes: outline.points, length: outline.points.count * point, options: .storageModeShared,
              ),
              let stroke = device.makeBuffer(
                  bytes: placement.points, length: placement.points.count * point, options: .storageModeShared,
              ),
              let encoder = commands.makeComputeCommandEncoder()
        else { throw EngineError.gpuUnavailable }
        encoder.label = "Retouch"
        let box = SIMD4<Int32>(
            Int32(placement.origin.x), Int32(placement.origin.y), Int32(placement.size.x), Int32(placement.size.y),
        )
        let featherStart = Float(1 - min(max(spot.feather, 0), 100) / 100)
        let opacity = Float(min(max(spot.opacity, 0), 100) / 100)
        var params = RetouchParams(
            box: box,
            shape: SIMD4<Float>(placement.radius, featherStart, outline.spacing, placement.radius / 2),
            source: fill.map { SIMD4<Float>(Float($0.origin.x), Float($0.origin.y), opacity, 1) }
                ?? SIMD4<Float>(placement.offset.x, placement.offset.y, opacity, heal ? 1 : 0),
            counts: SIMD4<Int32>(Int32(outline.points.count), Int32(placement.points.count), fill == nil ? 0 : 1, 0),
        )
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(fill?.texture ?? texture, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<RetouchParams>.stride, index: 0)
        encoder.setBuffer(ratios, offset: 0, index: 1)
        encoder.setBuffer(rim, offset: 0, index: 2)
        encoder.setBuffer(stroke, offset: 0, index: 3)
        if heal {
            encoder.setComputePipelineState(kernels.retouchRim)
            encoder.dispatchGrid(width: outline.points.count, height: 1, pipeline: kernels.retouchRim)
            encoder.setBuffer(filtered, offset: 0, index: 4)
            encoder.setComputePipelineState(kernels.retouchRimMedian)
            encoder.dispatchGrid(width: outline.points.count, height: 1, pipeline: kernels.retouchRimMedian)
            encoder.setBuffer(filtered, offset: 0, index: 1)
        }
        encoder.setComputePipelineState(kernels.retouchApply)
        encoder.setTexture(scratch, index: 1)
        encoder.dispatchGrid(width: placement.size.x, height: placement.size.y, pipeline: kernels.retouchApply)
        encoder.endEncoding()
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.copy(
            from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: placement.size.x, height: placement.size.y, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: placement.origin.x, y: placement.origin.y, z: 0),
        )
        blit.endEncoding()
    }
}
