import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels

/// Point Color's eyedropper (TON-29): the colour a swatch is given where the user clicks.
public extension RedlampEngine {
    func pointColorInput(sampledAt point: CGPoint, radius: Double, recipe: EditRecipe) async -> OKLCh? {
        guard let current = currentSession() else { return nil }
        return await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(
                    returning: try? samplePointColorInput(at: point, radius: radius, recipe: recipe, session: current),
                )
            }
        }
    }
}

extension RedlampEngine {
    /// What Point Color receives at `point`, averaged over a disc of `radius` (a fraction of the image
    /// height; 0 for a click): the edit, its masks included, rendered at the guide's size in the
    /// `pointColorInput` encoding, and read a level down, further for a wider disc.
    func samplePointColorInput(
        at point: CGPoint, radius: Double, recipe: EditRecipe, session: ImageSession,
    ) throws -> OKLCh {
        guard let commands = queue.makeCommandBuffer(),
              let buffer = device.makeBuffer(length: 8, options: .storageModeShared)
        else { throw EngineError.gpuUnavailable }
        masks.use(session, commands: commands)
        let size = masks.guideSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: true,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        try encodeDevelop(
            recipe, session: session, into: texture, size: size, encoding: .pointColorInput, showClipping: false,
            commands: commands, cacheDetail: false, detail: false, retouchMaps: .refreshLater,
        )
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.generateMipmaps(for: texture)
        let disc = ColorRangeMath.level(radius: radius, guideHeight: size.height).rounded(.up)
        let level = min(Int(disc), texture.mipmapLevelCount - 1)
        let width = max(1, texture.width >> level)
        let height = max(1, texture.height >> level)
        let x = min(max(Int(point.x * Double(width)), 0), width - 1)
        let y = min(max(Int(point.y * Double(height)), 0), height - 1)
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: 8, destinationBytesPerImage: 8,
        )
        blit.endEncoding()
        try finish(commands)
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        let lab = SIMD3(Double(halves[0]), Double(halves[1]), Double(halves[2]))
        let hue = atan2(lab.z, lab.y) * 180 / .pi
        return OKLCh(lightness: lab.x, chroma: hypot(lab.y, lab.z), hue: hue < 0 ? hue + 360 : hue)
    }
}
