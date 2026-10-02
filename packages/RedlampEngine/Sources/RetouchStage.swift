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
    /// Points on a spot's rim for Heal.
    static let rimSamples = 256
    /// A recipe and the one it's compared with.
    private static let maximumEntries = 2

    /// Where a spot lands in the pyramid, in level-0 texels.
    struct Placement: Equatable {
        var center: SIMD2<Float>
        var source: SIMD2<Float>
        var radius: Float
        var origin: SIMD2<Int>
        var size: SIMD2<Int>
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
        let center = texel(spot.center)
        let source = texel(spot.source)
        guard radius.isFinite, center.x.isFinite, center.y.isFinite, source.x.isFinite, source.y.isFinite,
              abs(center.x) < 1e7, abs(center.y) < 1e7
        else { return nil }
        let low = SIMD2(
            max(Int(floor(center.x - radius)) - 1, 0), max(Int(floor(center.y - radius)) - 1, 0),
        )
        let high = SIMD2(
            min(Int(ceil(center.x + radius)) + 1, width), min(Int(ceil(center.y + radius)) + 1, height),
        )
        guard radius > 0, high.x > low.x, high.y > low.y else { return nil }
        return Placement(center: center, source: source, radius: radius, origin: low, size: high &- low)
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
        let rimLength = Self.rimSamples * MemoryLayout<SIMD4<Float>>.stride
        guard let scratch = device.makeTexture(descriptor: descriptor),
              let rim = device.makeBuffer(length: rimLength, options: .storageModePrivate),
              let encoder = commands.makeComputeCommandEncoder()
        else { throw EngineError.gpuUnavailable }
        encoder.label = "Retouch"
        let heal = spot.mode == .heal
        let box = SIMD4<Int32>(
            Int32(placement.origin.x), Int32(placement.origin.y), Int32(placement.size.x), Int32(placement.size.y),
        )
        let featherStart = Float(1 - min(max(spot.feather, 0), 100) / 100)
        let opacity = Float(min(max(spot.opacity, 0), 100) / 100)
        var params = RetouchParams(
            box: box,
            circle: SIMD4<Float>(placement.center.x, placement.center.y, placement.radius, featherStart),
            source: SIMD4<Float>(placement.source.x, placement.source.y, opacity, heal ? 1 : 0),
            samples: SIMD4<Int32>(Int32(Self.rimSamples), 0, 0, 0),
        )
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<RetouchParams>.stride, index: 0)
        encoder.setBuffer(rim, offset: 0, index: 1)
        if heal {
            encoder.setComputePipelineState(kernels.retouchRim)
            encoder.dispatchGrid(width: Self.rimSamples, height: 1, pipeline: kernels.retouchRim)
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
