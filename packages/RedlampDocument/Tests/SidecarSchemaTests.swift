import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

/// `docs/recipes/sidecar-format.schema.json` against the real encoder and decoder: a rich sidecar, as
/// `SidecarStore` writes it, validates; every key it holds is in the schema and every key in the
/// schema is written; `required` is what the decoder needs; and objects are open exactly where
/// unknown keys survive a save.
struct SidecarSchemaTests {
    static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/recipes/sidecar-format.schema.json")
    static let documentURL = schemaURL.deletingLastPathComponent().appending(path: "sidecar-format.md")

    private func validator() throws -> SchemaValidator {
        try SchemaValidator(schema: json(Data(contentsOf: Self.schemaURL)))
    }

    private func json(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func json(_ text: String) throws -> JSONValue {
        try json(Data(text.utf8))
    }

    /// Saves the rich sidecar with `SidecarStore` and hands `body` the store and the image.
    private func withRichSidecar<T>(_ body: (SidecarStore, URL, Sidecar) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appending(path: "IMG_0001.ARW")
        let store = SidecarStore()
        let sidecar = RichSidecar.sidecar()
        try store.save(sidecar, for: image)
        return try body(store, image, sidecar)
    }

    /// The rich sidecar's `edit.json` and history file, as written.
    private func written() throws -> (edit: JSONValue, history: JSONValue) {
        try withRichSidecar { store, image, sidecar in
            let session = try #require(sidecar.session)
            let history = store.url(for: image).appending(path: SidecarStore.historyDirectory)
                .appending(path: "\(session.id.uuidString).json")
            return try (json(Data(contentsOf: store.editURL(for: image))), json(Data(contentsOf: history)))
        }
    }

    /// Each history step's whole edit, its patches applied.
    private func stepRecipes(_ history: JSONValue) throws -> [JSONValue] {
        var recipes: [JSONValue] = []
        for step in history["steps"]?.arrayValue ?? [] {
            if let recipe = step["recipe"] {
                recipes.append(recipe)
            } else if let patch = step["patch"], let previous = recipes.last {
                let operations = try JSONDecoder().decode([JSONPatch.Operation].self, from: JSONEncoder().encode(patch))
                try recipes.append(JSONPatch.apply(operations, to: previous))
            }
        }
        return recipes
    }

    // MARK: - Rich sidecars

    @Test func `a rich sidecar validates as SidecarStore writes it`() throws {
        let validator = try validator()
        try withRichSidecar { store, image, sidecar in
            let edit = try json(Data(contentsOf: store.editURL(for: image)))
            #expect(validator.errors(in: edit) == [])

            let session = try #require(sidecar.session)
            let file = store.url(for: image).appending(path: "history/\(session.id.uuidString).json")
            let history = try json(Data(contentsOf: file))
            #expect(validator.errors(in: history, against: "#/$defs/historyFile") == [])
            let recipes = try stepRecipes(history)
            #expect(recipes.count == session.steps.count)
            for (index, recipe) in recipes.enumerated() {
                #expect(validator.errors(in: recipe, against: "#/$defs/recipe") == [], "step \(index)")
            }

            let bitmaps = sidecar.recipe.maskBitmaps + sidecar.snapshots.flatMap(\.recipe.maskBitmaps)
            #expect(bitmaps.count == 9)
            for bitmap in bitmaps {
                #expect(try Data(contentsOf: store.bitmapURL(bitmap.sha256, for: image)) == bitmap.png)
            }
        }
    }

    @Test func `every key written is in the schema, and every key in the schema is written`() throws {
        let validator = try validator()
        let (edit, history) = try written()
        let editKeys = validator.keys(in: edit)
        let historyKeys = validator.keys(in: history, against: "#/$defs/historyFile")
        #expect(editKeys.undeclared + historyKeys.undeclared == [], "keys the encoder wrote that the schema lacks")

        // Format 1's name for `baseLook`, which is read but never written.
        let readOnly: Set = ["#/$defs/recipe profile"]
        let unwritten = validator.declaredKeys.subtracting(editKeys.declared).subtracting(historyKeys.declared)
            .subtracting(readOnly)
        #expect(unwritten.sorted() == [], "keys in the schema that the rich sidecar doesn't write")
    }

    @Test func `the schema requires exactly what the edit's decoder needs`() throws {
        // `version` is read only by the newer-version check, which ignores a value of another type.
        let mismatches = try mismatches(
            in: written().edit,
            validator: validator(),
            ignoring: { $0.hasSuffix("/recipe/version") },
            decodes: { (try? JSONDecoder.sidecar.decode(Sidecar.self, from: $0)) != nil },
        )
        #expect(mismatches == [])
    }

    @Test func `the schema requires exactly what the history decoder needs`() throws {
        // The edits inside a history file are checked as edits, and a patch's value is any JSON. A
        // step without its patch leaves the edit as it was, which can break the patches after it.
        let opaque = { (path: [String]) in
            path.count == 3 && path[0] == "steps" && path[2] == "recipe"
                || path.count == 5 && path[0] == "steps" && path[2] == "patch" && path[4] == "value"
        }
        let mismatches = try mismatches(
            in: written().history, against: "#/$defs/historyFile", validator: validator(), opaque: opaque,
            ignoring: { $0.range(of: "^/steps/[0-9]+/patch$", options: .regularExpression) != nil },
            decodes: { (try? HistorySession(decoding: $0)) != nil },
        )
        #expect(mismatches == [])
    }

    @Test func `objects are open exactly where unknown keys survive a save`() throws {
        let validator = try validator()
        let edit = try written().edit
        try #require(validator.errors(in: edit) == [])
        var mismatches: [String] = []
        var tried: Set<String> = []
        // A mask shape holds one key, its kind; unknown kinds are checked below.
        let objects = [[]] + locations(in: edit).map(\.path).filter { path in
            edit[path]?.objectValue != nil && path.last != "shape" && tried.insert(shape(of: path)).inserted
        }
        for path in objects {
            let extended = edit.updating(path) { $0.adding("futureField") }
            let accepted = validator.errors(in: extended).isEmpty
            let kept = try saved(extended)[path]?["futureField"] != nil
            if accepted != kept {
                mismatches.append("\(pointer(path)): the schema \(accepted ? "accepts" : "rejects") an unknown key, "
                    + "and saving \(kept ? "keeps" : "drops") it")
            }
        }
        #expect(mismatches == [])

        let component = ["recipe", "masks", "0", "components", "0", "shape"]
        let lasso = try json(#"{"lasso": {"_0": {"points": [{"x": 0.1, "y": 0.2}], "closed": true}}}"#)
        let withLasso = edit.updating(component) { _ in lasso }
        #expect(validator.errors(in: withLasso) == [])
        #expect(try saved(withLasso)[component] == lasso)
    }

    /// `edit` read and written again, as a save does.
    private func saved(_ edit: JSONValue) throws -> JSONValue {
        let sidecar = try JSONDecoder.sidecar.decode(Sidecar.self, from: JSONEncoder().encode(edit))
        return try json(JSONEncoder.sidecar.encode(sidecar))
    }

    /// Every removal of an object key, and every value replaced by one of another type, where the schema
    /// and `decodes` disagree. Opaque values are removed but neither looked into nor replaced.
    private func mismatches(
        in document: JSONValue,
        against reference: String = "#",
        validator: SchemaValidator,
        opaque: ([String]) -> Bool = { _ in false },
        ignoring ignored: (String) -> Bool = { _ in false },
        decodes: (Data) -> Bool,
    ) throws -> [String] {
        let invalid = validator.errors(in: document, against: reference)
        guard invalid.isEmpty else { return ["the document itself is invalid: \(invalid)"] }
        var mismatches: [String] = []
        func compare(_ mutated: JSONValue, _ change: String) throws {
            let accepted = validator.errors(in: mutated, against: reference).isEmpty
            let read = try decodes(JSONEncoder().encode(mutated))
            if accepted != read {
                mismatches.append("\(change): the schema \(accepted ? "accepts" : "rejects") it, the decoder "
                    + "\(read ? "reads" : "rejects") it")
            }
        }
        var tried: Set<String> = []
        for (path, isKey) in locations(in: document, opaque: opaque) where !ignored(pointer(path)) {
            guard tried.insert(shape(of: path)).inserted else { continue }
            if isKey {
                try compare(document.updating(path) { _ in nil }, "without \(pointer(path))")
            }
            if !opaque(path) {
                try compare(document.updating(path) { $0.ofAnotherType }, "\(pointer(path)) of another type")
            }
        }
        return mismatches
    }

    // MARK: - Hand-written sidecars

    @Test func `older and minimal sidecars validate`() throws {
        let validator = try validator()
        let sidecars = [
            #"{"recipe": {}}"#,
            #"""
            {"format": "app.redlamp.edit", "recipe": {"version": 1, "processVersion": 1,
             "profile": {"id": "redlamp.vivid", "name": "Redlamp Vivid", "amount": 80}}}
            """#,
            #"""
            {"format": "app.redlamp.edit", "modified": "2026-09-30T09:00:00+01:00", "snapshots": [],
             "recipe": {"version": 2, "processVersion": 1, "values": {"basic.exposure": 0.5}}}
            """#,
        ]
        for text in sidecars {
            #expect(try validator.errors(in: json(text)) == [], "\(text)")
            #expect(throws: Never.self) { try JSONDecoder.sidecar.decode(Sidecar.self, from: Data(text.utf8)) }
        }
    }

    @Test func `wrong sidecars fail validation`() throws {
        let validator = try validator()
        let edit = try written().edit
        let exposure = ["recipe", "values", "basic.exposure"]
        let operation = ["recipe", "masks", "0", "components", "1", "operation"]
        let radial = ["recipe", "masks", "2", "components", "1", "shape", "radial", "_0"]
        // Each wrong sidecar, and where its error is.
        let wrong: [(error: String, sidecar: JSONValue)] = [
            ("", edit.updating(["recipe"]) { _ in nil }),
            ("/recipe/masks/0", edit.updating(["recipe", "masks", "0", "id"]) { _ in nil }),
            ("/recipe/values/basic.exposure", edit.updating(exposure) { _ in .string("bright") }),
            ("/recipe/values/basic.exposure", edit.updating(exposure) { _ in .number(7) }),
            ("/recipe/values/local.exposure", edit.updating(["recipe", "values"]) { $0.adding("local.exposure") }),
            ("/recipe/masks/0/adjustments/local.future", edit.updating(["recipe", "masks", "0", "adjustments"]) {
                guard case var .object(adjustments) = $0 else { return $0 }
                adjustments["local.future"] = .string("bright")
                return .object(adjustments)
            }),
            (pointer(operation), edit.updating(operation) { _ in .string("multiply") }),
            ("\(pointer(radial))/softness", edit.updating(radial) { $0.adding("softness") }),
            ("/modified", edit.updating(["modified"]) { _ in .string("2026-10-03T12:59:01") }),
            ("/recipe/processVersion", edit.updating(["recipe", "processVersion"]) { _ in .number(99) }),
        ]
        for (error, sidecar) in wrong {
            let errors = validator.errors(in: sidecar)
            #expect(errors.contains { $0.hasPrefix("\(error):") }, "\(error): \(errors)")
        }
    }

    @Test func `the examples in the document validate and read`() throws {
        let validator = try validator()
        let document = try String(contentsOf: Self.documentURL, encoding: .utf8)
        let examples = document.components(separatedBy: "```json\n").dropFirst()
            .compactMap { $0.components(separatedBy: "\n```").first }
        var kinds: [String] = []
        for text in examples {
            let example = try json(text)
            if example["recipe"] != nil {
                #expect(validator.errors(in: example) == [])
                #expect(throws: Never.self) { try JSONDecoder.sidecar.decode(Sidecar.self, from: Data(text.utf8)) }
                kinds.append("edit")
            } else {
                #expect(validator.errors(in: example, against: "#/$defs/historyFile") == [])
                #expect(throws: Never.self) { try HistorySession(decoding: Data(text.utf8)) }
                kinds.append("history")
            }
        }
        #expect(kinds == ["edit", "history"])
    }

    // MARK: - The schema against the code

    @Test func `parameters match the catalog`() throws {
        let validator = try validator()
        let global = ParameterID.allCases.filter { !$0.isMaskScoped && !$0.isSpotScoped && !$0.isPointColorScoped }
        #expect(Set(ParameterID.localParameters) == Set(ParameterID.allCases.filter(\.isLocal)))
        #expect(Set(ParameterID.pointColorParameters) == Set(ParameterID.allCases.filter(\.isPointColorScoped)))
        for (reference, parameters) in [
            ("#/$defs/values", global),
            ("#/$defs/localAdjustments", ParameterID.localParameters),
            ("#/$defs/pointColorValues", ParameterID.pointColorParameters),
        ] {
            let properties = validator.schema(at: "\(reference)/properties").objectValue ?? [:]
            #expect(Set(properties.keys) == Set(parameters.map(\.rawValue)), "\(reference)")
            for parameter in parameters {
                let spec = parameter.spec
                let entry = properties[parameter.rawValue]
                #expect(entry?["minimum"] == .number(spec.range.lowerBound), "\(parameter.rawValue)")
                #expect(entry?["maximum"] == .number(spec.range.upperBound), "\(parameter.rawValue)")
                #expect(entry?["default"] == .number(spec.defaultValue), "\(parameter.rawValue)")
            }
        }
    }

    @Test func `enumerations, versions and limits match the code`() throws {
        let validator = try validator()
        func strings(_ reference: String) -> Set<String> {
            Set((validator.schema(at: reference).arrayValue ?? []).compactMap(\.stringValue))
        }
        #expect(strings("#/$defs/recipe/properties/treatment/enum") == Set(Treatment.allCases.map(\.rawValue)))
        #expect(strings("#/$defs/recipe/properties/whiteBalance/enum") ==
            Set(WhiteBalanceMode.allCases.map(\.rawValue)))
        #expect(strings("#/$defs/maskComponent/properties/operation/enum") ==
            Set(MaskOperation.allCases.map(\.rawValue)))
        #expect(strings("#/$defs/aiMask/properties/kind/enum") == Set(MaskKind.allCases.filter(\.isAI).map(\.rawValue)))
        #expect(strings("#/$defs/aiMask/properties/part/enum")
            == Set(PersonPart.allCases.map(\.rawValue) + LandscapeClass.allCases.map(\.rawValue)))
        #expect(strings("#/$defs/retouchSpot/properties/mode/enum") == Set(RetouchSpot.Mode.allCases.map(\.rawValue)))
        #expect(strings("#/$defs/recipe/properties/panelsOff/items/enum") ==
            Set(SwitchablePanel.allCases.map(\.rawValue)))
        #expect(strings("#/$defs/metadata/properties/label/enum") == Set(ColorLabel.allCases.map(\.rawValue)))
        #expect(strings("#/$defs/metadata/properties/flag/enum") == Set([PhotoFlag.pick, .reject].map(\.rawValue)))

        #expect(validator.schema(at: "#/properties/format/const") == .string(Sidecar.format))
        #expect(validator.schema(at: "#/$defs/historyFile/properties/format/const") == .string(HistorySession.format))
        let integers: [(String, Int)] = [
            ("#/$defs/recipe/properties/version/maximum", EditRecipe.formatVersion),
            ("#/$defs/recipe/properties/processVersion/maximum", EditRecipe.currentProcessVersion),
            ("#/$defs/historyFile/properties/version/maximum", HistorySession.formatVersion),
            ("#/$defs/recipe/properties/masks/maxItems", MaskLayer.maximumLayers),
            ("#/$defs/colorRangeMask/properties/samples/maxItems", ColorRangeMask.maximumSamples),
        ]
        for (reference, value) in integers {
            #expect(validator.schema(at: reference) == .number(Double(value)), "\(reference)")
        }
        let ranges: [(String, ClosedRange<Double>)] = [
            ("#/$defs/baseLookReference/properties/amount", BaseLookReference.amountRange),
            ("#/$defs/maskLayer/properties/amount", ParameterID.maskAmount.spec.range),
            ("#/$defs/maskLayer/properties/detail", ParameterID.maskDetail.spec.range),
            ("#/$defs/radialMask/properties/feather", ParameterID.maskFeather.spec.range),
            ("#/$defs/colorRangeMask/properties/refine", ParameterID.maskColorRefine.spec.range),
            ("#/$defs/retouchSpot/properties/feather", ParameterID.spotFeather.spec.range),
            ("#/$defs/retouchSpot/properties/opacity", ParameterID.spotOpacity.spec.range),
        ]
        for (reference, range) in ranges {
            #expect(validator.schema(at: "\(reference)/minimum") == .number(range.lowerBound), "\(reference)")
            #expect(validator.schema(at: "\(reference)/maximum") == .number(range.upperBound), "\(reference)")
        }
    }

    @Test func `the schema's defaults are what the decoder assumes`() throws {
        let validator = try validator()
        func withDefaults(_ reference: String, _ object: [String: JSONValue]) -> [String: JSONValue] {
            let properties = validator.schema(at: "\(reference)/properties").objectValue ?? [:]
            return object.merging(properties.compactMapValues { $0["default"] }) { given, _ in given }
        }
        func decoded<T: Decodable>(_: T.Type, _ object: [String: JSONValue]) throws -> T {
            try JSONDecoder.sidecar.decode(T.self, from: JSONEncoder().encode(JSONValue.object(object)))
        }
        #expect(try decoded(EditRecipe.self, withDefaults("#/$defs/recipe", [:])) == decoded(EditRecipe.self, [:]))
        let layer: [String: JSONValue] = ["id": .string(UUID().uuidString)]
        #expect(try decoded(MaskLayer.self, withDefaults("#/$defs/maskLayer", layer)) == decoded(MaskLayer.self, layer))
        let look: [String: JSONValue] = ["id": .string("local/looks/dusk"), "name": .string("Dusk")]
        #expect(try decoded(BaseLookReference.self, withDefaults("#/$defs/baseLookReference", look))
            == decoded(BaseLookReference.self, look))
    }

    @Test func `history actions are written as the schema says`() throws {
        let validator = try validator()
        for action in Self.historyActions {
            let encoded = try json(JSONEncoder().encode([action])).arrayValue?.first
            #expect(encoded == .string(expectedName(of: action)))
            #expect(validator.errors(in: encoded ?? .null, against: "#/$defs/historyAction") == [], "\(action)")
        }
        let plain = Self.historyActions.map(expectedName).filter { !$0.contains(":") }
        #expect(Set(validator.schema(at: "#/$defs/historyAction/anyOf/0/enum").arrayValue ?? []) ==
            Set(plain.map(JSONValue.string)))
        for unknown in ["hologram", "adjustment:", "mask:lasso", "Crop"] {
            #expect(validator.errors(in: .string(unknown), against: "#/$defs/historyAction") != [], "\(unknown)")
        }
    }

    static let historyActions: [HistoryAction] = [
        .open, .clear, .restore, .reset, .auto, .treatment, .baseLook, .whiteBalance, .toneCurve, .recipe, .snapshot,
        .paste, .crop, .rotate, .flip, .straighten, .upright, .mask(nil), .retouch, .edit,
    ] + ParameterID.allCases.map(HistoryAction.adjustment) + MaskKind.allCases.map(HistoryAction.mask)

    /// What each action is written as. The switch stops compiling when an action is added, until it is
    /// listed above and in the schema.
    private func expectedName(of action: HistoryAction) -> String {
        switch action {
        case let .adjustment(parameter): "adjustment:\(parameter.rawValue)"
        case let .mask(kind): kind.map { "mask:\($0.rawValue)" } ?? "mask"
        case .open, .clear, .restore, .reset, .auto, .treatment, .baseLook, .whiteBalance, .toneCurve, .recipe,
             .snapshot, .paste, .crop, .rotate, .flip, .straighten, .upright, .retouch, .edit: "\(action)"
        }
    }

    // MARK: - The validator

    @Test func `the validator checks the keywords it supports and refuses the others`() throws {
        let schema = try json(#"""
        {"type": "object", "required": ["a"], "properties": {
            "a": {"type": "integer", "minimum": 1, "maximum": 3},
            "b": {"oneOf": [{"const": "x"}, {"enum": ["x", "y"]}]},
            "c": {"type": "array", "prefixItems": [{"type": "string"}], "items": {"type": "number"}, "maxItems": 3},
            "d": {"type": ["string", "null"], "pattern": "^[a-z]+$"},
            "e": {"exclusiveMinimum": 0}},
         "patternProperties": {"^x-": false},
         "additionalProperties": {"type": "boolean"}}
        """#)
        let validator = try SchemaValidator(schema: schema)
        func errors(_ text: String) throws -> [String] {
            try validator.errors(in: json(text))
        }
        #expect(try errors(#"{"a": 2, "c": ["s", 1, 2], "d": null, "z": true}"#) == [])
        #expect(try errors(#"{"a": 2.5}"#).count == 1)
        #expect(try errors(#"{"a": 4}"#).count == 1)
        #expect(try errors(#"{}"#) == [": a is missing"])
        #expect(try errors(#"{"a": 1, "b": "x"}"#).count == 1, "oneOf matches both branches")
        #expect(try errors(#"{"a": 1, "b": "y"}"#) == [])
        #expect(try errors(#"{"a": 1, "c": [1]}"#).count == 1)
        #expect(try errors(#"{"a": 1, "c": ["s", 1, 2, 3]}"#).count == 1)
        #expect(try errors(#"{"a": 1, "d": "A"}"#).count == 1)
        #expect(try errors(#"{"a": 1, "x-y": true}"#).count == 1)
        #expect(try errors(#"{"a": 1, "z": 1}"#).count == 1)
        #expect(try errors(#"{"a": 1, "e": 1}"#) == ["/e: unsupported keyword exclusiveMinimum"])
    }
}

// MARK: - A rich sidecar

/// A sidecar with everything the format holds: masks of every kind, AI masks with refinements and
/// prompts, Remove, Heal and Clone spots, a crop with an angle, an orientation, a Base Look, an
/// applied recipe, an older process version, a snapshot with every global parameter set, metadata
/// and a history session.
enum RichSidecar {
    /// Files keep whole seconds.
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    static func sidecar() -> Sidecar {
        let edit = recipe()
        return Sidecar(
            recipe: edit,
            snapshots: [Snapshot(name: "Every slider", created: date, recipe: everySlider())],
            metadata: PhotoMetadata(rating: 4, flag: .pick, label: .purple, originalName: "DSC_0042.NEF"),
            modified: date,
            session: session(ending: edit),
        )
    }

    static func recipe() -> EditRecipe {
        var recipe = EditRecipe()
        recipe.processVersion = 6
        recipe.baseLook = BaseLookReference(
            id: "local/looks/teal-cinema", version: 2, name: "Teal Cinema", amount: 80,
            contentHash: String(repeating: "5e", count: 32),
        )
        recipe.whiteBalanceMode = .custom
        recipe[.temperature] = 6150
        recipe[.tint] = 12
        recipe.pointCurve = [CurvePoint(x: 0, y: 0.04), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 0.97)]
        recipe[.exposure] = 0.65
        recipe[.highlights] = -40
        recipe[.gradeShadowsHue] = 215
        recipe[.gradeShadowsSaturation] = 20
        recipe[.lensProfile] = 0
        recipe[.frameStyle] = 3
        recipe[.cropAngle] = 3.25
        recipe.crop = CropRect(left: 0.08, top: 0.05, right: 0.94, bottom: 0.9)
        recipe.orientation = ImageOrientation(quarterTurns: 1, mirrored: true)
        recipe.appliedRecipe = AppliedRecipe(id: "redlamp/film/portra-400", version: 2, name: "Portra 400", amount: 120)
        recipe.exposureAnchor = ExposureAnchor(stops: 0.94, source: .target, camera: "Canon EOS R5")
        recipe.pointColor = [
            PointColorSwatch(
                color: .oklch(OKLCh(lightness: 0.64, chroma: 0.08, hue: 48)),
                picked: ColorSample(center: point(0.42, 0.36), radius: 0.012),
                values: farEnds(of: ParameterID.pointColorParameters),
            ),
            PointColorSwatch(
                color: .oklch(OKLCh(lightness: 0.5, chroma: 0.12, hue: 250)),
                values: [.pointColorHueRange: 30],
            ),
        ]
        recipe.masks = masks()
        recipe.spots = spots()
        recipe.panelsOff = [.detail, .effects]
        return recipe
    }

    /// Each parameter at the end of its range farther from its default.
    static func farEnds(of parameters: [ParameterID]) -> [ParameterID: Double] {
        Dictionary(uniqueKeysWithValues: parameters.map { parameter in
            let range = parameter.spec.range
            return (parameter, range.upperBound == parameter.spec.defaultValue ? range.lowerBound : range.upperBound)
        })
    }

    /// Every global parameter away from its default, in a black and white edit at the current process.
    static func everySlider() -> EditRecipe {
        var recipe = EditRecipe()
        recipe.treatment = .blackAndWhite
        recipe.baseLook = BuiltInBaseLook.monochrome.reference.withAmount(120)
        recipe.whiteBalanceMode = .daylight
        let global = ParameterID.allCases.filter { !$0.isMaskScoped && !$0.isSpotScoped && !$0.isPointColorScoped }
        for (parameter, value) in farEnds(of: global) {
            recipe[parameter] = value
        }
        return recipe
    }

    static func point(_ x: Double, _ y: Double) -> ImagePoint {
        ImagePoint(x: x, y: y)
    }

    static func aiMask(_ kind: MaskKind, _ name: String, part: String? = nil, instance: Int? = nil) -> AIMask {
        AIMask(
            kind: kind, provider: "test.\(kind.rawValue)", revision: 2, osBuild: "25G83", instance: instance,
            part: part, analysisHash: "9f86d081884c7d65", center: point(0.5, 0.4),
            bitmap: MaskBitmap(png: Data(name.utf8), width: 64, height: 48), createdAt: date,
        )
    }

    static func stroke(at x: Double, erase: Bool = false) -> BrushStroke {
        BrushStroke(
            points: [point(x, 0.6), point(x + 0.04, 0.62), point(x + 0.08, 0.61)], pressures: [0.35, 0.8, 1],
            size: 0.03, feather: 40, flow: 75, density: 90, erase: erase, autoMask: !erase,
        )
    }

    static func masks() -> [MaskLayer] {
        let sky = skyMask()
        return [sky] + drawnMasks() + modelMasks(reusing: sky)
    }

    /// An AI mask with Refine Edge strokes, limited to a luminance range.
    static func skyMask() -> MaskLayer {
        var sky = aiMask(.sky, "sky")
        sky.refinements = [stroke(at: 0.2), stroke(at: 0.25, erase: true)]
        let range = LuminanceRangeMask(
            lower: 40, upper: 90, lowerFeather: 15, upperFeather: 5, samplePoint: point(0.3, 0.1),
        )
        let components = [
            MaskComponent(shape: .ai(sky)),
            MaskComponent(shape: .luminanceRange(range), operation: .intersect),
        ]
        return layer("Sky", components, [.localExposure: -0.4, .localDehaze: 20])
    }

    /// A hidden brush mask with an erase stroke, linear and radial gradients, and a color range.
    static func drawnMasks() -> [MaskLayer] {
        let strokes = [stroke(at: 0.4), stroke(at: 0.42, erase: true)]
        var dodge = MaskLayer(
            name: "Dodge", components: [MaskComponent(shape: .brush(BrushMask(strokes: strokes)))], isVisible: false,
            amount: 150, adjustments: [.localExposure: 0.3],
        )
        dodge.detail = 30
        dodge.inverted = true
        let linear = LinearMask(start: point(0.5, -0.1), end: point(0.5, 0.45))
        let radial = RadialMask(center: point(0.6, 0.55), radiusX: 0.2, radiusY: 0.12, rotation: 15, feather: 70)
        let samples = [ColorSample(center: point(0.2, 0.8)), ColorSample(center: point(0.25, 0.75), radius: 0.01)]
        let gradients = [
            MaskComponent(shape: .linear(linear)),
            MaskComponent(shape: .radial(radial), operation: .subtract, inverted: true),
        ]
        let foliage = [MaskComponent(shape: .colorRange(ColorRangeMask(samples: samples, refine: 35)))]
        return [
            dodge,
            layer("Gradients", gradients, [.localContrast: -10]),
            layer("Foliage", foliage, [.localHue: -12.5, .localSaturation: 15]),
        ]
    }

    static func layer(
        _ name: String,
        _ components: [MaskComponent],
        _ adjustments: [ParameterID: Double],
    ) -> MaskLayer {
        MaskLayer(name: name, components: components, adjustments: adjustments)
    }

    /// Depth Range, People, Objects, Landscape, Subject and Background masks, and one reusing `sky` with
    /// every local adjustment.
    static func modelMasks(reusing sky: MaskLayer) -> [MaskLayer] {
        let depth = DepthRangeMask(
            depth: aiMask(.depthRange, "depth"), lower: 0, upper: 35, lowerFeather: 0, upperFeather: 10,
        )
        var objects = aiMask(.objects, "objects", instance: 0)
        objects.prompts = [point(0.7, 0.5)]
        objects.excludedPrompts = [point(0.72, 0.55)]
        objects.box = ImageRect(x: 0.6, y: 0.4, width: 0.25, height: 0.2)
        objects.feather = 20
        objects.edge = -15
        let face = aiMask(.people, "face", part: PersonPart.faceSkin.rawValue, instance: 0)
        let faces = [MaskComponent(shape: .ai(face)), MaskComponent(shape: .ai(objects), operation: .subtract)]
        let trees = aiMask(.landscape, "trees", part: LandscapeClass.vegetation.rawValue)
        let reused = [
            MaskComponent(shape: .maskReference(MaskReference(maskID: sky.id))),
            MaskComponent(shape: .ai(aiMask(.subject, "subject")), operation: .subtract),
            MaskComponent(shape: .ai(aiMask(.background, "background")), operation: .intersect),
        ]
        var every = layer("Every adjustment", reused, farEnds(of: ParameterID.localParameters))
        var curves = MaskCurves()
        for (index, channel) in MaskCurves.Channel.allCases.enumerated() {
            curves[channel] = [
                CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.4, y: 0.3 + 0.05 * Double(index)), CurvePoint(x: 1, y: 0.95),
            ]
        }
        every.curves = curves
        var evened = layer("Faces", faces, [.localTexture: -20])
        evened.pointColor = [
            PointColorSwatch(color: .mask, values: [.pointColorHueUniformity: 50, .pointColorSaturationUniformity: 35]),
        ]
        return [
            layer("Background", [MaskComponent(shape: .depthRange(depth))], [.localSharpness: -60]),
            evened,
            layer("Trees", [MaskComponent(shape: .ai(trees))], [.localSaturation: 10]),
            every,
        ]
    }

    static func spots() -> [RetouchSpot] {
        let person = aiMask(.people, "person", part: PersonPart.entirePerson.rawValue, instance: 1)
        let dust = point(0.82, 0.2)
        let stroke = [point(0.01, 0), point(0.02, -0.01)]
        return [
            RetouchSpot(
                mode: .heal, center: point(0.3, 0.4), source: point(0.36, 0.4), radius: 0.02, feather: 60, opacity: 90,
            ),
            RetouchSpot(mode: .clone, center: point(0.6, 0.62), source: point(0.6, 0.7), stroke: stroke, radius: 0.015),
            RetouchSpot(mode: .remove, center: person.center, source: person.center, region: person, radius: 0.005),
            RetouchSpot(mode: .remove, center: dust, source: dust, radius: 0.006),
            RetouchSpot(
                mode: .remove, center: point(0.4, 0.75), source: point(0.4, 0.75), radius: 0.03,
                fill: GeneratedFill(
                    bitmap: MaskBitmap(png: Data("generated".utf8), width: 96, height: 64), peak: 1.37,
                    box: GeneratedFill.Box(x: 1600, y: 2900, width: 384, height: 256),
                    photoSize: PixelSize(width: 6000, height: 4000), model: "flux2-klein-4b-fill", modelVersion: 1,
                    seed: 7, prompt: "remove",
                ),
            ),
        ]
    }

    /// A session that builds `edit` step by step from the photo as opened.
    static func session(ending edit: EditRecipe) -> HistorySession {
        var recipe = EditRecipe()
        recipe.processVersion = edit.processVersion
        var steps = [HistoryStep(action: .open, title: "Opened", recipe: recipe)]
        func step(
            _ action: HistoryAction, _ title: String, before: String? = nil, after: String? = nil,
            _ change: (inout EditRecipe) -> Void,
        ) {
            change(&recipe)
            steps.append(HistoryStep(action: action, title: title, before: before, after: after, recipe: recipe))
        }
        step(.adjustment(.exposure), "Exposure", before: "0.00", after: "+0.65") { $0[.exposure] = edit[.exposure] }
        step(.whiteBalance, "White Balance", after: "Custom") {
            $0.whiteBalanceMode = edit.whiteBalanceMode
            $0[.temperature] = edit[.temperature]
            $0[.tint] = edit[.tint]
        }
        step(.mask(.sky), "New Sky") { $0.masks = [edit.masks[0]] }
        step(.mask(.brush), "New Brush") { $0.masks.append(edit.masks[1]) }
        step(.mask(nil), "Delete Mask") { $0.masks.removeLast() }
        step(.retouch, "Heal") { $0.spots = [edit.spots[0]] }
        step(.straighten, "Straighten", after: "+3.25°") { $0[.cropAngle] = edit[.cropAngle] }
        step(.crop, "Crop") { $0.crop = edit.crop }
        step(.rotate, "Rotate Right") { $0.orientation = ImageOrientation(quarterTurns: 1) }
        step(.flip, "Flip Horizontal") { $0.orientation = edit.orientation }
        step(.recipe, "Recipe", after: "Portra 400") { $0.appliedRecipe = edit.appliedRecipe }
        step(.baseLook, "Base Look", after: "Teal Cinema") { $0.baseLook = edit.baseLook }
        step(.restore, "Restored", after: "Sep 30, 2026 at 09:00") { $0.pointCurve = edit.pointCurve }
        step(.edit, "Edit") { $0 = edit }
        return HistorySession(started: date, steps: steps)
    }
}

// MARK: - A JSON Schema validator

/// The subset of JSON Schema 2020-12 that the sidecar schema uses. Any other keyword is an error, so
/// the schema can't come to rely on one this validator would ignore.
struct SchemaValidator {
    static let keywords: Set = [
        "$ref", "type", "enum", "const", "minimum", "maximum", "pattern", "properties", "patternProperties",
        "additionalProperties", "required", "minProperties", "maxProperties", "items", "prefixItems", "minItems",
        "maxItems", "anyOf", "oneOf",
    ]
    /// Keywords that describe without constraining.
    static let annotations: Set = ["$schema", "$id", "$defs", "title", "description", "default", "deprecated", "format"]
    private static let known = keywords.union(annotations)

    let root: JSONValue
    private var expressions: [String: NSRegularExpression] = [:]
    private var references: [String: JSONValue] = [:]

    init(schema: JSONValue) throws {
        root = schema
        for pattern in Self.strings(named: "pattern", in: schema) + Self.patternProperties(in: schema) {
            expressions[pattern] = try NSRegularExpression(pattern: pattern)
        }
        for reference in Self.strings(named: "$ref", in: schema) {
            references[reference] = resolve(reference)
        }
    }

    /// The schema at `reference`: `#`, or a JSON Pointer after it such as `#/$defs/recipe`.
    func schema(at reference: String) -> JSONValue {
        references[reference] ?? resolve(reference)
    }

    private func resolve(_ reference: String) -> JSONValue {
        let tokens = reference.dropFirst().split(separator: "/").map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        return root[tokens] ?? .bool(false)
    }

    /// Where `instance` breaks the schema at `reference`, as "pointer: problem".
    func errors(in instance: JSONValue, against reference: String = "#") -> [String] {
        var errors: [String] = []
        check(instance, schema(at: reference), at: "", into: &errors)
        return errors.sorted()
    }

    private func passes(_ value: JSONValue, _ schema: JSONValue) -> Bool {
        var errors: [String] = []
        check(value, schema, at: "", into: &errors)
        return errors.isEmpty
    }

    private func check(_ value: JSONValue, _ schema: JSONValue, at path: String, into errors: inout [String]) {
        guard case let .object(keywords) = schema else {
            if schema != .bool(true) {
                errors.append("\(path): not allowed here")
            }
            return
        }
        for keyword in keywords.keys where !Self.known.contains(keyword) {
            errors.append("\(path): unsupported keyword \(keyword)")
        }
        if let reference = keywords["$ref"]?.stringValue {
            check(value, self.schema(at: reference), at: path, into: &errors)
        }
        checkScalar(value, keywords, at: path, into: &errors)
        if let items = value.arrayValue {
            checkArray(items, keywords, at: path, into: &errors)
        }
        if let object = value.objectValue {
            checkObject(object, keywords, at: path, into: &errors)
        }
        if let branches = keywords["anyOf"]?.arrayValue, !branches.contains(where: { passes(value, $0) }) {
            errors.append("\(path): matches none of anyOf")
        }
        if let branches = keywords["oneOf"]?.arrayValue, branches.count(where: { passes(value, $0) }) != 1 {
            errors.append("\(path): doesn't match exactly one of oneOf")
        }
    }

    private func checkScalar(
        _ value: JSONValue, _ keywords: [String: JSONValue], at path: String, into errors: inout [String],
    ) {
        if let type = keywords["type"] {
            let names = type.arrayValue ?? [type]
            if !names.contains(where: { $0.stringValue.map(value.isOf) ?? false }) {
                errors.append("\(path): \(value.text) isn't of type \(type.text)")
            }
        }
        if let options = keywords["enum"]?.arrayValue, !options.contains(value) {
            errors.append("\(path): \(value.text) isn't one of \(keywords["enum"]?.text ?? "")")
        }
        if let constant = keywords["const"], constant != value {
            errors.append("\(path): \(value.text) isn't \(constant.text)")
        }
        if case let .number(number) = value {
            if let minimum = keywords["minimum"]?.numberValue, number < minimum {
                errors.append("\(path): \(value.text) is below \(minimum)")
            }
            if let maximum = keywords["maximum"]?.numberValue, number > maximum {
                errors.append("\(path): \(value.text) is above \(maximum)")
            }
        }
        if case let .string(text) = value, let pattern = keywords["pattern"]?.stringValue, !matches(text, pattern) {
            errors.append("\(path): \(value.text) doesn't match \(pattern)")
        }
    }

    private func checkArray(
        _ items: [JSONValue], _ keywords: [String: JSONValue], at path: String, into errors: inout [String],
    ) {
        let prefix = keywords["prefixItems"]?.arrayValue ?? []
        for (index, item) in items.enumerated() {
            if let schema = index < prefix.count ? prefix[index] : keywords["items"] {
                check(item, schema, at: "\(path)/\(index)", into: &errors)
            }
        }
        if let minimum = keywords["minItems"]?.numberValue, Double(items.count) < minimum {
            errors.append("\(path): fewer than \(minimum) items")
        }
        if let maximum = keywords["maxItems"]?.numberValue, Double(items.count) > maximum {
            errors.append("\(path): more than \(maximum) items")
        }
    }

    private func checkObject(
        _ object: [String: JSONValue], _ keywords: [String: JSONValue], at path: String, into errors: inout [String],
    ) {
        for key in keywords["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
            errors.append("\(path): \(key) is missing")
        }
        let properties = keywords["properties"]?.objectValue ?? [:]
        let patternProperties = keywords["patternProperties"]?.objectValue ?? [:]
        let additional = keywords["additionalProperties"]
        for (key, value) in object {
            let location = "\(path)/\(escape(key))"
            var declared = false
            if let schema = properties[key] {
                check(value, schema, at: location, into: &errors)
                declared = true
            }
            for (pattern, schema) in patternProperties where matches(key, pattern) {
                check(value, schema, at: location, into: &errors)
                declared = true
            }
            if !declared, let additional {
                check(value, additional, at: location, into: &errors)
            }
        }
        if let minimum = keywords["minProperties"]?.numberValue, Double(object.count) < minimum {
            errors.append("\(path): fewer than \(minimum) keys")
        }
        if let maximum = keywords["maxProperties"]?.numberValue, Double(object.count) > maximum {
            errors.append("\(path): more than \(maximum) keys")
        }
    }

    private func matches(_ text: String, _ pattern: String) -> Bool {
        expressions[pattern]?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The string values of every `keyword` in the schema.
    private static func strings(named keyword: String, in schema: JSONValue) -> [String] {
        let children = schema.objectValue.map { Array($0.values) } ?? schema.arrayValue ?? []
        return [schema[keyword]?.stringValue].compactMap(\.self) + children.flatMap { strings(named: keyword, in: $0) }
    }

    private static func patternProperties(in schema: JSONValue) -> [String] {
        let children = schema.objectValue.map { Array($0.values) } ?? schema.arrayValue ?? []
        let own = schema["patternProperties"]?.objectValue.map { Array($0.keys) } ?? []
        return own + children.flatMap(patternProperties(in:))
    }

    // MARK: Coverage

    /// Every property the schema declares, as "schema pointer key".
    var declaredKeys: Set<String> {
        Self.declaredKeys(in: root, at: "#")
    }

    private static func declaredKeys(in schema: JSONValue, at pointer: String) -> Set<String> {
        if let items = schema.arrayValue {
            return items.indices.reduce(into: []) { $0.formUnion(declaredKeys(in: items[$1], at: "\(pointer)/\($1)")) }
        }
        guard let object = schema.objectValue else { return [] }
        var keys = Set((object["properties"]?.objectValue ?? [:]).keys.map { "\(pointer) \($0)" })
        for (key, child) in object where !["default", "enum", "const"].contains(key) {
            keys.formUnion(declaredKeys(in: child, at: "\(pointer)/\(escape(key))"))
        }
        return keys
    }

    /// The object keys in `instance` that the schema declares, as "schema pointer key", and the
    /// pointers of those it doesn't. A value whose schema declares no properties isn't looked into.
    func keys(
        in instance: JSONValue,
        against reference: String = "#",
    ) -> (declared: Set<String>, undeclared: [String]) {
        var declared: Set<String> = []
        var undeclared: [String] = []
        walk(instance, reference, at: "", declared: &declared, undeclared: &undeclared)
        return (declared, undeclared.sorted())
    }

    private typealias Located = (pointer: String, keywords: [String: JSONValue])

    /// The schema at `pointer`, what it refers to, and the anyOf and oneOf branches `value` passes.
    private func applicable(_ value: JSONValue, _ pointer: String) -> [Located] {
        guard let keywords = schema(at: pointer).objectValue else { return [] }
        var schemas: [Located] = [(pointer, keywords)]
        if let reference = keywords["$ref"]?.stringValue {
            schemas += applicable(value, reference)
        }
        for combinator in ["anyOf", "oneOf"] {
            for (index, branch) in (keywords[combinator]?.arrayValue ?? []).enumerated() where passes(value, branch) {
                schemas += applicable(value, "\(pointer)/\(combinator)/\(index)")
            }
        }
        return schemas
    }

    private func walk(
        _ value: JSONValue, _ pointer: String, at path: String, declared: inout Set<String>, undeclared: inout [String],
    ) {
        let schemas = applicable(value, pointer)
        if let object = value.objectValue {
            let owners = schemas.filter { $0.keywords["properties"] != nil }
            guard !owners.isEmpty else { return }
            for (key, child) in object {
                guard let owner = owners.first(where: { $0.keywords["properties"]?[key] != nil }) else {
                    undeclared.append("\(path)/\(escape(key))")
                    continue
                }
                declared.insert("\(owner.pointer) \(key)")
                let next = "\(owner.pointer)/properties/\(escape(key))"
                walk(child, next, at: "\(path)/\(escape(key))", declared: &declared, undeclared: &undeclared)
            }
        }
        for (index, item) in (value.arrayValue ?? []).enumerated() {
            let prefixed = schemas.first { ($0.keywords["prefixItems"]?.arrayValue?.count ?? 0) > index }
            let next = prefixed.map { "\($0.pointer)/prefixItems/\(index)" }
                ?? schemas.first { $0.keywords["items"] != nil }.map { "\($0.pointer)/items" }
            if let next {
                walk(item, next, at: "\(path)/\(index)", declared: &declared, undeclared: &undeclared)
            }
        }
    }
}

// MARK: - JSON helpers

private func escape(_ key: String) -> String {
    key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}

private func pointer(_ path: [String]) -> String {
    path.map { "/\(escape($0))" }.joined()
}

/// The path with its array indices as `*`. The elements of an array share a schema, so a check made
/// at one place stands for every place with the same shape.
private func shape(of path: [String]) -> String {
    path.map { Int($0) == nil ? escape($0) : "*" }.joined(separator: "/")
}

/// Every object key and array element in `value`, outermost first, as paths of keys and indices.
/// Opaque values are listed but not looked into.
private func locations(
    in value: JSONValue,
    at path: [String] = [],
    opaque: ([String]) -> Bool = { _ in false },
) -> [(path: [String], isKey: Bool)] {
    guard path.isEmpty || !opaque(path) else { return [] }
    if let object = value.objectValue {
        return object.sorted { $0.key < $1.key }.flatMap { key, child in
            [(path + [key], true)] + locations(in: child, at: path + [key], opaque: opaque)
        }
    }
    return (value.arrayValue ?? []).enumerated().flatMap { index, child in
        [(path + ["\(index)"], false)] + locations(in: child, at: path + ["\(index)"], opaque: opaque)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(object) = self else { return nil }
        return object
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(items) = self else { return nil }
        return items
    }

    var stringValue: String? {
        guard case let .string(text) = self else { return nil }
        return text
    }

    var numberValue: Double? {
        guard case let .number(number) = self else { return nil }
        return number
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    subscript(path: [String]) -> JSONValue? {
        path.reduce(self) { value, token in
            value?.objectValue?[token] ?? Int(token).flatMap { index in
                value?.arrayValue.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            }
        }
    }

    /// This value with the one at `path` changed by `change`, or removed where `change` returns nil.
    func updating(_ path: [String], _ change: (JSONValue) -> JSONValue?) -> JSONValue {
        guard let token = path.first else { return change(self) ?? self }
        let rest = Array(path.dropFirst())
        switch self {
        case var .object(object):
            guard let child = object[token] else { return self }
            object[token] = rest.isEmpty ? change(child) : child.updating(rest, change)
            return .object(object)
        case var .array(items):
            guard let index = Int(token), items.indices.contains(index) else { return self }
            if !rest.isEmpty {
                items[index] = items[index].updating(rest, change)
            } else if let changed = change(items[index]) {
                items[index] = changed
            } else {
                items.remove(at: index)
            }
            return .array(items)
        default:
            return self
        }
    }

    /// This object with `key` added, set to 1.
    func adding(_ key: String) -> JSONValue {
        guard case var .object(object) = self else { return self }
        object[key] = .number(1)
        return .object(object)
    }

    /// A value of another JSON type, for checking that a decoder rejects it.
    var ofAnotherType: JSONValue {
        switch self {
        case .string: .number(7)
        case .number, .integer, .unsignedInteger: .string("7")
        case .bool: .string("true")
        case .array: .object([:])
        case .object: .array([])
        case .null: .number(0)
        }
    }

    func isOf(_ type: String) -> Bool {
        switch (type, self) {
        case ("null", .null), ("boolean", .bool), ("number", .number), ("string", .string), ("array", .array),
             ("object", .object): true
        case let ("integer", .number(number)): number.rounded() == number
        case ("integer", .integer), ("integer", .unsignedInteger), ("number", .integer),
             ("number", .unsignedInteger): true
        default: false
        }
    }

    /// Compact JSON, for messages.
    var text: String {
        (try? JSONEncoder().encode(self)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "\(self)"
    }
}
