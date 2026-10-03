import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

/// What this build writes, byte for byte, is what main (787731f) wrote for the same edit: keeping
/// unknown fields at every level changes nothing for a file that has none.
struct SidecarGoldenTests {
    /// The bytes main wrote, kept here as compact JSON and written out the way sidecars are.
    private static func golden(_ compact: String) throws -> Data {
        try JSONEncoder.sidecar.encode(JSONDecoder().decode(JSONValue.self, from: Data(compact.utf8)))
    }

    @Test func `an edit using every part of the format is written as before`() throws {
        let golden = try Self.golden(Self.everything)
        #expect(try JSONEncoder.sidecar.encode(SidecarSamples.everything) == golden)
        let reread = try JSONDecoder.sidecar.decode(Sidecar.self, from: golden)
        #expect(try JSONEncoder.sidecar.encode(reread) == golden)
    }

    @Test(arguments: zip(SidecarSamples.ordinary, ordinary))
    func `sidecars of every format are written again as before`(input: String, written: String) throws {
        let decoded = try JSONDecoder.sidecar.decode(Sidecar.self, from: Data(input.utf8))
        #expect(try JSONEncoder.sidecar.encode(decoded) == Self.golden(written))
    }

    /// `SidecarSamples.everything` as main wrote it.
    static let everything = #"{"format":"app.redlamp.edit","metadata":{"flag":"pick","label":"green","rating":4},"modified":"1970-01-0"#
        + #"1T00:33:20Z","recipe":{"appliedRecipe":{"amount":80,"id":"local/test","name":"Test","version":1},"baseLo"#
        + #"ok":{"amount":100,"id":"redlamp/base/color","name":"Redlamp Color","version":1},"crop":{"bottom":0.8,"le"#
        + #"ft":0.1,"right":0.9,"top":0.1},"masks":[{"adjustments":{"local.exposure":-0.5},"amount":100,"components""#
        + #":[{"id":"00000000-0000-0000-0000-000000000011","inverted":false,"operation":"add","shape":{"linear":{"_0"#
        + #"":{"end":{"x":0.5,"y":0.5},"start":{"x":0.5,"y":0}}}}},{"id":"00000000-0000-0000-0000-000000000012","inv"#
        + #"erted":false,"operation":"add","shape":{"radial":{"_0":{"center":{"x":0.4,"y":0.4},"feather":50,"radiusX"#
        + #"":0.2,"radiusY":0.1,"rotation":0}}}},{"id":"00000000-0000-0000-0000-000000000013","inverted":false,"oper"#
        + #"ation":"subtract","shape":{"brush":{"_0":{"strokes":[{"autoMask":false,"density":100,"erase":false,"feat"#
        + #"her":50,"flow":100,"points":[{"x":0.1,"y":0.2}],"pressures":[],"size":0.05}]}}}},{"id":"00000000-0000-00"#
        + #"00-0000-000000000014","inverted":true,"operation":"add","shape":{"luminanceRange":{"_0":{"lower":20,"low"#
        + #"erFeather":10,"upper":80,"upperFeather":0}}}},{"id":"00000000-0000-0000-0000-000000000015","inverted":fa"#
        + #"lse,"operation":"add","shape":{"colorRange":{"_0":{"refine":50,"samples":[{"center":{"x":0.2,"y":0.5},"r"#
        + #"adius":0}]}}}}],"id":"00000000-0000-0000-0000-000000000001","isVisible":true,"name":"Sky"},{"adjustments"#
        + #"":{},"amount":100,"components":[{"id":"00000000-0000-0000-0000-000000000021","inverted":false,"operation"#
        + #"":"add","shape":{"ai":{"_0":{"analysisHash":"0","bitmap":{"height":2,"sha256":"a9491f4c1bf7b0cffbadcba2d"#
        + #"b8f028e4b3f2867cb59e1f3a0bc1968f3c51242","width":4},"center":{"x":0.5,"y":0.5},"createdAt":"1970-01-01T0"#
        + #"0:16:40Z","kind":"subject","prompts":[],"provider":"test","revision":1}}}}],"id":"00000000-0000-0000-000"#
        + #"0-000000000002","isVisible":true,"name":"Subject"},{"adjustments":{},"amount":100,"components":[{"id":"0"#
        + #"0000000-0000-0000-0000-000000000031","inverted":false,"operation":"add","shape":{"depthRange":{"_0":{"de"#
        + #"pth":{"analysisHash":"0","bitmap":{"height":2,"sha256":"310d55360ccf2643bc21d3ec41f3dcbbb05279387075330e"#
        + #"396ab870dee07e4d","width":4},"center":{"x":0.5,"y":0.5},"createdAt":"1970-01-01T00:16:40Z","kind":"depth"#
        + #"Range","prompts":[],"provider":"test","revision":1},"lower":60,"lowerFeather":15,"upper":100,"upperFeath"#
        + #"er":0}}}},{"id":"00000000-0000-0000-0000-000000000032","inverted":false,"operation":"add","shape":{"mask"#
        + #"Reference":{"_0":{"maskID":"00000000-0000-0000-0000-000000000002"}}}}],"id":"00000000-0000-0000-0000-000"#
        + #"000000003","isVisible":true,"name":"Depth"}],"orientation":{"mirrored":false,"quarterTurns":1},"pointCur"#
        + #"ve":[{"x":0,"y":0.05},{"x":0.5,"y":0.55},{"x":1,"y":1}],"processVersion":7,"spots":[{"center":{"x":0.3,""#
        + #"y":0.3},"feather":50,"id":"00000000-0000-0000-0000-000000000004","mode":"heal","opacity":100,"radius":0."#
        + #"02,"source":{"x":0.6,"y":0.3}}],"treatment":"blackAndWhite","values":{"basic.exposure":0.7,"wb.temperatu"#
        + #"re":6500},"version":3,"whiteBalance":"daylight"},"snapshots":[{"created":"1970-01-01T00:16:40Z","id":"00"#
        + #"000000-0000-0000-0000-000000000005","name":"Before","recipe":{"baseLook":{"amount":100,"id":"redlamp/bas"#
        + #"e/color","name":"Redlamp Color","version":1},"processVersion":7,"treatment":"color","values":{},"version"#
        + #"":3,"whiteBalance":"asShot"}}]}"#

