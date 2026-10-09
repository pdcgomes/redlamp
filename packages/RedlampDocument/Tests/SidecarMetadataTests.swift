import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

/// The organising fields the sidecar's metadata gained (LIB-15, LIB-22, LIB-23, LIB-28): each read and
/// written back as it was, written only when it's set, and sidecars older builds wrote left as they are.
struct SidecarMetadataTests {
    private func temporaryImage() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "IMG_0001.ARW"), { try? FileManager.default.removeItem(at: directory) })
    }

    /// The metadata object of the edit saved for `image`.
    private func written(_ store: SidecarStore, for image: URL) throws -> [String: JSONValue] {
        let edit = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        guard case let .object(root) = edit, case let .object(metadata)? = root["metadata"] else { return [:] }
        return metadata
    }

    static let stackID = UUID(uuidString: "6F1C2A4E-8B1D-4C3A-9E57-1B2D3C4E5F60")!

    /// Each field set alone, with what the sidecar holds for it.
    static let fields: [(key: String, metadata: PhotoMetadata, json: JSONValue)] = [
        ("customLabel", PhotoMetadata(customLabel: "Urgent"), .string("Urgent")),
        ("mark", PhotoMetadata(mark: true), .bool(true)),
        ("title", PhotoMetadata(title: "Tram 28"), .string("Tram 28")),
        ("caption", PhotoMetadata(caption: "The tram climbing to Graça."), .string("The tram climbing to Graça.")),
        ("creator", PhotoMetadata(creator: "Ana Sousa; Rui Lopes"), .string("Ana Sousa; Rui Lopes")),
        ("copyright", PhotoMetadata(copyright: "© 2026 Ana Sousa"), .string("© 2026 Ana Sousa")),
        (
            "location",
            PhotoMetadata(location: PhotoLocation(
                country: "Portugal", state: "Lisboa", city: "Lisbon", sublocation: "Graça", countryCode: "PT",
            )),
            .object([
                "country": .string("Portugal"), "state": .string("Lisboa"), "city": .string("Lisbon"),
                "sublocation": .string("Graça"), "countryCode": .string("PT"),
            ]),
        ),
        (
            "collections", PhotoMetadata(collections: ["Clients/Acme/Selects", "Best%2FWorst"]),
            .array([.string("Clients/Acme/Selects"), .string("Best%2FWorst")]),
        ),
        (
            "stack", PhotoMetadata(stack: PhotoStack(id: stackID, top: true)),
            .object(["id": .string(stackID.uuidString), "top": .bool(true)]),
        ),
        (
            "stack", PhotoMetadata(stack: PhotoStack(id: stackID, position: 3)),
            .object(["id": .string(stackID.uuidString), "position": .number(3)]),
        ),
        ("captureShift", PhotoMetadata(captureShift: -18000), .number(-18000)),
        ("captureOffset", PhotoMetadata(captureOffset: 19800), .number(19800)),
    ]

    @Test(arguments: fields)
    func `each field round-trips through the sidecar, and alone keeps it`(
        key: String, metadata: PhotoMetadata, json: JSONValue,
    ) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        #expect(!metadata.isEmpty)
        try store.saveOrRemove(Sidecar(recipe: EditRecipe(), metadata: metadata), for: image)
        #expect(try written(store, for: image) == ["rating": .number(0), key: json])
        #expect(store.load(for: image)?.metadata == metadata)
        #expect(store.protection(for: image) == nil)
    }

    @Test func `a field that isn't set isn't written`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let metadata = PhotoMetadata(
            rating: 2, mark: false, location: PhotoLocation(city: "Lisbon"), collections: [],
            stack: PhotoStack(id: Self.stackID, top: false), captureShift: 0, captureOffset: nil,
        )
        try store.save(Sidecar(recipe: EditRecipe(), metadata: metadata), for: image)
        #expect(try written(store, for: image) == [
            "rating": .number(2), "location": .object(["city": .string("Lisbon")]),
            "stack": .object(["id": .string(Self.stackID.uuidString)]),
        ])
        #expect(store.load(for: image)?.metadata == metadata)
        try store.saveOrRemove(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(mark: false)), for: image)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: image).path))
    }

    @Test func `an empty title, caption, creator, copyright or location is the photo's: it has none`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let cleared = [
            PhotoMetadata(title: ""), PhotoMetadata(caption: ""), PhotoMetadata(creator: ""),
            PhotoMetadata(copyright: ""), PhotoMetadata(location: PhotoLocation()),
        ]
        for metadata in cleared {
            #expect(!metadata.isEmpty)
            try store.saveOrRemove(Sidecar(recipe: EditRecipe(), metadata: metadata), for: image)
            #expect(store.load(for: image)?.metadata == metadata)
        }
    }

    @Test func `a sidecar written before these fields keeps loading and saving unchanged`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let metadata: [String: JSONValue] = [
            "rating": .number(3), "flag": .string("pick"), "label": .string("red"),
            "originalName": .string("DSC_0042.NEF"), "keywords": .array([.string("Places/Portugal/Lisbon")]),
        ]
        let old: JSONValue = try .object([
            "format": .string("app.redlamp.edit"), "modified": .string("2026-10-01T09:00:00Z"),
            "snapshots": .array([]), "metadata": .object(metadata),
            "recipe": JSONDecoder().decode(JSONValue.self, from: JSONEncoder.sidecar.encode(EditRecipe())),
        ])
        let bytes = try JSONEncoder.sidecar.encode(old)
        try store.save(Sidecar(recipe: EditRecipe()), for: image)
        try bytes.write(to: store.editURL(for: image))

        let loaded = try #require(store.load(for: image))
        #expect(loaded.metadata == PhotoMetadata(
            rating: 3, flag: .pick, label: .red, originalName: "DSC_0042.NEF", keywords: ["Places/Portugal/Lisbon"],
        ))
        #expect(store.protection(for: image) == nil)
        #expect(try JSONEncoder.sidecar.encode(loaded) == bytes)
        var edited = loaded
        edited.recipe[.exposure] = 0.4
        try store.save(edited, for: image)
        #expect(try written(store, for: image) == metadata)
    }

    @Test func `a sidecar written before the capture time's shift and zone saves byte for byte as it was`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let metadata: [String: JSONValue] = [
            "rating": .number(4), "flag": .string("pick"), "customLabel": .string("Urgent"), "mark": .bool(true),
            "title": .string("Tram 28"), "location": .object(["city": .string("Lisbon")]),
            "collections": .array([.string("Clients/Acme")]),
            "stack": .object(["id": .string(Self.stackID.uuidString)]),
            "originalName": .string("DSC_0042.NEF"),
        ]
        let old: JSONValue = try .object([
            "format": .string("app.redlamp.edit"), "modified": .string("2026-10-05T09:00:00Z"),
            "snapshots": .array([]), "metadata": .object(metadata),
            "recipe": JSONDecoder().decode(JSONValue.self, from: JSONEncoder.sidecar.encode(EditRecipe())),
        ])
        let bytes = try JSONEncoder.sidecar.encode(old)
        try store.save(Sidecar(recipe: EditRecipe()), for: image)
        try bytes.write(to: store.editURL(for: image))

        let loaded = try #require(store.load(for: image))
        #expect(loaded.metadata?.captureShift == 0 && loaded.metadata?.captureOffset == nil)
        #expect(store.protection(for: image) == nil)
        #expect(try JSONEncoder.sidecar.encode(loaded) == bytes)
        try store.save(loaded, for: image)
        #expect(try Data(contentsOf: store.editURL(for: image)) == bytes)
        var edited = loaded
        edited.recipe[.exposure] = 0.4
        try store.save(edited, for: image)
        #expect(try written(store, for: image) == metadata)
    }

    @Test func `a capture shift that isn't a whole number of seconds can't be read`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1},"#
            + #""metadata":{"rating":0,"captureShift":1.5}}"#
        try Data(json.utf8).write(to: store.url(for: image))
        #expect(store.load(for: image) == nil)
        #expect(store.protection(for: image) == .unreadable)
    }

    @Test func `every field another writer changed alone is kept when an edit is saved over theirs`() {
        let base = Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 1))
        var ours = base
        ours.recipe[.exposure] = 0.5
        let everything = PhotoMetadata(
            rating: 3, flag: .reject, label: .blue, originalName: "DSC_0042.NEF", keywords: ["Places/Porto"],
            customLabel: "Urgent", mark: true, title: "Tram 28", caption: "Graça", creator: "Ana Sousa",
            copyright: "© 2026 Ana Sousa", location: PhotoLocation(city: "Lisbon"), collections: ["Clients/Acme"],
            stack: PhotoStack(id: Self.stackID, top: true), captureShift: 3600, captureOffset: -18000,
        )
        let unset = Dictionary(uniqueKeysWithValues: Mirror(reflecting: PhotoMetadata()).children.map {
            ($0.label ?? "", String(describing: $0.value))
        })
        for field in Mirror(reflecting: everything).children where field.label != "unknownFields" {
            #expect(
                String(describing: field.value) != unset[field.label ?? ""],
                "\(field.label ?? "?") is left at its default: give it a value here, and merge it",
            )
        }
        for metadata in Self.fields.map(\.metadata) + [everything] {
            var theirs = base
            theirs.metadata = metadata
            let merged = SidecarStore.merge(ours, theirs, base: base, opened: base)
            #expect(merged.metadata == metadata)
            #expect(merged.recipe[.exposure] == 0.5)
        }
    }

    @Test func `keys a newer build added to a location or a stack are kept`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1},"metadata":{"rating":0,"#
            + #""location":{"city":"Lisbon","altitude":12},"stack":{"id":"\#(Self.stackID.uuidString)","order":2}}}"#
        try Data(json.utf8).write(to: store.url(for: image))
        #expect(store.protection(for: image) == nil)
        var sidecar = try #require(store.load(for: image))
        #expect(sidecar.metadata?.location?.unknownFields == ["altitude": .number(12)])
        sidecar.metadata?.rating = 4
        try store.save(sidecar, for: image)
        let metadata = try written(store, for: image)
        #expect(metadata["location"] == .object(["city": .string("Lisbon"), "altitude": .number(12)]))
        #expect(metadata["stack"] == .object(["id": .string(Self.stackID.uuidString), "order": .number(2)]))
    }

    @Test func `a false mark or top, or a shift of 0, another writer left reads as none and is dropped on saving`(
    ) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1},"metadata":{"rating":1,"#
            + #""mark":false,"collections":[],"stack":{"top":false},"captureShift":0}}"#
        try Data(json.utf8).write(to: store.url(for: image))
        #expect(store.protection(for: image) == nil)
        let sidecar = try #require(store.load(for: image))
        #expect(sidecar.metadata == PhotoMetadata(rating: 1, stack: PhotoStack()))
        try store.save(sidecar, for: image)
        #expect(try written(store, for: image) == ["rating": .number(1), "stack": .object([:])])
    }
}
