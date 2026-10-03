import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd

/// Heal and Clone spots baked into a copy of the session's pyramid (see `Retouch.metal`). The
/// copy stands in for the photo everywhere after it: Detail, the develop kernel and its masks.
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

    private let device: any MTLDevice
    private let kernels: KernelLibrary
    private var entries: [Entry] = []

    init(device: any MTLDevice, kernels: KernelLibrary) {
        self.device = device
        self.kernels = kernels
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
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.label = "Retouch copy"
        blit.copy(
            from: pyramid, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: pyramid.width, height: pyramid.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(),
        )
        blit.endEncoding()
        for spot in spots {
            guard let placement = Self.placement(
                spot, orientation: original.orientation, width: pyramid.width, height: pyramid.height,
            ) else { continue }
            try encode(spot, placement: placement, into: texture, commands: commands)
        }
        guard let mipmaps = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        mipmaps.generateMipmaps(for: texture)
        mipmaps.endEncoding()
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

    /// Writes the spot into a scratch texture, then copies that over the pyramid, so a source
    /// overlapping the destination reads the photo before the spot.
    private func encode(
        _ spot: RetouchSpot, placement: Placement, into texture: any MTLTexture, commands: any MTLCommandBuffer,
    ) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: placement.size.x, height: placement.size.y, mipmapped: false,
        )
        descriptor.usage = [.shaderWrite]
        descriptor.storageMode = .private
        let heal = spot.mode == .heal
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
            source: SIMD4<Float>(placement.offset.x, placement.offset.y, opacity, heal ? 1 : 0),
            counts: SIMD4<Int32>(Int32(outline.points.count), Int32(placement.points.count), 0, 0),
        )
        encoder.setTexture(texture, index: 0)
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
