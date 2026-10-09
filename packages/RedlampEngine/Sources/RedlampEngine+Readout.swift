import Foundation
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampKernels
import simd

/// The histogram's readout (UX-32): what the photo renders as under the pointer.
public extension RedlampEngine {
    func readout(at point: CGPoint, area: CGSize, recipe: EditRecipe) async -> PixelReadout? {
        guard let current = currentSession() else { return nil }
        return await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(returning: try? readout(at: point, area: area, recipe: recipe, session: current))
            }
        }
    }
}

extension RedlampEngine {
    /// The side of the square a readout averages, in rendered pixels.
    static let readoutPixels = 5

    /// `area` around `point` of the frame, rendered as the canvas renders it but without overlays,
    /// at `readoutPixels` square, and averaged in linear light. With the readout encoding, the
    /// stops under Redlamp Reproduction come from the same render.
    func readout(
        at point: CGPoint, area: CGSize, recipe: EditRecipe, session: ImageSession, output: OutputEncoding = .readout,
    ) throws -> PixelReadout {
        let side = Self.readoutPixels
        let width = min(max(area.width, 1e-6), 1)
        let height = min(max(area.height, 1e-6), 1)
        let region = ImageRect(
            x: min(max(point.x - width / 2, 0), 1 - width),
            y: min(max(point.y - height / 2, 0), 1 - height),
            width: width,
            height: height,
        )
        let bytes = side * side * 4 * MemoryLayout<Float16>.stride
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let commands = queue.makeCommandBuffer(),
              let texture = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        else { throw EngineError.gpuUnavailable }
        commands.label = "Readout"
        try encoding(commands) {
            try encodeDevelop(
                recipe, session: session, into: texture, size: PixelSize(width: side, height: side), region: region,
                encoding: output, showClipping: false, commands: commands, cacheDetail: false,
                retouchMaps: .refreshLater,
            )
            guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: side, height: side, depth: 1), to: buffer, destinationOffset: 0,
                destinationBytesPerRow: side * 4 * MemoryLayout<Float16>.stride, destinationBytesPerImage: bytes,
            )
            blit.endEncoding()
        }
        try finish(commands)
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        var sum = SIMD3<Double>.zero
        var luminance = 0.0
        for pixel in 0 ..< side * side {
            sum += SIMD3(Double(halves[pixel * 4]), Double(halves[pixel * 4 + 1]), Double(halves[pixel * 4 + 2]))
            luminance += Double(halves[pixel * 4 + 3])
        }
        let count = Double(side * side)
        var readout = Self.readout(linearDisplayP3: sum / count)
        if output == .readout, recipe.baseLook.isReproduction {
            readout.stops = log2(max(luminance / count, 1e-6) / PixelReadout.middleGrey)
        }
        return readout
    }

    /// The readout of a colour as the canvas holds it: linear Display P3.
    static func readout(linearDisplayP3 color: SIMD3<Double>) -> PixelReadout {
        let clamped = simd_clamp(color, .zero, SIMD3(repeating: 1))
        return PixelReadout(
            rgb: SIMD3(SRGB.encode(clamped.x), SRGB.encode(clamped.y), SRGB.encode(clamped.z)) * 100,
            lab: CIELab.d50(fromLinearDisplayP3: clamped),
        )
    }
}
