import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampEngine

/// A Sky mask's edges are solved on the photo it was computed for, though another photo opens
/// meanwhile.
@Suite(.enabled(if: EngineSmokeTests.canRender && EngineSmokeTests.fixtures.count >= 2))
struct SkySessionTests {
    @Test func `the sky refinement keeps to the photo it started on`() async throws {
        setenv("REDLAMP_SKY_METHOD", "classical", 1)
        let engine = try RedlampEngine()
        var found: (url: URL, session: ImageSession, analysis: (image: CGImage, hash: String), sky: AIMask)?
        for url in EngineSmokeTests.fixtures {
            _ = try await engine.open(url)
            _ = engine.openIfReady(url)
            let session = try #require(engine.currentSession())
            let analysis = try await engine.analysisImage(for: session)
            if let sky = try await engine.modelSky(analysis, session: session) {
                found = (url, session, analysis, sky)
                break
            }
        }
        let photo = try #require(found, "no fixture has a sky the classical estimate finds")
        let other = try #require(EngineSmokeTests.fixtures.first { $0 != photo.url })
        _ = try await engine.open(other)
        _ = engine.openIfReady(other)
        #expect(engine.currentSession() !== photo.session)

        let sky = try await engine.modelSky(photo.analysis, session: photo.session)
        #expect(sky?.bitmap.sha256 == photo.sky.bitmap.sha256)
    }
}
