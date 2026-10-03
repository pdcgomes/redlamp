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

    @Test(arguments: SidecarSamples.ordinary)
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
        try store.save(SidecarSamples.everything, for: image)
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

    /// `SidecarSamples.everything`, saved, with `value` added at `path` as a newer build might.
    private func saveEverything(adding value: JSONValue, at path: String, for image: URL) throws -> Data {
        let store = SidecarStore()
        try store.save(SidecarSamples.everything, for: image)
        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        let json = try JSONEncoder().encode(JSONPatch.apply([JSONPatch.Operation(.add, path, value)], to: written))
        try json.write(to: store.editURL(for: image))
        return json
    }

    /// Fields a newer build could add below the top level, where this build keeps them.
    static let kept: [(path: String, value: JSONValue)] = [
        ("/recipe/masks/0/adjustments/local.future", .number(40)),
        ("/recipe/masks/0/blendMode", .string("multiply")),
        ("/recipe/masks/0/components/0/opacity", .number(50)),
        ("/recipe/masks/1/components/0/shape/ai/_0/edgeSoftness", .number(3)),
        ("/recipe/masks/2/components/0/shape/depthRange/_0/depth/edgeSoftness", .number(3)),
        ("/recipe/spots/0/sourceRotation", .number(20)),
        ("/recipe/appliedRecipe/author", .string("Someone")),
        ("/snapshots/0/pinned", .bool(true)),
        ("/snapshots/0/recipe/futureStage", .bool(true)),
        ("/metadata/caption", .string("Harbour at dawn")),
    ]

    @Test func `metadata a newer build added keeps an otherwise empty sidecar`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1},"#
            + #""metadata":{"rating":0,"caption":"Harbour at dawn"}}"#
        try Data(json.utf8).write(to: store.url(for: image))
        let sidecar = try #require(store.load(for: image))
        #expect(sidecar.metadata?.isEmpty == false)
        try store.saveOrRemove(sidecar, for: image)
        #expect(store.load(for: image)?.metadata?.unknownFields["caption"] == .string("Harbour at dawn"))
    }

    @Test(arguments: kept)
    func `a field a newer build added is kept, and the photo stays editable`(path: String, value: JSONValue) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = try saveEverything(adding: value, at: path, for: image)
        #expect(store.protection(for: image) == nil)

        var sidecar = try #require(store.load(for: image))
        sidecar.recipe[.contrast] = 10
        sidecar.metadata?.rating = 2
        try store.save(sidecar, for: image)
        let before = try JSONDecoder().decode(JSONValue.self, from: json)
        let after = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        let lost = JSONPatch.diff(from: before, to: after).filter { $0.op != .add && $0.path.hasPrefix(path) }
        #expect(lost.isEmpty)
    }

    /// Fields where this build has nowhere to keep them, and a value outside this build's range.
    static let lossy: [(path: String, value: JSONValue)] = [
        ("/recipe/crop/angle", .number(2)),
        ("/recipe/baseLook/strength", .number(2)),
        ("/recipe/masks/0/components/1/shape/radial/_0/falloff", .number(2)),
        ("/recipe/masks/0/components/2/shape/brush/_0/strokes/0/tilt", .number(2)),
        ("/recipe/masks/1/components/0/shape/ai/_0/bitmap/format", .string("heic")),
        ("/recipe/values/basic.exposure", .number(9)),
    ]

    @Test(arguments: lossy)
    func `a sidecar that wouldn't survive a save is read-only and kept`(path: String, value: JSONValue) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = try saveEverything(adding: value, at: path, for: image)

        #expect(store.protection(for: image) == .lossy)
        #expect(store.load(for: image) != nil, "it is still shown")
        #expect(throws: SidecarStoreError.lossy(store.url(for: image))) {
            try store.save(SidecarSamples.everything, for: image)
        }
        #expect(throws: SidecarStoreError.lossy(store.url(for: image))) {
            try Library.writeMetadata(PhotoMetadata(rating: 1), for: image, store: store)
        }
        #expect(throws: SidecarStoreError.lossy(store.url(for: image))) {
            try store.saveOrRemove(Sidecar(recipe: EditRecipe()), for: image)
        }
        store.delete(for: image)
        #expect(try Data(contentsOf: store.editURL(for: image)) == json)
    }
}
