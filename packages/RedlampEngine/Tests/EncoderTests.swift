import Metal
import Testing
@testable import RedlampEngine

/// An encoder is ended however the work encoded into it exits, so a buffer or texture that can't
/// be allocated partway through fails the render instead of aborting under Metal's validation
/// layer (DATA-16).
struct EncoderTests {
    private struct Failure: Error {}

    private static let device = MTLCreateSystemDefaultDevice()

    private func commandBuffer() throws -> any MTLCommandBuffer {
        let queue = try #require(Self.device?.makeCommandQueue())
        return try #require(queue.makeCommandBuffer())
    }

    @Test(.enabled(if: device != nil))
    func `a compute encoder is ended when the work in it throws`() throws {
        let commands = try commandBuffer()
        #expect(throws: Failure.self) {
            try commands.withComputeEncoder { _ in throw Failure() }
        }
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.status == .completed)
    }

    @Test(.enabled(if: device != nil))
    func `a compute encoder is ended when the work in it returns`() throws {
        let commands = try commandBuffer()
        let value = try commands.withComputeEncoder { _ in 7 }
        let blit = try #require(commands.makeBlitCommandEncoder(), "another encoder opens after it")
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        #expect(value == 7)
        #expect(commands.status == .completed)
    }
}
