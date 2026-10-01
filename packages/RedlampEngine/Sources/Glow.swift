import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels

/// Halation and bloom's per-session data: the light they spread (see `Glow.metal`), mipmapped
/// so the develop kernel reads wide blurs of it from its coarse levels.
enum Glow {
    /// The map's long edge at most, in texels.
    static let mapLongEdge = 1024
    /// Highlights near the clip point count as up to this many times brighter (4 stops).
    static let clipGain: Float = 16
    /// Where highlights fade into the glow, in pyramid units (1 is about the clip point).
    static let threshold: ClosedRange<Float> = 0.25 ... 1.0
    /// Where the clip point's extra energy starts.
    static let clipKnee: Float = 0.9

    static func encodeSource(
        pyramid: any MTLTexture,
        device: any MTLDevice,
        kernels: KernelLibrary,
        commands: any MTLCommandBuffer,
    ) throws -> any MTLTexture {
        let longEdge = max(pyramid.width, pyramid.height)
        let mapLevel = max(1, Int(ceil(log2(Double(longEdge) / Double(mapLongEdge)))))
        let level = min(mapLevel - 1, pyramid.mipmapLevelCount - 1)
        let width = max(1, pyramid.width >> (level + 1))
        let height = max(1, pyramid.height >> (level + 1))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let map = device.makeTexture(descriptor: descriptor),
              let encoder = commands.makeComputeCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }
        encoder.label = "Glow source"
        var params = GlowParams(
            size: SIMD4(Int32(width), Int32(height), Int32(level), 0),
            shape: SIMD4(clipGain, threshold.lowerBound, threshold.upperBound, clipKnee),
        )
        encoder.setComputePipelineState(kernels.glowSource)
        encoder.setTexture(pyramid, index: 0)
        encoder.setTexture(map, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<GlowParams>.stride, index: 0)
        encoder.dispatchGrid(width: width, height: height, pipeline: kernels.glowSource)
        encoder.endEncoding()
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.generateMipmaps(for: map)
        blit.endEncoding()
        return map
    }
}
