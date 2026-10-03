import Foundation
import Testing
@testable import RedlampEngine

/// The base edge-aware Highlights and Shadows read: smooth over texture, sharp across edges, and
/// independent of exposure.
struct ToneBaseTests {
    private let width = 200
    private let height = 100

    /// A dark half and a bright half, 4 stops apart, each with fine texture of ±0.15 stops.
    private func scene(offset: Float = 0) -> [Float] {
        (0 ..< width * height).map { index in
            let x = index % width
            let y = index / width
            let texture: Float = (x + y) % 2 == 0 ? 0.15 : -0.15
            return (x < width / 2 ? -3 : 1) + texture + offset
        }
    }

    private func base(_ ev: [Float]) -> [Float] {
        let c = ToneBase.coefficients(ev, width: width, height: height)
        return ev.indices.map { c.a[$0] * ev[$0] + c.b[$0] }
    }

    @Test func `texture stays in the detail and the edge stays in the base`() {
        let ev = scene()
        let base = base(ev)
        let row = 50 * width
        // Away from the edge the base is the region's level, the texture gone from it.
        #expect(abs(base[row + 20] - -3) < 0.05, "dark region: \(base[row + 20])")
        #expect(abs(base[row + 180] - 1) < 0.05, "bright region: \(base[row + 180])")
        // Two pixels either side of the edge still sit at their own side's level.
        #expect(base[row + 97] < -2.5, "dark side of the edge: \(base[row + 97])")
        #expect(base[row + 102] > 0.5, "bright side of the edge: \(base[row + 102])")
        // The detail is the texture.
        let detail = ev[row + 20] - base[row + 20]
        #expect(abs(abs(detail) - 0.15) < 0.05, "detail: \(detail)")
    }

    @Test func `the base moves with exposure and nothing else changes`() {
        let base0 = base(scene())
        let base2 = base(scene(offset: 2))
        let shifts = zip(base0, base2).map { $1 - $0 }
        #expect(shifts.allSatisfy { abs($0 - 2) < 1e-3 }, "two stops brighter, the base two stops brighter")
    }
}
