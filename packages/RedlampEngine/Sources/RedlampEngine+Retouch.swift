import Foundation
import Metal
import RedlampEngineAPI
import simd

extension RedlampEngine {
    public func retouchSource(for spot: RetouchSpot, recipe: EditRecipe) async -> ImagePoint? {
        guard let current = currentSession() else { return nil }
        return await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(returning: try? findRetouchSource(for: spot, recipe: recipe, session: current))
            }
        }
    }

    /// Reads the pyramid level `RetouchSource` searches, around the spot, back from the GPU.
    func findRetouchSource(
        for spot: RetouchSpot,
        recipe: EditRecipe,
        session base: ImageSession,
    ) throws -> ImagePoint? {
        guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        let session = try retouch.session(for: recipe, base: base, commands: commands)
        let pyramid = session.pyramid
        guard let placement = RetouchStage.placement(
            spot, orientation: session.orientation, width: pyramid.width, height: pyramid.height,
        ) else { return nil }
        let level = RetouchSource.level(radius: placement.radius, levels: pyramid.mipmapLevelCount)
        let scale = Float(1 << level)
        let levelWidth = max(1, pyramid.width >> level), levelHeight = max(1, pyramid.height >> level)
        let center = placement.center / scale, radius = placement.radius / scale
        let margin = Int(ceil(radius * (RetouchSource.reach + RetouchSource.rim))) + 2
        let x0 = max(Int(center.x) - margin, 0), y0 = max(Int(center.y) - margin, 0)
        let x1 = min(Int(center.x) + margin, levelWidth), y1 = min(Int(center.y) + margin, levelHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        let (width, height) = (x1 - x0, y1 - y0)
        guard let buffer = device.makeBuffer(length: width * height * 8, options: .storageModeShared),
              let blit = commands.makeBlitCommandEncoder()
        else { throw EngineError.gpuUnavailable }
        blit.copy(
            from: pyramid, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: width * 8, destinationBytesPerImage: width * height * 8,
        )
        blit.endEncoding()
        try finish(commands)

        let weights = DetailStage.luma(session)
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        var values = [Float](repeating: 0, count: width * height)
        for index in values.indices {
            let rgb = SIMD3(Float(halves[index * 4]), Float(halves[index * 4 + 1]), Float(halves[index * 4 + 2]))
            values[index] = log(max(simd_dot(rgb, SIMD3(weights.x, weights.y, weights.z)), 1e-4))
        }
        let origin = SIMD2(Float(x0), Float(y0))
        guard let found = RetouchSource.search(
            RetouchSource.Image(width: width, height: height, values: values),
            center: center - origin, radius: radius, matchBrightness: spot.mode == .heal,
        ) else { return nil }
        let texel = (found + origin) * scale
        let point = orientedCoordinate(
            SIMD2(Double(texel.x) / Double(pyramid.width), Double(texel.y) / Double(pyramid.height)),
            orientation: session.orientation,
        )
        return ImagePoint(x: point.x, y: point.y)
    }
}
