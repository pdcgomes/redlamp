import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd
import Testing
@testable import RedlampEngine

/// Saturation's gamut-relative boost (TON-07) on colours brighter than the output can show at their
/// saturation (#517): a yellow and red banner the tone curve leaves past the output's white took
/// neither Saturation nor the Color Mixer's saturation, while the same colours a stop darker did.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct SaturationRenderTests: PointColorRendering {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    enum Boost: String, CaseIterable, Sendable {
        case saturation = "Saturation +100"
        case mixer = "the Color Mixer's red and yellow Saturation +100"

        func apply(to recipe: inout EditRecipe) {
            switch self {
            case .saturation:
                recipe[.saturation] = 100
            case .mixer:
                recipe[ColorBand.red.saturationParameter] = 100
                recipe[ColorBand.yellow.saturationParameter] = 100
            }
        }
    }

    private static let red = SIMD3<Float>(0.9, 0.2, 0.18)

    /// The red on the left, a yellow on the right: at Exposure 0 the tone curve leaves each brighter
    /// than Display P3's white at its saturation, and a stop down both fit inside it.
    private func banner() throws -> ImageSession {
        try makeSession(width: 64, height: 16) { x, _ in x < 32 ? Self.red : SIMD3(0.95, 0.75, 0.25) }
    }

    private let colors = [(name: "red", pixel: 8 * 64 + 16), (name: "yellow", pixel: 8 * 64 + 48)]

    /// The OKLab chroma `boost` adds to each of the banner's colours at `exposure`.
    private func gains(_ boost: Boost, exposure: Double, process: Int, session: ImageSession) throws -> [Double] {
        var plain = EditRecipe()
        plain.processVersion = process
        plain[.exposure] = exposure
        var boosted = plain
        boost.apply(to: &boosted)
        let before = try render(plain, session: session)
        let after = try render(boosted, session: session)
        return colors.map { lch(after[$0.pixel]).y - lch(before[$0.pixel]).y }
    }

    @Test(arguments: Boost.allCases)
    func `a bright saturated colour takes a boost as the same colour a stop darker does`(boost: Boost) throws {
        let session = try banner()
        let bright = try gains(boost, exposure: 0, process: EditRecipe.currentProcessVersion, session: session)
        let darker = try gains(boost, exposure: -1, process: EditRecipe.currentProcessVersion, session: session)
        for (index, color) in colors.enumerated() {
            print("\(boost.rawValue), \(color.name): chroma +\(bright[index]) at Exposure 0, +\(darker[index]) at -1")
            #expect(
                bright[index] > 0.4 * darker[index],
                "\(boost.rawValue), \(color.name): +\(bright[index]) at Exposure 0, +\(darker[index]) at -1",
            )
        }
    }

    @Test func `edits before process 21 keep their boost on bright colours`() throws {
        let gain = try gains(.saturation, exposure: 0, process: 20, session: banner())
        #expect(abs(gain[0]) < 0.002, "the red, past white, as it rendered: +\(gain[0])")
    }

    /// Colours a boost takes past white are brought back by the final gamut map, which keeps their
    /// darkest channel, so a red from dark to bright stays in order of lightness at Saturation +100
    /// instead of flattening where it passes white.
    @Test func `a boosted ramp from dark to bright keeps its gradation`() throws {
        let steps = 24
        let session = try makeSession(width: steps * 8, height: 8) { x, _ in
            Self.red * (0.05 + 0.95 * Float(x / 8) / Float(steps - 1))
        }
        var recipe = EditRecipe()
        recipe[.saturation] = 100
        let pixels = try render(recipe, session: session)
        let ramp = (0 ..< steps).map { lch(pixels[4 * steps * 8 + $0 * 8 + 4]) }
        for (step, (darker, lighter)) in zip(ramp, ramp.dropFirst()).enumerated() {
            #expect(lighter.x > darker.x + 0.002, "step \(step + 1): L \(darker.x) to \(lighter.x)")
        }
    }
}