    /// `SidecarSamples.ordinary`, decoded and written again by main.
    static let ordinary = [
        #"{"format":"app.redlamp.edit","modified":"0001-01-01T00:00:00Z","recipe":{"baseLook":{"amount":80,"id":"r"#
            + #"edlamp/base/vivid","name":"Redlamp Vivid","version":1},"processVersion":1,"treatment":"color","values":{"#
            + #"},"version":3,"whiteBalance":"asShot"},"snapshots":[]}"#,
        #"{"format":"app.redlamp.edit","modified":"0001-01-01T00:00:00Z","recipe":{"baseLook":{"amount":100,"id":""#
            + #"redlamp/base/color","name":"Redlamp Color","version":1},"processVersion":1,"treatment":"color","values":"#
            + #"{"basic.exposure":0.5},"version":3,"whiteBalance":"asShot"},"snapshots":[]}"#,
        #"{"format":"app.redlamp.edit","modified":"2026-09-30T08:00:00Z","recipe":{"baseLook":{"amount":100,"id":""#
            + #"redlamp/base/color","name":"Redlamp Color","version":1},"future":true,"processVersion":1,"treatment":"co"#
            + #"lor","values":{"basic.exposure":0.5,"future.parameter":3},"version":3,"whiteBalance":"asShot"},"snapshot"#
            + #"s":[],"versions":[{"name":"Alt"}]}"#,
        #"{"format":"app.redlamp.edit","modified":"0001-01-01T00:00:00Z","recipe":{"baseLook":{"amount":100,"id":""#
            + #"redlamp/base/color","name":"Redlamp Color","version":1},"processVersion":1,"treatment":"color","values":"#
            + #"{},"version":3,"whiteBalance":"asShot"},"snapshots":[]}"#,
    ]
}
