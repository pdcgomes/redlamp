import Foundation
import Metal
import RedlampEngineAPI
import simd

public extension RedlampEngine {
    func retouchSource(for spot: RetouchSpot, recipe: EditRecipe) async -> ImagePoint? {
        guard let current = currentSession() else { return nil }
        return await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(returning: try? findRetouchSource(for: spot, recipe: recipe, session: current))
            }
        }
    }

    func detectDust(recipe: EditRecipe, sensitivity: Double) async -> [DetectedSpot] {
        guard let current = currentSession() else { return [] }
        return await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                let found = try? findDust(recipe: recipe, sensitivity: sensitivity, session: current)
                continuation.resume(returning: found ?? [])
            }
        }
    }

    func detectDust(
        in photos: [(url: URL, recipe: EditRecipe)], sensitivity: Double, progress: @escaping @Sendable (Int) -> Void,
    ) async -> [URL: [DetectedSpot]] {
        var frames: [ShootDust.Frame] = []
        for (index, photo) in photos.enumerated() {
            defer { progress(index + 1) }
            guard let session = try? await sessions.session(for: photo.url) else { continue }
            // Repetition across frames weeds out the scene, so each frame is looked at more keenly.
            let found = await withCheckedContinuation { continuation in
                renderQueue.async { [self] in
                    let specks = try? findSpecks(
                        recipe: photo.recipe, sensitivity: min(sensitivity + 15, 100), session: session,
                    )
                    continuation.resume(returning: specks ?? [])
                }
            }
            frames.append(ShootDust.Frame(url: photo.url, recipe: photo.recipe, session: session, specks: found))
        }
        return ShootDust.consistent(frames)
    }

    internal func findDust(
        recipe: EditRecipe,
        sensitivity: Double,
        session: ImageSession,
    ) throws -> [DetectedSpot] {
        try findSpecks(recipe: recipe, sensitivity: sensitivity, session: session).map(\.spot)
    }

    /// Reads back the pyramid level whose long edge is 2000 to 4000 texels, and looks for dust
    /// there, away from the recipe's spots.
    internal func findSpecks(
        recipe: EditRecipe,
        sensitivity: Double,
        session base: ImageSession,
    ) throws -> [ShootDust.Sighting] {
        guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        let (session, buffer, width, height) = try encoding(commands) {
            let session = try retouch.session(for: recipe, base: base, commands: commands)
            let pyramid = session.pyramid
            let longEdge = max(pyramid.width, pyramid.height)
            let level = min(max(Int(floor(log2(Double(longEdge) / 2000))), 0), pyramid.mipmapLevelCount - 1)
            let width = max(1, pyramid.width >> level), height = max(1, pyramid.height >> level)
            guard let buffer = device.makeBuffer(length: width * height * 8, options: .storageModeShared),
                  let blit = commands.makeBlitCommandEncoder()
            else { throw EngineError.gpuUnavailable }
            blit.copy(
                from: pyramid, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                destinationBytesPerRow: width * 8, destinationBytesPerImage: width * height * 8,
            )
            blit.endEncoding()
            return (session, buffer, width, height)
        }
        try finish(commands)
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        let pixels = (0 ..< width * height).map { index in
            SIMD3(Float(halves[index * 4]), Float(halves[index * 4 + 1]), Float(halves[index * 4 + 2]))
        }
        let weights = DetailStage.luma(session)
        let specks = DustDetector.detect(
            DustDetector.Image(width: width, height: height, pixels: pixels),
            luma: SIMD3(weights.x, weights.y, weights.z), sensitivity: sensitivity,
        )
        let orientedHeight = Double(session.orientation >= 5 ? width : height)
        let placed = recipe.spots.compactMap {
            RetouchStage.placement($0, orientation: session.orientation, width: width, height: height)
        }
        return specks.compactMap { speck in
            // Already covered by a spot.
            let covered = placed.contains { placement in
                placement.points.contains { simd_distance($0, speck.center) < placement.radius + speck.radius }
            }
            guard !covered else { return nil }
            let point = orientedCoordinate(
                SIMD2(Double(speck.center.x) / Double(width), Double(speck.center.y) / Double(height)),
                orientation: session.orientation,
            )
            let spot = DetectedSpot(
                center: ImagePoint(x: point.x, y: point.y), radius: Double(speck.radius) / orientedHeight,
                strength: Double(speck.strength),
            )
            return ShootDust.Sighting(spot: spot, surroundings: speck.surroundings)
        }
    }

    /// Reads the pyramid level `RetouchSource` searches, around the spot, back from the GPU.
    internal func findRetouchSource(
        for spot: RetouchSpot,
        recipe: EditRecipe,
        session base: ImageSession,
    ) throws -> ImagePoint? {
        // Placed on the original, which the retouched copy matches in shape, before the spots go into a
        // command buffer: a return once they had would drop the buffer without rolling it back.
        let pyramid = base.original.pyramid
        guard let placement = RetouchStage.placement(
            spot, orientation: base.orientation, width: pyramid.width, height: pyramid.height,
        ) else { return nil }
        let level = RetouchSource.level(radius: placement.radius, levels: pyramid.mipmapLevelCount)
        let scale = Float(1 << level)
        let levelWidth = max(1, pyramid.width >> level), levelHeight = max(1, pyramid.height >> level)
        let center = placement.center / scale, radius = placement.radius / scale
        let stroke = placement.points.dropFirst().map { ($0 - placement.center) / scale }
        let low = stroke.reduce(center) { simd_min($0, center + $1) }
        let high = stroke.reduce(center) { simd_max($0, center + $1) }
        let margin = Int(ceil(radius * (RetouchSource.reach + RetouchSource.rim))) + 2
        let x0 = max(Int(low.x) - margin, 0), y0 = max(Int(low.y) - margin, 0)
        let x1 = min(Int(high.x) + margin, levelWidth), y1 = min(Int(high.y) + margin, levelHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        let (width, height) = (x1 - x0, y1 - y0)
        guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        let (session, buffer) = try encoding(commands) {
            let session = try retouch.session(for: recipe, base: base, commands: commands)
            guard let buffer = device.makeBuffer(length: width * height * 8, options: .storageModeShared),
                  let blit = commands.makeBlitCommandEncoder()
            else { throw EngineError.gpuUnavailable }
            blit.copy(
                from: session.pyramid, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                destinationBytesPerRow: width * 8, destinationBytesPerImage: width * height * 8,
            )
            blit.endEncoding()
            return (session, buffer)
        }
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
            center: center - origin, radius: radius, stroke: stroke, matchBrightness: spot.mode == .heal,
        ) else { return nil }
        let texel = (found + origin) * scale
        let point = orientedCoordinate(
            SIMD2(Double(texel.x) / Double(pyramid.width), Double(texel.y) / Double(pyramid.height)),
            orientation: session.orientation,
        )
        return ImagePoint(x: point.x, y: point.y)
    }
}
