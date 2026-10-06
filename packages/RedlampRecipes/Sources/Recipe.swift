import Foundation
import RedlampEngineAPI

/// A shareable look: slider settings, optionally on top of a Base Look.
///
/// Recipes are declarative and never executable, so a file from anyone is safe to read
/// once `RecipeValidator` accepts it. `id` plus `version` identifies a recipe forever: a
/// published version never changes, and applying a recipe writes its resolved values into
/// the edit, so a later version can't change photos already edited with an earlier one.
public struct Recipe: Sendable, Hashable, Identifiable {
    /// The `.redrecipe` file syntax.
    public static let formatVersion = 1
    public static let fileExtension = "redrecipe"

    public var id: String
    public var version: Int
    public var name: String
    /// Where the recipe is listed, for example "Portrait".
    public var group: String
    public var summary: String?
    public var author: RecipeAuthor?
    /// An SPDX identifier such as `CC-BY-4.0`, or a marketplace license name.
    public var license: String?
    public var tags: [String]
    /// The rendering behavior the recipe was tuned with (`EditRecipe.processVersion`).
    public var processVersion: Int
    /// The setting groups the recipe controls; everything else is left as it is.
    public var includes: Set<RecipeSettingGroup>
    public var settings: RecipeSettings
    public var baseLook: BaseLookReference?
    /// Base Looks the recipe carries with it, so it renders anywhere without other files.
    public var embeddedBaseLooks: [BaseLookPackage]
    /// The recipe as it was written in another dialect, such as a camera recipe card.
    public var source: RecipeSource?
    /// Lint checks this recipe fails on purpose, for example a toned black and white.
    public var lintWaivers: Set<String>
    /// Reserved for marketplace signing; not verified yet.
    public var signature: String?
    public var created: Date?
    /// Fields written by a newer Redlamp, kept so a save never erases them.
    public private(set) var unknownFields: [String: JSONValue] = [:]
    /// The file's format version when it was read.
    public private(set) var fileFormat: Int = Recipe.formatVersion

    public init(
        id: String,
        version: Int = 1,
        name: String,
        group: String,
        summary: String? = nil,
        author: RecipeAuthor? = nil,
        license: String? = nil,
        tags: [String] = [],
        processVersion: Int = EditRecipe.currentProcessVersion,
        includes: Set<RecipeSettingGroup>,
        settings: RecipeSettings,
        baseLook: BaseLookReference? = nil,
        embeddedBaseLooks: [BaseLookPackage] = [],
        source: RecipeSource? = nil,
        lintWaivers: Set<String> = [],
        signature: String? = nil,
        created: Date? = nil,
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.group = group
        self.summary = summary
        self.author = author
        self.license = license
        self.tags = tags
        self.processVersion = processVersion
        self.includes = includes
        self.settings = settings
        self.baseLook = baseLook
        self.embeddedBaseLooks = embeddedBaseLooks
        self.source = source
        self.lintWaivers = lintWaivers
        self.signature = signature
        self.created = created
    }

    /// The namespace part of the id: `redlamp`, `local` or a publisher.
    public var namespace: String {
        String(id.split(separator: "/", maxSplits: 1).first ?? "")
    }

    public var isBundled: Bool {
        namespace == RecipeNamespace.bundled
    }

    public var isLocal: Bool {
        namespace == RecipeNamespace.local
    }

    /// Whether any part of the recipe needs a Redlamp newer than this one to render exactly.
    public var requiresNewerRedlamp: Bool {
        fileFormat > Recipe.formatVersion
            || processVersion > EditRecipe.currentProcessVersion
            || !unknownFields.isEmpty
            || !settings.unknownValues.isEmpty
            || !settings.unknownIncludes.isEmpty
            || embeddedBaseLooks.contains { $0.table?.isSupported == false }
    }

    /// Whether the look relies on a table (a LUT) rather than parameters alone.
    public var usesLookTable: Bool {
        baseLook?.contentHash != nil
    }

