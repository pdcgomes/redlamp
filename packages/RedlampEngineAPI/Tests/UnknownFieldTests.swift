import Foundation
import RedlampEngineAPI
import Testing

/// Fields a newer Redlamp adds below the top level of an edit are written back unchanged, through
/// a decode, an edit and an encode.
struct UnknownFieldTests {
    private func roundTrip<T: Codable>(
        _: T.Type,
        _ json: String,
        _ edit: (inout T) -> Void,
    ) throws -> [String: JSONValue] {
        try roundTrip(T.self, Data(json.utf8), edit)
    }

    private func roundTrip<T: Codable>(
        _: T.Type,
        _ json: Data,
        _ edit: (inout T) -> Void,
    ) throws -> [String: JSONValue] {
        var decoded = try JSONDecoder().decode(T.self, from: json)
        edit(&decoded)
        guard case let .object(root) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
        else {
            Issue.record("did not encode as an object")
            return [:]
        }
        return root
    }

    private static let id = "00000000-0000-0000-0000-000000000001"

    @Test func `a mask layer keeps its unknown fields and adjustments`() throws {
        let json = #"{"id":"\#(Self.id)","name":"Sky","components":[],"amount":100,"#
            + #""adjustments":{"local.exposure":0.5,"local.future":40},"blendMode":"multiply"}"#
        let root = try roundTrip(MaskLayer.self, json) { $0.name = "Sky 2" }
        #expect(root["blendMode"] == .string("multiply"))
        guard case let .object(adjustments) = root["adjustments"] else {
            Issue.record("no adjustments")
            return
        }
        #expect(adjustments == ["local.exposure": .number(0.5), "local.future": .number(40)])
    }

    @Test func `a mask component keeps its unknown fields`() throws {
        let json = #"{"id":"\#(Self.id)","operation":"add","inverted":false,"opacity":50,"#
            + #""shape":{"linear":{"_0":{"start":{"x":0,"y":0},"end":{"x":1,"y":1}}}}}"#
        let root = try roundTrip(MaskComponent.self, json) { $0.inverted = true }
        #expect(root["opacity"] == .number(50))
        #expect(root["inverted"] == .bool(true))
    }

    @Test func `an AI mask keeps its unknown fields`() throws {
        let json = #"{"kind":"subject","provider":"test","revision":1,"prompts":[],"analysisHash":"0","#
            + #""center":{"x":0.5,"y":0.5},"bitmap":{"sha256":"s","width":4,"height":2},"createdAt":1000,"edgeSoftness":3}"#
        let root = try roundTrip(AIMask.self, json) { $0.revision = 2 }
        #expect(root["edgeSoftness"] == .number(3))
        #expect(root["revision"] == .number(2))
    }

    @Test func `an applied recipe keeps its unknown fields`() throws {
        let json = #"{"id":"local/test","version":1,"name":"Test","amount":80,"author":"Someone"}"#
        let root = try roundTrip(AppliedRecipe.self, json) { $0.amount = 60 }
        #expect(root["author"] == .string("Someone"))
    }

    @Test func `a spot keeps its unknown fields`() throws {
        let json = #"{"id":"\#(Self.id)","mode":"heal","center":{"x":0.3,"y":0.3},"source":{"x":0.6,"y":0.3},"#
            + #""radius":0.02,"feather":50,"opacity":100,"sourceRotation":20}"#
        let root = try roundTrip(RetouchSpot.self, json) { $0.opacity = 80 }
        #expect(root["sourceRotation"] == .number(20))
    }

    @Test func `types without unknown fields are written as before`() throws {
        let layer = MaskLayer(name: "Sky", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.1,
        )))])
        let root = try roundTrip(MaskLayer.self, JSONEncoder().encode(layer)) { _ in }
        #expect(Set(root.keys) == ["id", "name", "isVisible", "components", "amount", "adjustments"])
    }
}
