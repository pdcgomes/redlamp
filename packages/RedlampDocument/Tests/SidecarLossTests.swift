import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

/// What the round-trip check counts as lost when this build would save a sidecar back.
struct SidecarLossTests {
    @Test func `an array element this build drops is a loss`() throws {
        let data = try JSONEncoder.sidecar.encode(SidecarSamples.everything)
        var dropped = SidecarSamples.everything
        dropped.recipe.spots.removeLast()
        #expect(SidecarStore.wouldLose(data, decoding: dropped))
        #expect(!SidecarStore.wouldLose(data, decoding: SidecarSamples.everything))
    }
}