    /// Captures an edit as a recipe that controls `includes`.
    public static func capture(
        _ edit: EditRecipe,
        id: String = RecipeNamespace.newLocalID(),
        name: String,
        group: String = "My Recipes",
        includes: Set<RecipeSettingGroup>,
        embedding looks: [BaseLookPackage] = [],
    ) -> Recipe {
        var values: [ParameterID: Double] = [:]
        for group in includes {
            for parameter in group.parameters where !edit.isDefault(parameter) {
                values[parameter] = edit[parameter]
            }
        }
        let settings = RecipeSettings(
            values: values,
            treatment: includes.contains(.treatment) ? edit.treatment : nil,
            whiteBalanceMode: includes.contains(.whiteBalance) ? edit.whiteBalanceMode : nil,
            pointCurve: includes.contains(.toneCurve) ? edit.pointCurve : nil,
        )
        let baseLook = includes.contains(.baseLook) ? edit.baseLook : nil
        return Recipe(
            id: id,
            name: name,
            group: group,
            processVersion: edit.processVersion,
            includes: includes,
            settings: settings,
            baseLook: baseLook,
            embeddedBaseLooks: looks.filter { package in baseLook.map { package.matches($0) } ?? false },
            created: Date(),
        )
    }
}

public enum RecipeNamespace {
    /// Reserved for recipes that ship with Redlamp.
    public static let bundled = "redlamp"
    /// Recipes made on this machine.
    public static let local = "local"

    public static func newLocalID() -> String {
        "\(local)/\(UUID().uuidString.lowercased())"
    }

    /// `namespace/slug[/more]`: lowercase letters, digits, `-`, `_` and `.` only.
    public static func isValid(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, id.count <= 200 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(allowed.contains) }
    }
}

public struct RecipeAuthor: Codable, Sendable, Hashable {
    public var name: String
    public var url: String?

    public init(name: String, url: String? = nil) {
        self.name = name
        self.url = url
    }
}

/// The groups of settings a recipe can control, in panel order.
public enum RecipeSettingGroup: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case treatment
    case baseLook
    case whiteBalance
    case tone
    case presence
    case toneCurve
    case colorMixer
    case colorGrading
    case colorChrome
    case effects
    case detail

    public var name: String {
        switch self {
        case .treatment: "Treatment"
        case .baseLook: "Base Look"
        case .whiteBalance: "White Balance"
        case .tone: "Tone"
        case .presence: "Presence"
        case .toneCurve: "Tone Curve"
        case .colorMixer: "Color Mixer"
        case .colorGrading: "Color Grading"
        case .colorChrome: "Color Chrome"
        case .effects: "Effects"
        case .detail: "Detail"
        }
    }

    /// Groups a new recipe captures unless the user changes them. White balance and
    /// detail depend on the photo, so they are left out, as in Lightroom.
    public static let captureDefaults: Set<RecipeSettingGroup> = Set(allCases).subtracting([.whiteBalance, .detail])

    /// The scalar parameters in the group. Lens, transform and calibration settings are
    /// specific to a photo and never belong to a recipe.
    public var parameters: [ParameterID] {
        ParameterID.allCases.filter { RecipeSettingGroup(parameter: $0) == self }
    }

    public init?(parameter: ParameterID) {
        switch parameter {
        case .temperature, .tint, .wbShiftRed, .wbShiftBlue: self = .whiteBalance
        case .exposure, .contrast, .highlights, .shadows, .whites, .blacks, .dynamicRange: self = .tone
        case .texture, .clarity, .dehaze, .vibrance, .saturation: self = .presence
        case .colorChrome, .colorChromeBlue: self = .colorChrome
        default:
            let key = parameter.rawValue
            if key.hasPrefix("toneCurve.") {
                self = .toneCurve
            } else if key.hasPrefix("mixer.") {
                self = .colorMixer
            } else if key.hasPrefix("grading.") {
                self = .colorGrading
            } else if key.hasPrefix("effects.") {
                self = .effects
            } else if key.hasPrefix("detail.") {
                self = .detail
            } else {
                return nil
            }
        }
    }

    public static func < (lhs: RecipeSettingGroup, rhs: RecipeSettingGroup) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// The values a recipe sets. Parameters of an included group that aren't listed take
/// their default, so a recipe renders the same whatever the photo had before.
public struct RecipeSettings: Sendable, Hashable {
    public var values: [ParameterID: Double]
    public var treatment: Treatment?
    public var whiteBalanceMode: WhiteBalanceMode?
    public var pointCurve: [CurvePoint]?
    /// Parameters a newer Redlamp knows, kept unchanged.
    public internal(set) var unknownValues: [String: Double] = [:]
    /// Setting groups a newer Redlamp knows, kept unchanged.
    public internal(set) var unknownIncludes: [String] = []

