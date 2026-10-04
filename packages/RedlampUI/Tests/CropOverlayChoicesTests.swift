import Foundation
import Testing
@testable import RedlampUI

/// Choose Overlays to Cycle and Choose Aspect Ratios: the cycle through the chosen overlays, the
/// chosen ratios' outlines, and the choices kept between launches.
struct CropOverlayChoicesTests {
    @Test func `every overlay and ratio is chosen at first, and O goes through them all in order`() {
        let choices = CropOverlayChoices()
        #expect(choices.overlays == Set(CropOverlay.allCases))
        #expect(choices.ratios == Set(CropOverlay.AspectRatio.allCases))
        let all = CropOverlay.allCases
        for (overlay, next) in zip(all, all.dropFirst() + [all[0]]) {
            #expect(choices.overlay(after: overlay) == next)
        }
    }

    @Test func `the cycle keeps Lightroom's order, skips the overlays left out and wraps`() {
        var choices = CropOverlayChoices()
        for overlay in [CropOverlay.grid, .thirds, .goldenRatio] {
            choices[overlay] = false
        }
        var shown = CropOverlay.diagonal
        var visited = [shown]
        for _ in 0 ..< 4 {
            shown = choices.overlay(after: shown)
            visited.append(shown)
        }
        #expect(visited == [.diagonal, .goldenTriangle, .goldenSpiral, .aspectRatios, .diagonal])
        #expect(choices.overlay(after: .grid) == .diagonal, "from one left out, the next chosen")
        #expect(choices.overlay(after: .goldenRatio) == .goldenSpiral)
    }

    @Test func `the last overlay and the last ratio chosen stay chosen`() {
        var choices = CropOverlayChoices()
        for overlay in CropOverlay.allCases {
            choices[overlay] = false
        }
        #expect(choices.overlays == [.aspectRatios])
        #expect(choices.overlay(after: .aspectRatios) == .aspectRatios, "O stays on the only one")
        #expect(choices.overlay(after: .thirds) == .aspectRatios)
        choices[.thirds] = true
        choices[.aspectRatios] = false
        #expect(choices.overlays == [.thirds])

        for ratio in CropOverlay.AspectRatio.allCases {
            choices[ratio] = false
        }
        #expect(choices.ratios == [.sixteenByTen])
    }

    @Test func `the Aspect Ratios overlay outlines only the chosen ratios, in Lightroom's order`() {
        var choices = CropOverlayChoices()
        let kept: Set<CropOverlay.AspectRatio> = [.sixteenByNine, .square, .fourByFive]
        for ratio in CropOverlay.AspectRatio.allCases where !kept.contains(ratio) {
            choices[ratio] = false
        }
        for rect in [CGRect(x: 10, y: 20, width: 600, height: 400), CGRect(x: 0, y: 0, width: 400, height: 600)] {
            let all = CropOverlay.aspectOutlines(in: rect)
            #expect(CropOverlay.aspectOutlines(in: rect, ratios: choices.ratios) == [all[0], all[1], all[6]])
        }
        #expect(CropOverlay.aspectOutlines(in: CGRect(x: 0, y: 0, width: 600, height: 400), ratios: []).isEmpty)
    }

    @Test func `the choices are kept by name, leaving out names this version doesn't know`() throws {
        var choices = CropOverlayChoices()
        choices[.grid] = false
        choices[.sixteenByTen] = false
        let stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(choices)) as? [String: [String]]
        #expect(stored?["overlays"] == [
            "thirds", "diagonal", "goldenTriangle", "goldenRatio", "goldenSpiral", "aspectRatios",
        ])
        #expect(stored?["ratios"] == ["1x1", "4x5", "8.5x11", "5x7", "2x3", "4x3", "16x9"])

        let later = Data(#"{"overlays": ["goldenHexagon", "thirds"], "ratios": ["3x1", "16x9"]}"#.utf8)
        let read = try JSONDecoder().decode(CropOverlayChoices.self, from: later)
        #expect(read.overlays == [.thirds] && read.ratios == [.sixteenByNine])
        for nothingKnown in [#"{"overlays": ["goldenHexagon"], "ratios": []}"#, "{}"] {
            let read = try JSONDecoder().decode(CropOverlayChoices.self, from: Data(nothingKnown.utf8))
            #expect(read == CropOverlayChoices(), "\(nothingKnown) chooses every one")
        }
    }

    @MainActor
    @Test func `the choices are remembered between launches`() throws {
        let suite = "CropOverlayChoicesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CropOverlayChoices.Store(defaults: defaults).choices == CropOverlayChoices(), "nothing saved yet")

        let store = CropOverlayChoices.Store(defaults: defaults)
        store.choices[.grid] = false
        store.choices[.goldenSpiral] = false
        store.choices[.letter] = false
        let relaunched = CropOverlayChoices.Store(defaults: defaults)
        #expect(relaunched.choices == store.choices)
        #expect(relaunched.choices.overlays == [.thirds, .diagonal, .goldenTriangle, .goldenRatio, .aspectRatios])
        #expect(relaunched.choices.ratios == Set(CropOverlay.AspectRatio.allCases).subtracting([.letter]))

        defaults.set(Data("not the choices".utf8), forKey: "app.redlamp.cropOverlays")
        #expect(CropOverlayChoices.Store(defaults: defaults).choices == CropOverlayChoices(), "unreadable")
    }
}
