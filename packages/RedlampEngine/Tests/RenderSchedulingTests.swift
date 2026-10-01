import Foundation
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampEngine

/// The render scheduler: the canvas never waits for a whole export, previews run ahead of
/// exports, and a cancelled still stops at its next tile.
struct RenderSchedulingTests {
    static let sample = EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" }
        ?? EngineSmokeTests.fixtures.first

    /// Small tiles and spatial filters, so a full-resolution export takes many yields.
    static var heavy: EditRecipe {
        var recipe = EditRecipe()
        recipe[.noiseLuminance] = 50
        recipe[.texture] = 30
        recipe[.clarity] = 30
        return recipe
    }

    private func openEngine() async throws -> RedlampEngine {
        let engine = try RedlampEngine(stillTile: 384)
        _ = try await engine.open(#require(Self.sample))
        return engine
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `the canvas is served while an export renders`() async throws {
        let engine = try await openEngine()
        var iterator = engine.frames().makeAsyncIterator()
        let started = ContinuousClock.now
        let export = Task {
            _ = try await engine.renderStill(StillRequest(recipe: Self.heavy, purpose: .export))
            return ContinuousClock.now
        }
        try await Task.sleep(for: .milliseconds(30))
        var slowest = Duration.zero
        for generation in UInt64(1) ... 5 {
            let sent = ContinuousClock.now
            engine.render(RenderRequest(
                recipe: EditRecipe(), targetSize: PixelSize(width: 800, height: 800), generation: generation,
            ))
            var frame = await iterator.next()
            while let current = frame, current.generation != generation {
                frame = await iterator.next()
            }
            slowest = max(slowest, .now - sent)
        }
        let framesDone = ContinuousClock.now
        let exported = try await export.value
        #expect(framesDone < exported, "the frames waited for the export (\(exported - started))")
        #expect(slowest < (exported - started) / 2, "slowest frame \(slowest) of an export of \(exported - started)")
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `a cancelled export stops at its next tile`() async throws {
        let engine = try await openEngine()
        let export = Task { try await engine.renderStill(StillRequest(recipe: Self.heavy, purpose: .export)) }
        try await Task.sleep(for: .milliseconds(50))
        let cancelled = ContinuousClock.now
        export.cancel()
        await #expect(throws: CancellationError.self) { _ = try await export.value }
        #expect(.now - cancelled < .seconds(1))
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `a cancelled export waiting its turn ends at once`() async throws {
        let engine = try await openEngine()
        let first = Task { try await engine.renderStill(StillRequest(recipe: Self.heavy, purpose: .export)) }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { try await engine.renderStill(StillRequest(recipe: Self.heavy, purpose: .export)) }
        try await Task.sleep(for: .milliseconds(50))
        second.cancel()
        await #expect(throws: CancellationError.self) { _ = try await second.value }
        let secondDone = ContinuousClock.now
        _ = try await first.value
        #expect(secondDone < .now, "the cancelled export waited for the one ahead of it")
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `previews run ahead of an export`() async throws {
        let engine = try await openEngine()
        let order = Mutex<[String]>([])
        let export = Task {
            _ = try await engine.renderStill(StillRequest(recipe: Self.heavy, purpose: .export))
            order.withLock { $0.append("export") }
        }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await engine.renderStill(StillRequest(recipe: EditRecipe(), maxLongEdge: 256))
        order.withLock { $0.append("preview") }
        try await export.value
        #expect(order.withLock { $0 } == ["preview", "export"])
    }

    @Test func `exports rest when the machine is hot`() {
        let work = Duration.milliseconds(40)
        #expect(RedlampEngine.cooldown(after: work, thermalState: .nominal) == .zero)
        #expect(RedlampEngine.cooldown(after: work, thermalState: .fair) == .zero)
        #expect(RedlampEngine.cooldown(after: work, thermalState: .serious) == work)
        #expect(RedlampEngine.cooldown(after: work, thermalState: .critical) == work * 3)
    }
}