    public init(
        values: [ParameterID: Double] = [:],
        treatment: Treatment? = nil,
        whiteBalanceMode: WhiteBalanceMode? = nil,
        pointCurve: [CurvePoint]? = nil,
    ) {
        self.values = values
        self.treatment = treatment
        self.whiteBalanceMode = whiteBalanceMode
        self.pointCurve = pointCurve
    }

    public subscript(parameter: ParameterID) -> Double {
        values[parameter] ?? parameter.spec.defaultValue
    }
}

extension RecipeSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case values, treatment, whiteBalance, pointCurve
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        values = [:]
        for (key, value) in raw {
            if let parameter = ParameterID(rawValue: key) {
                values[parameter] = value
            } else {
                unknownValues[key] = value
            }
        }
        treatment = try container.decodeIfPresent(Treatment.self, forKey: .treatment)
        whiteBalanceMode = try container.decodeIfPresent(WhiteBalanceMode.self, forKey: .whiteBalance)
        pointCurve = try container.decodeIfPresent([CurvePoint].self, forKey: .pointCurve)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let known = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        try container.encode(unknownValues.merging(known) { _, value in value }, forKey: .values)
        try container.encodeIfPresent(treatment, forKey: .treatment)
        try container.encodeIfPresent(whiteBalanceMode, forKey: .whiteBalance)
        try container.encodeIfPresent(pointCurve, forKey: .pointCurve)
    }
}

/// A recipe as first written in another dialect. It is kept next to the resolved values
/// so it can be shown and edited in its own terms.
public enum RecipeSource: Sendable, Hashable {
    case cameraCard(CameraRecipeCard, mappingVersion: Int)
    /// A dialect this build doesn't know, kept unchanged.
    case other(dialect: String, payload: [String: JSONValue])
}

extension RecipeSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case dialect, mappingVersion, card
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dialect = try container.decode(String.self, forKey: .dialect)
        if dialect == CameraRecipeCard.dialect,
           let card = try? container.decode(CameraRecipeCard.self, forKey: .card) {
            let mapping = try container.decodeIfPresent(Int.self, forKey: .mappingVersion) ?? 1
            self = .cameraCard(card, mappingVersion: mapping)
        } else {
            var payload = try decoder.container(keyedBy: DynamicCodingKey.self).unknownFields(excluding: ["dialect"])
            payload.removeValue(forKey: "dialect")
            self = .other(dialect: dialect, payload: payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .cameraCard(card, mappingVersion):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(CameraRecipeCard.dialect, forKey: .dialect)
            try container.encode(mappingVersion, forKey: .mappingVersion)
            try container.encode(card, forKey: .card)
        case let .other(dialect, payload):
            var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
            try dynamic.encode(payload)
            try dynamic.encode(dialect, forKey: DynamicCodingKey("dialect"))
        }
    }
}

// MARK: - Base Looks in files

/// A Base Look as stored in a recipe file: parameters plus an optional look table.
public struct BaseLookPackage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var version: Int
    public var name: String
    public var summary: String?
    /// Film-simulation-style slot this look fills, for camera recipe cards.
    public var slot: String?
    public var parameters: BaseLookParameters
    public var table: LookTableFile?

    private enum CodingKeys: String, CodingKey {
        case id, version, name, summary, slot, parameters = "look", table
    }

    public init(
        id: String,
        version: Int = 1,
        name: String,
        summary: String? = nil,
        slot: String? = nil,
        parameters: BaseLookParameters = .identity,
        table: LookTable? = nil,
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.summary = summary
        self.slot = slot
        self.parameters = parameters
        self.table = table.map(LookTableFile.init)
    }

    /// Decodes and verifies the table.
    public func definition() throws -> BaseLookDefinition {
        try BaseLookDefinition(id: id, version: version, name: name, parameters: parameters, table: table?.decode())
    }

    public var reference: BaseLookReference {
        BaseLookReference(id: id, version: version, name: name, contentHash: table?.sha256)
    }

    public func matches(_ reference: BaseLookReference) -> Bool {
        id == reference.id && version == reference.version && table?.sha256 == reference.contentHash
    }
}

