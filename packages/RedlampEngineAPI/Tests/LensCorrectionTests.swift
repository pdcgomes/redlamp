import Foundation
import Testing
@testable import RedlampEngineAPI

/// The name a lens profile gives a correction (LNS-11): a label that codes with it, and that
/// photos opened before it existed, and corrections the file carries, do without.
struct LensCorrectionTests {
    static let named = LensCorrection(
        source: .profile, center: SIMD2(0.5, 0.5), radii: [0, 0.5, 1],
        distortion: [SIMD3(repeating: 1), SIMD3(repeating: 1.01), SIMD3(repeating: 1.03)],
        vignetting: [1, 1.1, 1.4], profileName: "Nikon NIKKOR Z 24-70mm f/4 S",
    )

    @Test func `a correction coded before it had a name decodes without one`() throws {
        let old = Data(#"""
        {"source":"sony","center":[0.5,0.5],"radii":[0,1],"distortion":[[1,1,1],[1.01,1.01,1.01]],
         "vignetting":[1,1.2]}
        """#.utf8)
        let lens = try JSONDecoder().decode(LensCorrection.self, from: old)
        #expect(lens.profileName == nil && lens.source == .sony && lens.vignetting == [1, 1.2])
    }

    @Test func `the name codes with the correction, and a correction without one codes as before`() throws {
        #expect(try JSONDecoder().decode(LensCorrection.self, from: JSONEncoder().encode(Self.named)) == Self.named)
        var unnamed = Self.named
        unnamed.profileName = nil
        #expect(try !String(decoding: JSONEncoder().encode(unnamed), as: UTF8.self).contains("profileName"))
    }

    @Test func `the name doesn't change the geometry`() {
        var unnamed = Self.named
        unnamed.profileName = nil
        let size = PixelSize(width: 6000, height: 4000)
        let named = GeometryMap(recipe: EditRecipe(), imageSize: size, lens: Self.named).lensProfile
        let plain = GeometryMap(recipe: EditRecipe(), imageSize: size, lens: unnamed).lensProfile
        #expect(named != nil)
        #expect(named?.distortion == plain?.distortion && named?.vignetting == plain?.vignetting)
        #expect(named?.center == plain?.center && named?.radii == plain?.radii)
    }
}
