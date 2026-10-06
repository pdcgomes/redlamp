import Metal
import RedlampEngineAPI

extension MTLCommandBuffer {
    /// Runs `body` with a new compute encoder and ends it however `body` exits: an encoder
    /// released without `endEncoding()` aborts under Metal's validation layer, so a buffer or
    /// texture that fails to allocate partway through would crash a Debug build.
    func withComputeEncoder<T>(_ body: (any MTLComputeCommandEncoder) throws -> T) throws -> T {
        guard let encoder = makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        defer { encoder.endEncoding() }
        return try body(encoder)
    }
}
