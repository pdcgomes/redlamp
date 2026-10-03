import Foundation
import RedlampDocument
import RedlampEngineAPI

/// Sidecars for the round-trip and golden tests.
enum SidecarSamples {
    private static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private static func ai(_ kind: MaskKind) -> AIMask {
        AIMask(
            kind: kind, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(png: Data("\(kind)".utf8), width: 4, height: 2),
            createdAt: Date(timeIntervalSince1970: 1000),
        )
    }

    /// An edit using every part of the format: each mask shape, local adjustments, spots, crop,
    /// orientation, a recipe, a curve, a snapshot and culling metadata.
    static var everything: Sidecar {
        var recipe = EditRecipe()
        recipe[.exposure] = 0.7
        recipe[.temperature] = 6500
        recipe.treatment = .blackAndWhite
        recipe.whiteBalanceMode = .daylight
        recipe.pointCurve = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]
        let stroke = BrushStroke(points: [ImagePoint(x: 0.1, y: 0.2)], size: 0.05)
        let samples = [ColorSample(center: ImagePoint(x: 0.2, y: 0.5))]
        var gradient = MaskLayer(id: id(1), name: "Sky", components: [
            MaskComponent(
                id: id(11),
                shape: .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.5))),
            ),
            MaskComponent(
                id: id(12),
                shape: .radial(RadialMask(center: ImagePoint(x: 0.4, y: 0.4), radiusX: 0.2, radiusY: 0.1)),
            ),
            MaskComponent(id: id(13), shape: .brush(BrushMask(strokes: [stroke])), operation: .subtract),
            MaskComponent(id: id(14), shape: .luminanceRange(LuminanceRangeMask(lower: 20, upper: 80)), inverted: true),
            MaskComponent(id: id(15), shape: .colorRange(ColorRangeMask(samples: samples))),
        ])
        gradient[.localExposure] = -0.5
        let subject = MaskLayer(id: id(2), name: "Subject", components: [
            MaskComponent(id: id(21), shape: .ai(ai(.subject))),
        ])
        let depth = MaskLayer(id: id(3), name: "Depth", components: [
            MaskComponent(id: id(31), shape: .depthRange(DepthRangeMask(depth: ai(.depthRange)))),
            MaskComponent(id: id(32), shape: .maskReference(MaskReference(maskID: subject.id))),
        ])
        recipe.masks = [gradient, subject, depth]
        recipe.spots = [RetouchSpot(
            id: id(4), mode: .heal, center: ImagePoint(x: 0.3, y: 0.3), source: ImagePoint(x: 0.6, y: 0.3),
            radius: 0.02,
        )]
        recipe.appliedRecipe = AppliedRecipe(id: "local/test", version: 1, name: "Test", amount: 80)
        recipe.crop = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.8)
        recipe.orientation = ImageOrientation(quarterTurns: 1)
        return Sidecar(
            recipe: recipe,
            snapshots: [Snapshot(
                id: id(5),
                name: "Before",
                created: Date(timeIntervalSince1970: 1000),
                recipe: EditRecipe(),
            )],
            metadata: PhotoMetadata(rating: 4, flag: .pick, label: .green),
            modified: Date(timeIntervalSince1970: 2000),
        )
    }

    /// Ordinary sidecars of every format: format 1 with a profile and an old look id, format 2,
    /// one carrying fields a newer build added where they are kept, and one spelling out defaults.
    static let ordinary = [
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"#
            + #""profile":{"id":"redlamp.vivid","name":"Redlamp Vivid","amount":80}}}"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":2,"processVersion":1,"values":{"basic.exposure":0.5}}}"#,
        #"{"format":"app.redlamp.edit","modified":"2026-09-30T08:00:00Z","snapshots":[],"versions":[{"name":"Alt"}],"#
            +
            #""recipe":{"version":3,"processVersion":1,"future":true,"values":{"basic.exposure":0.5,"future.parameter":3}}}"#,
        #"{"format":"app.redlamp.edit","snapshots":[],"recipe":{"version":3,"processVersion":1,"values":{"basic.exposure":0},"#
            + #""masks":[],"spots":[],"crop":{"left":0,"top":0,"right":1,"bottom":1},"#
            +
            #""baseLook":{"id":"redlamp/base/color","version":1,"name":"Redlamp Color","amount":100,"contentHash":null}}}"#,
    ]
}
