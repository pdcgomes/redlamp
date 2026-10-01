import Foundation
import RedlampEngineAPI
import Testing

struct MaskShapeTests {
    private func roundTrip(_ shape: MaskShape) throws -> MaskShape {
        try JSONDecoder().decode(MaskShape.self, from: JSONEncoder().encode(shape))
    }

    @Test func `reads gradients in the synthesized format`() throws {
        let json = #"{"linear":{"_0":{"start":{"x":0.5,"y":0},"end":{"x":0.5,"y":0.4}}}}"#
        let shape = try JSONDecoder().decode(MaskShape.self, from: Data(json.utf8))
        #expect(shape == .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.4))))
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shape)) as? [String: Any]
        #expect((written?["linear"] as? [String: Any])?["_0"] != nil)
    }

    @Test func `round trips every new shape`() throws {
        let stroke = BrushStroke(
            points: [ImagePoint(x: 0.1, y: 0.2), ImagePoint(x: 0.3, y: 0.25)],
            pressures: [0.4, 0.9], size: 0.05, feather: 30, flow: 60, density: 80, erase: true, autoMask: true,
        )
        let bitmap = MaskBitmap(sha256: "ab12", width: 1536, height: 1024, png: Data([1, 2, 3]))
        let shapes: [MaskShape] = [
            .brush(BrushMask(strokes: [stroke])),
            .luminanceRange(LuminanceRangeMask(lower: 20, upper: 60, lowerFeather: 5, upperFeather: 10)),
            .colorRange(ColorRangeMask(
                samples: [ColorSample(center: ImagePoint(x: 0.4, y: 0.5), radius: 0.02)],
                refine: 70,
            )),
            .ai(AIMask(
                kind: .subject, provider: "apple.vision.foreground", revision: 1, osBuild: "25G100",
                analysisHash: "ff00", center: ImagePoint(x: 0.5, y: 0.6), bitmap: bitmap,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            )),
        ]
        let depth = AIMask(
            kind: .depthRange, provider: "apple.embedded.depth", revision: 1, analysisHash: "ff00",
            center: ImagePoint(x: 0.5, y: 0.5), bitmap: bitmap, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        )
        for shape in shapes + [.depthRange(DepthRangeMask(depth: depth, lower: 30, upper: 70))] {
            #expect(try roundTrip(shape) == shape)
        }
    }

    @Test func `bitmap bytes stay out of the JSON`() throws {
        let bitmap = MaskBitmap(sha256: "ab12", width: 8, height: 4, png: Data(repeating: 7, count: 100))
        let json = try #require(String(data: JSONEncoder().encode(bitmap), encoding: .utf8))
        #expect(!json.contains("png"))
        #expect(try JSONDecoder().decode(MaskBitmap.self, from: Data(json.utf8)) == bitmap)
    }

    @Test func `keeps a newer component unchanged`() throws {
        let json = #"{"hologram":{"_0":{"near":0.2,"far":0.6}}}"#
        let shape = try JSONDecoder().decode(MaskShape.self, from: Data(json.utf8))
        guard case let .unknown(unknown) = shape else {
            Issue.record("expected an unknown shape")
            return
        }
        #expect(unknown.key == "hologram")
        #expect(shape.kind == nil)
        #expect(try roundTrip(shape) == shape)
    }

    @Test func `a mask with a newer component still loads`() throws {
        let json = #"""
        {"id":"4D7C5D0E-2B8A-4D5C-9E31-6F1D2B3A4C5D","name":"Mask 1","components":[
          {"id":"0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","operation":"add","inverted":false,
           "shape":{"hologram":{"_0":{"x":1}}}}]}
        """#
        let mask = try JSONDecoder().decode(MaskLayer.self, from: Data(json.utf8))
        #expect(mask.components.count == 1)
        #expect(mask.components[0].shape.kind == nil)
    }

    @Test func `normalizes a luminance range`() {
        let range = LuminanceRangeMask(lower: 80, upper: 40, lowerFeather: 120, upperFeather: 50).normalized
        #expect(range.lower == 80)
        #expect(range.upper == 80)
        #expect(range.lowerFeather == 80)
        #expect(range.upperFeather == 20)
    }

    @Test func `limits color samples to five`() {
        let samples = (0 ..< 8).map { ColorSample(center: ImagePoint(x: Double($0) / 8, y: 0.5)) }
        #expect(ColorRangeMask(samples: samples).samples.count == ColorRangeMask.maximumSamples)
    }
}
