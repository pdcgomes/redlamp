import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing

/// A sidecar this build can't save back without dropping or changing something is read-only;
/// every ordinary sidecar, in any format, stays editable.
struct SidecarRoundTripTests {
    private func temporaryImage() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "IMG_0001.ARW"), { try? FileManager.default.removeItem(at: directory) })
    }

    private static func ai(_ kind: MaskKind) -> AIMask {
        AIMask(
            kind: kind, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(png: Data("\(kind)".utf8), width: 4, height: 2),
        )
    }

    /// An edit using every part of the format: each mask shape, local adjustments, spots, crop,
    /// orientation, a recipe, a curve, a snapshot and culling metadata.
    private static var everything: Sidecar {
        var recipe = EditRecipe()
        recipe[.exposure] = 0.7
        recipe[.temperature] = 6500
        recipe.treatment = .blackAndWhite
        recipe.whiteBalanceMode = .daylight
        recipe.pointCurve = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]
        var gradient = MaskLayer(name: "Sky", components: [
            MaskComponent(shape: .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.5)))),
            MaskComponent(shape: .radial(RadialMask(center: ImagePoint(x: 0.4, y: 0.4), radiusX: 0.2, radiusY: 0.1))),
            MaskComponent(
                shape: .brush(BrushMask(strokes: [BrushStroke(points: [ImagePoint(x: 0.1, y: 0.2)], size: 0.05)])),
                operation: .subtract,
            ),
            MaskComponent(shape: .luminanceRange(LuminanceRangeMask(lower: 20, upper: 80)), inverted: true),
            MaskComponent(shape: .colorRange(ColorRangeMask(samples: [ColorSample(center: ImagePoint(
                x: 0.2,
                y: 0.5,
            ))]))),
        ])
        gradient[.exposure] = -0.5
        let subject = MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(ai(.subject)))])
        let depth = MaskLayer(name: "Depth", components: [
            MaskComponent(shape: .depthRange(DepthRangeMask(depth: ai(.depthRange)))),
            MaskComponent(shape: .maskReference(MaskReference(maskID: subject.id))),
        ])
        recipe.masks = [gradient, subject, depth]
        recipe.spots = [RetouchSpot(
            mode: .heal,
            center: ImagePoint(x: 0.3, y: 0.3),
            source: ImagePoint(x: 0.6, y: 0.3),
            radius: 0.02,
        )]
        recipe.appliedRecipe = AppliedRecipe(id: "local/test", version: 1, name: "Test", amount: 80)
        recipe.crop = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.8)
        recipe.orientation = ImageOrientation(quarterTurns: 1)
        return Sidecar(
            recipe: recipe,
            snapshots: [Snapshot(name: "Before", created: Date(timeIntervalSince1970: 1000), recipe: EditRecipe())],
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

    @Test(arguments: ordinary)
    func `an ordinary single-file sidecar stays editable`(json: String) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try Data(json.utf8).write(to: store.url(for: image))
        #expect(store.protection(for: image) == nil)
        var sidecar = try #require(store.load(for: image))
        sidecar.recipe[.contrast] = 10
        try store.save(sidecar, for: image)
        #expect(store.protection(for: image) == nil)
    }

    @Test func `a sidecar this build wrote, using every part of the format, stays editable`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(Self.everything, for: image)
        #expect(store.protection(for: image) == nil)
        var sidecar = try #require(store.load(for: image))
        sidecar.recipe[.contrast] = 10
        try store.save(sidecar, for: image)
        #expect(store.protection(for: image) == nil)

        // Rolling back: every key this build writes is one the previous build (787731f) reads.
        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        guard case let .object(root) = written, case let .object(recipe) = root["recipe"] else {
            Issue.record("sidecar did not encode as an object")
            return
        }
        #expect(Set(root.keys) == ["format", "recipe", "snapshots", "metadata", "modified"])
        #expect(Set(recipe.keys) == [
            "version", "processVersion", "treatment", "baseLook", "whiteBalance", "pointCurve", "values", "masks",
            "appliedRecipe", "crop", "orientation", "spots",
        ])
    }

    /// Fields a newer build could add below the top level, and a value outside this build's range.
    static let lossy: [(path: String, value: JSONValue)] = [
        ("/recipe/masks/0/adjustments/local.future", .number(40)),
        ("/recipe/masks/0/blendMode", .string("multiply")),
        ("/recipe/masks/0/components/0/opacity", .number(50)),
        ("/recipe/masks/1/components/0/shape/ai/_0/edgeSoftness", .number(3)),
        ("/recipe/spots/0/sourceRotation", .number(20)),
        ("/recipe/appliedRecipe/author", .string("Someone")),
        ("/recipe/crop/angle", .number(2)),
        ("/snapshots/0/pinned", .bool(true)),
        ("/metadata/caption", .string("Harbour at dawn")),
        ("/recipe/values/basic.exposure", .number(9)),
    ]

    @Test(arguments: lossy)
    func `a sidecar that wouldn't survive a save is read-only and kept`(path: String, value: JSONValue) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(Self.everything, for: image)
        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        let changed = try JSONPatch.apply([JSONPatch.Operation(.add, path, value)], to: written)
        let json = try JSONEncoder().encode(changed)
        try json.write(to: store.editURL(for: image))

        #expect(store.protection(for: image) == .lossy)
        #expect(store.load(for: image) != nil, "it is still shown")
        #expect(throws: SidecarStoreError.lossy(store.url(for: image))) {
            try store.save(Self.everything, for: image)
        }
        #expect(throws: SidecarStoreError.lossy(store.url(for: image))) {
            try store.saveOrRemove(Sidecar(recipe: EditRecipe()), for: image)
        }
        store.delete(for: image)
        #expect(try Data(contentsOf: store.editURL(for: image)) == json)
    }
}
