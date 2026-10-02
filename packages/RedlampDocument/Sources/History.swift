import Foundation
import RedlampEngineAPI

/// The kind of operation a history step records, which the History panel shows as an icon.
public enum HistoryAction: Hashable, Sendable {
    /// The photo as it was opened: a session's first step.
    case open
    /// What clearing history left.
    case clear
    /// A step brought back from an earlier session.
    case restore
    /// A slider, or a control that sets several sliders of one panel (the parameter is one of them).
    case adjustment(ParameterID)
    case reset
    case auto
    case treatment
    case baseLook
    case whiteBalance
    case toneCurve
    case recipe
    case snapshot
    case paste
    case crop
    case rotate
    case flip
    case straighten
    case upright
    /// A mask: a component, stroke or sample, one of its sliders, renaming or deleting it. The kind,
    /// when the step is about one type of component.
    case mask(MaskKind?)
    /// A Heal or Clone spot: adding, moving, resizing or deleting one.
    case retouch
    case edit
}

extension HistoryAction: Codable {
    private static let plain: [String: HistoryAction] = [
        "open": .open, "clear": .clear, "restore": .restore, "reset": .reset, "auto": .auto,
        "treatment": .treatment, "baseLook": .baseLook, "whiteBalance": .whiteBalance, "toneCurve": .toneCurve,
        "recipe": .recipe, "snapshot": .snapshot, "paste": .paste, "crop": .crop, "rotate": .rotate,
        "flip": .flip, "straighten": .straighten, "upright": .upright, "mask": .mask(nil), "retouch": .retouch,
        "edit": .edit,
    ]

    /// "adjustment:basic.exposure", "mask:brush", "crop". Actions this build doesn't know read as `edit`.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case let ("adjustment", raw?): self = ParameterID(rawValue: raw).map(Self.adjustment) ?? .edit
        case let ("mask", raw?): self = .mask(MaskKind(rawValue: raw))
        default: self = Self.plain[text] ?? .edit
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .adjustment(parameter): try container.encode("adjustment:\(parameter.rawValue)")
        case let .mask(kind?): try container.encode("mask:\(kind.rawValue)")
        default: try container.encode(Self.plain.first { $0.value == self }?.key ?? "edit")
        }
    }
}

/// One step of a photo's history: what was done, and the edit it left.
public struct HistoryStep: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var action: HistoryAction
    /// "Exposure", "Brush Stroke", "Treatment".
    public var title: String
    /// The one value the step changed, as it was and as it became: "+0.50" and "+1.00". Steps that
    /// change many values have neither; some have only `after` ("Recipe", "Teal Cinema 2").
    public var before: String?
    public var after: String?
    public var recipe: EditRecipe

    public init(
        id: UUID = UUID(),
        action: HistoryAction,
        title: String,
        before: String? = nil,
        after: String? = nil,
        recipe: EditRecipe,
    ) {
        self.id = id
        self.action = action
        self.title = title
        self.before = before
        self.after = after
        self.recipe = recipe
    }

    /// The step as one line of text: "Exposure: 0.00 → +0.50".
    public var name: String {
        switch (before, after) {
        case let (before?, after?): "\(title): \(before) → \(after)"
        case let (nil, after?): "\(title): \(after)"
        default: title
        }
    }
}

/// The steps of one visit to a photo, from opening it to leaving it.
public struct HistorySession: Identifiable, Hashable, Sendable {
    public static let format = "app.redlamp.history"
    public static let formatVersion = 1

    public var id: UUID
    public var started: Date
    public var steps: [HistoryStep]

    public init(id: UUID = UUID(), started: Date = Date(), steps: [HistoryStep]) {
        self.id = id
        self.started = started
        self.steps = steps
    }

    /// Whether anything was done after the session's first step.
    public var hasEdits: Bool {
        steps.count > 1
    }

    /// Every mask bitmap the steps use.
    public var maskBitmaps: [MaskBitmap] {
        var seen = Set<String>()
        return steps.flatMap(\.recipe.maskBitmaps).filter { seen.insert($0.sha256).inserted }
    }
}

// MARK: - Files

/// A session as written to `history/<id>.json` in the sidecar package: the first step's whole edit,
/// then each later step as a JSON Patch from the one before.
struct HistoryFile: Codable {
    struct Step: Codable {
        var id: UUID
        var action: HistoryAction
        var title: String
        var before: String?
        var after: String?
        var recipe: JSONValue?
        var patch: [JSONPatch.Operation]?
    }

    var format = HistorySession.format
    var version = HistorySession.formatVersion
    var id: UUID
    var started: Date
    /// The mask bitmaps the steps use, so the package keeps them without reading every step.
    var bitmaps: [String]
    var steps: [Step]

    /// Just what saving needs from a session file: its date and the bitmaps it uses.
    struct Summary: Decodable {
        var version: Int?
        var started: Date?
        var bitmaps: [String]?
    }
}

public enum HistoryFileError: Error, Equatable {
    case unsupported
    case empty
}

public extension HistorySession {
    /// The session file's JSON.
    func encoded() throws -> Data {
        var previous: JSONValue?
        var steps: [HistoryFile.Step] = []
        for step in self.steps {
            let json = try JSONDecoder.sidecar.decode(JSONValue.self, from: JSONEncoder.sidecar.encode(step.recipe))
            var record = HistoryFile.Step(
                id: step.id, action: step.action, title: step.title, before: step.before, after: step.after,
            )
            if let previous {
                record.patch = JSONPatch.diff(from: previous, to: json)
            } else {
                record.recipe = json
            }
            steps.append(record)
            previous = json
        }
        let file = HistoryFile(
            id: id, started: started, bitmaps: maskBitmaps.map(\.sha256).sorted(), steps: steps,
        )
        return try JSONEncoder.sidecar.encode(file)
    }

    /// A session read from its file's JSON. Mask bitmaps are left unloaded.
    init(decoding data: Data) throws {
        let file = try JSONDecoder.sidecar.decode(HistoryFile.self, from: data)
        guard file.format == HistorySession.format, file.version <= HistorySession.formatVersion else {
            throw HistoryFileError.unsupported
        }
        var json: JSONValue?
        var steps: [HistoryStep] = []
        for record in file.steps {
            if let recipe = record.recipe {
                json = recipe
            } else if let patch = record.patch, let previous = json {
                json = try JSONPatch.apply(patch, to: previous)
            }
            guard let json else { throw HistoryFileError.empty }
            let recipe = try JSONDecoder.sidecar.decode(EditRecipe.self, from: JSONEncoder.sidecar.encode(json))
            steps.append(HistoryStep(
                id: record.id, action: record.action, title: record.title, before: record.before,
                after: record.after, recipe: recipe,
            ))
        }
        guard !steps.isEmpty else { throw HistoryFileError.empty }
        self.init(id: file.id, started: file.started, steps: steps)
    }
}
