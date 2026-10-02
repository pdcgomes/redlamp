import RedlampEngineAPI
import RedlampUI
import Testing

/// ⌘F adjustment search (UX-03).
struct AdjustmentSearchTests {
    private func first(_ query: String) -> ParameterID? {
        AdjustmentSearch.results(for: query).first?.parameter
    }

    @Test func `finds sliders by name, by prefix and by the words people use`() {
        #expect(first("dehaze") == .dehaze)
        #expect(first("haze") == .dehaze)
        #expect(first("shad") == .shadows)
        #expect(first("fill light") == .shadows)
        #expect(first("kelvin") == .temperature)
        #expect(Set(AdjustmentSearch.results(for: "white balance").prefix(2).map(\.parameter)) == [.temperature, .tint])
        #expect(first("sharpen") == .sharpenAmount)
        #expect(first("nr") == .noiseLuminance)
        #expect(first("colour noise") == .noiseColor)
        #expect(AdjustmentSearch.results(for: "split toning").first?.panel == .colorGrading)
    }

    @Test func `several words narrow the results`() {
        let results = AdjustmentSearch.results(for: "orange saturation")
        #expect(results.first?.parameter == ColorBand.orange.saturationParameter)
    }

    @Test func `only live sliders are offered, and nonsense finds nothing`() {
        #expect(AdjustmentSearch.results(for: "defringe").isEmpty)
        let distortion = Set(AdjustmentSearch.results(for: "distortion").prefix(2).map(\.parameter))
        #expect(distortion == [.lensProfileDistortion, .lensDistortion])
        #expect(AdjustmentSearch.results(for: "zzzz").isEmpty)
        #expect(AdjustmentSearch.results(for: "  ").isEmpty)
    }
}
