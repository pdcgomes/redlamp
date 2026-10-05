import Foundation
import RedlampEngineAPI
import Testing

struct EngineErrorTests {
    @Test func `a format that isn't supported yet says so`() {
        let error = EngineError.notSupportedYet("JPEG XL-compressed mosaic DNGs", tracker: "CAM-10")
        #expect(error.localizedDescription == "JPEG XL-compressed mosaic DNGs aren't supported yet.")
        #expect(error.notSupportedYetTracker == "CAM-10")
        #expect(EngineError.decodeFailed("truncated").notSupportedYetTracker == nil)
    }

    /// Errors cross from the decode service to the app as JSON.
    @Test func `a format that isn't supported yet keeps its tracker row through JSON`() throws {
        let error = EngineError.notSupportedYet("Nikon's High Efficiency raw files (HE and HE*)", tracker: "CAM-12")
        let decoded = try JSONDecoder().decode(EngineError.self, from: JSONEncoder().encode(error))
        #expect(decoded.notSupportedYetTracker == "CAM-12")
        #expect(decoded.localizedDescription == error.localizedDescription)
    }
}
