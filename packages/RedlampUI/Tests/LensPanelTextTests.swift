import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// What the Lens panel says about a photo's lens correction (LNS-11): a profile's lens by name,
/// corrections the file carries as before, and lens profiles that couldn't be read.
struct LensPanelTextTests {
    static func correction(_ source: LensCorrection.Source, name: String? = nil) -> LensCorrection {
        let distortion: [SIMD3<Double>] = [SIMD3(repeating: 1), SIMD3(repeating: 1.02)]
        return LensCorrection(
            source: source, center: SIMD2(0.5, 0.5), radii: [0, 1], distortion: distortion, vignetting: [1, 1.3],
            profileName: name,
        )
    }

    @Test func `a profile's correction names its lens`() throws {
        let lens = Self.correction(.profile, name: "Nikon NIKKOR Z 24-70mm f/4 S")
        #expect(LensPanelText.help(lens, applies: true) == """
        Distortion and vignetting corrections from the lens profile for Nikon NIKKOR Z 24-70mm f/4 S in your Lens \
        Profiles folder
        """)
        let note = try #require(LensPanelText.profile(lens))
        #expect(note.text == "Profile: Nikon NIKKOR Z 24-70mm f/4 S")
        #expect(note.help == "The lens profile in your Lens Profiles folder for Nikon NIKKOR Z 24-70mm f/4 S")
    }

    @Test func `a correction the file carries reads as before, with no profile line`() {
        let lens = Self.correction(.dng)
        let help = (LensPanelText.help(lens, applies: true), LensPanelText.help(lens, applies: false))
        #expect(help.0 == "Distortion and vignetting corrections from the DNG file itself")
        #expect(help.1 == "Edits made before process 5 render without this lens correction")
        #expect(LensPanelText.profile(lens) == nil)
    }

    @Test func `without a correction the panel says so`() {
        #expect(LensPanelText.help(nil, applies: false) == "This photo carries no lens correction")
        #expect(LensPanelText.profile(nil) == nil)
    }

    @Test func `profiles that couldn't be read are counted, with each file and its reasons in the help`() throws {
        #expect(LensPanelText.issues([:]) == nil)
        let folder = URL(fileURLWithPath: "/Lens Profiles")
        let one = try #require(LensPanelText.issues([folder.appending(path: "b.lcp"): ["not a lens profile"]]))
        #expect(one.text == "1 lens profile couldn't be read")
        let two = try #require(LensPanelText.issues([
            folder.appending(path: "b.lcp"): ["not a lens profile"],
            folder.appending(path: "Nikon/a.lcp"): ["fisheye at 8 mm", "fisheye at 15 mm"],
        ]))
        #expect(two.text == "2 lens profiles couldn't be read")
        #expect(two.help == """
        In your Lens Profiles folder:
        a.lcp: fisheye at 8 mm; fisheye at 15 mm
        b.lcp: not a lens profile
        """)
    }
}
