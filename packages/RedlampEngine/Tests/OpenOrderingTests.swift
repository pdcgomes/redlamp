import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampEngine

/// Which photo the engine ends up on when opens overlap (CONC-01).
@MainActor
struct OpenOrderingTests {
    private func photos() throws -> (URL, URL) {
        let fixtures = EngineSmokeTests.fixtures
        try #require(fixtures.count >= 2)
        return (fixtures[0], fixtures[1])
    }

    /// Going to an undecoded photo and straight back: the editor cancels the first open before
    /// its task has run, and shows the photo it came back to with `openIfReady`.
    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `an open cancelled before it starts doesn't replace the photo opened since`() async throws {
        let engine = try RedlampEngine()
        let (shown, skipped) = try photos()
        _ = try await engine.open(shown)
        let open = Task { @MainActor in try await engine.open(skipped) }
        open.cancel()
        #expect(engine.openIfReady(shown) != nil)

        await #expect(throws: CancellationError.self) { try await open.value }
        #expect(engine.currentSession()?.info.url == shown)
        var request = StillRequest(recipe: EditRecipe(), purpose: .export)
        request.source = shown
        request.maxLongEdge = 256
        _ = try await engine.renderStill(request)
        #expect(engine.openIfReady(skipped) != nil, "the photo skipped was still decoded, for a later visit")
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `opens one after another each change the photo`() async throws {
        let engine = try RedlampEngine()
        let (first, second) = try photos()
        _ = try await engine.open(first)
        _ = try await engine.open(second)
        #expect(engine.currentSession()?.info.url == second)
        _ = try await engine.open(first)
        #expect(engine.currentSession()?.info.url == first)
    }
}
