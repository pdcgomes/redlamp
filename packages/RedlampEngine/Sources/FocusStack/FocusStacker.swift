import Foundation
import Metal
import MetalPerformanceShaders
import RedlampEngineAPI
import RedlampKernels
import simd

/// Focus stacking on the GPU: analysis copies for alignment, warping frames into the reference,
/// and (next) the depth solve and fusion. Frames are balanced linear camera RGB (`DemosaicedFrame`).
final class FocusStacker {
    /// Long edge of the copies alignment runs on: enough for sub-pixel accuracy at full resolution.
    static let analysisLongEdge = 2048

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init(device: any MTLDevice, queue: any MTLCommandQueue, kernels: KernelLibrary) {
        self.device = device
        self.queue = queue
        self.kernels = kernels
    }

    /// A Lanczos-downscaled copy of `frame` (or the frame itself if already small) on the CPU, with
    /// a long edge of at most `longEdge`: the alignment copy by default, a quarter of the frame
    /// for the depth solve.
    func analyse(_ frame: any MTLTexture, longEdge: Int = FocusStacker.analysisLongEdge) throws -> FrameAnalysis {
        let factor = max(1, Float(max(frame.width, frame.height)) / Float(longEdge))
        let width = max(1, Int((Float(frame.width) / factor).rounded()))
        let height = max(1, Int((Float(frame.height) / factor).rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let rowBytes = width * 16
        guard let small = device.makeTexture(descriptor: descriptor),
              let readback = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer()
        else {
            throw EngineError.gpuUnavailable
        }
        commands.label = "Stack analysis"
        MPSImageLanczosScale(device: device).encode(
            commandBuffer: commands,
            sourceTexture: frame,
            destinationTexture: small,
        )
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.copy(
            from: small, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }
        let floats = readback.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let rgb = (0 ..< width * height).map { index in
            let value = floats[index]
            return simd_max(SIMD3(value.x, value.y, value.z), .zero)
        }
        // Full-resolution pixels per analysis pixel, measured on the width actually used.
        return FrameAnalysis(width: width, height: height, rgb: rgb, factor: Float(frame.width) / Float(width))
    }

    /// Encodes `frame` resampled into the reference's geometry: `transform` maps reference pixels
    /// to the frame's, `gain` matches its brightness. `output` alpha marks covered pixels.
    func encodeWarp(
        _ frame: any MTLTexture,
        transform: Similarity,
        gain: SIMD3<Float>,
        into output: any MTLTexture,
        commands: any MTLCommandBuffer,
    ) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        encoder.label = "Stack warp"
        var params = StackWarpParams(
            transform: SIMD4(transform.a, transform.b, transform.tx, transform.ty),
            gain: SIMD4(gain, 1),
            size: SIMD4(Int32(output.width), Int32(output.height), Int32(frame.width), Int32(frame.height)),
        )
        encoder.setComputePipelineState(kernels.stackWarp)
        encoder.setTexture(frame, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<StackWarpParams>.stride, index: 0)
        encoder.dispatchGrid(width: output.width, height: output.height, pipeline: kernels.stackWarp)
        encoder.endEncoding()
    }
}