/// A look table as JSON: base64 little-endian Float16 values, red fastest.
public struct LookTableFile: Codable, Sendable, Hashable {
    public var size: Int
    /// A `LookTableSpace` raw value; unknown spaces come from a newer Redlamp.
    public var space: String
    public var sha256: String
    public var data: String

    public init(_ table: LookTable) {
        size = table.size
        space = table.space.rawValue
        sha256 = table.contentHash
        data = table.littleEndianBytes.base64EncodedString()
    }

    public var isSupported: Bool {
        LookTableSpace(rawValue: space) != nil
    }

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case unsupportedSpace(String)
        case badData
        case hashMismatch

        public var description: String {
            switch self {
            case let .unsupportedSpace(space): "the look table uses \(space), which needs a newer Redlamp"
            case .badData: "the look table data is not valid base64"
            case .hashMismatch: "the look table does not match its checksum"
            }
        }
    }

    public func decode() throws -> LookTable {
        guard let space = LookTableSpace(rawValue: space) else { throw DecodeError.unsupportedSpace(space) }
        guard let bytes = Data(base64Encoded: data) else { throw DecodeError.badData }
        let table = try LookTable(size: size, space: space, littleEndianBytes: bytes)
        guard table.contentHash == sha256 else { throw DecodeError.hashMismatch }
        return table
    }
}

// MARK: - Codable

extension Recipe: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, id, version, name, group, summary, author, license, tags, processVersion, includes
        case settings, baseLook, embeddedBaseLooks, source, lintWaivers, signature, created
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileFormat = try container.decodeIfPresent(Int.self, forKey: .format) ?? 1
        id = try container.decode(String.self, forKey: .id)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try container.decode(String.self, forKey: .name)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? "Recipes"
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        author = try container.decodeIfPresent(RecipeAuthor.self, forKey: .author)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        processVersion = try container.decodeIfPresent(Int.self, forKey: .processVersion) ?? 1
        var settings = try container.decodeIfPresent(RecipeSettings.self, forKey: .settings) ?? RecipeSettings()
        let includeNames = try container.decodeIfPresent([String].self, forKey: .includes)
        if let includeNames {
            includes = Set(includeNames.compactMap(RecipeSettingGroup.init(rawValue:)))
            settings.unknownIncludes = includeNames.filter { RecipeSettingGroup(rawValue: $0) == nil }
        } else {
            includes = RecipeSettings.inferredIncludes(settings)
        }
        self.settings = settings
        baseLook = try container.decodeIfPresent(BaseLookReference.self, forKey: .baseLook)
        if baseLook != nil, includeNames == nil {
            includes.insert(.baseLook)
        }
        embeddedBaseLooks = try container.decodeIfPresent([BaseLookPackage].self, forKey: .embeddedBaseLooks) ?? []
        source = try container.decodeIfPresent(RecipeSource.self, forKey: .source)
        lintWaivers = try Set(container.decodeIfPresent([String].self, forKey: .lintWaivers) ?? [])
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(max(fileFormat, Recipe.formatVersion), forKey: .format)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(group, forKey: .group)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(license, forKey: .license)
        if !tags.isEmpty {
            try container.encode(tags, forKey: .tags)
        }
        try container.encode(processVersion, forKey: .processVersion)
        try container.encode(includes.sorted().map(\.rawValue) + settings.unknownIncludes, forKey: .includes)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(baseLook, forKey: .baseLook)
        if !embeddedBaseLooks.isEmpty {
            try container.encode(embeddedBaseLooks, forKey: .embeddedBaseLooks)
        }
        try container.encodeIfPresent(source, forKey: .source)
        if !lintWaivers.isEmpty {
            try container.encode(lintWaivers.sorted(), forKey: .lintWaivers)
        }
        try container.encodeIfPresent(signature, forKey: .signature)
        try container.encodeIfPresent(created, forKey: .created)
    }
}

extension RecipeSettings {
    /// For files without an `includes` list: the groups that have a value.
    static func inferredIncludes(_ settings: RecipeSettings) -> Set<RecipeSettingGroup> {
        var groups = Set(settings.values.keys.compactMap(RecipeSettingGroup.init(parameter:)))
        if settings.treatment != nil {
            groups.insert(.treatment)
        }
        if settings.whiteBalanceMode != nil {
            groups.insert(.whiteBalance)
        }
        if settings.pointCurve != nil {
            groups.insert(.toneCurve)
        }
        return groups
    }
}
