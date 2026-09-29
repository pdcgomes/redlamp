import Foundation
import Metal

/// The compiled Redlamp compute kernels.
///
/// Pipeline states are created once at startup; encoding a frame never compiles.
public final class KernelLibrary: @unchecked Sendable {
    public let device: any MTLDevice
    public let cfaNormalize: any MTLComputePipelineState
    public let rgbNormalize: any MTLComputePipelineState
    public let demosaicBayer: any MTLComputePipelineState
    public let demosaicGeneric: any MTLComputePipelineState
    public let develop: any MTLComputePipelineState
    public let histogram: any MTLComputePipelineState

    public init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: KernelLibrary.self))

        func pipeline(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw KernelError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }

        cfaNormalize = try pipeline("rl_cfa_normalize")
        rgbNormalize = try pipeline("rl_rgb_normalize")
        demosaicBayer = try pipeline("rl_demosaic_bayer")
        demosaicGeneric = try pipeline("rl_demosaic_generic")
        develop = try pipeline("rl_develop")
        histogram = try pipeline("rl_histogram")
    }
}

public enum KernelError: Error, CustomStringConvertible {
    case missingFunction(String)

    public var description: String {
        switch self {
        case let .missingFunction(name): "Metal function \(name) is missing from the kernel library"
        }
    }
}

public extension MTLComputeCommandEncoder {
    /// Dispatches one thread per pixel of a `width` x `height` grid.
    func dispatchGrid(width: Int, height: Int, pipeline: any MTLComputePipelineState) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: min(h, 16), depth: 1),
        )
    }
}
