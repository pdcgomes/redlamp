import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// ⌘F adjustment search (UX-03): the palette's slider rows, ranked as its sliders scope ranks them.
@MainActor
struct AdjustmentSearchTests {
    private func results(_ query: String) -> [ParameterID] {
        PaletteCatalog.rank(PaletteCatalog.sliderItems, query: query, words: SearchMatcher.words(query))
            .compactMap { item in
                if case let .slider(parameter) = item.kind {
                    return parameter
                }
                return nil
            }
    }

    private func first(_ query: String) -> ParameterID? {
        results(query).first
    }

    @Test func `finds sliders by name, by prefix and by the words people use`() throws {
        #expect(first("dehaze") == .dehaze)
        #expect(first("haze") == .dehaze)
        #expect(first("shad") == .shadows)
        #expect(first("fill light") == .shadows)
        #expect(first("kelvin") == .temperature)
        #expect(Set(results("white balance").prefix(2)) == [.temperature, .tint])
        #expect(first("sharpen") == .sharpenAmount)
        #expect(first("nr") == .noiseLuminance)
        #expect(first("colour noise") == .noiseColor)
        let toning = try #require(first("split toning"))
        #expect(PanelID.colorGrading.parameters.contains(toning))
    }

    @Test func `several words narrow the results`() {
        #expect(first("orange saturation") == ColorBand.orange.saturationParameter)
    }

    @Test func `only live sliders are offered, and nonsense finds nothing`() {
        #expect(first("defringe") == .defringePurpleAmount)
        #expect(results("fisheye").isEmpty)
        #expect(Set(results("distortion").prefix(2)) == [.lensProfileDistortion, .lensDistortion])
        #expect(results("zzzz").isEmpty)
        #expect(SearchMatcher.words("  ").isEmpty, "a blank query browses the panels instead")
        #expect(PaletteCatalog.sliderItems.allSatisfy { item in
            if case let .slider(parameter) = item.kind {
                return parameter.spec.availability.isLive
            }
            return false
        })
    }
}
