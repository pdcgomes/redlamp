import Foundation
import RedlampDocument
import RedlampEngineAPI

/// Where a report belongs: an area of the app and one of its features, named as the UI names
/// them, so a report reads "Masking › Objects" and lands with its area's label.
public struct FeedbackArea: Identifiable, Hashable, Sendable, Encodable {
    public let id: String
    public let title: String
    public let symbol: String
    /// One line under the title in the picker, and the GitHub label's description.
    public let summary: String
    /// The tracker prefixes its work is planned under (`docs/research/research-tracker.md`).
    public let tracker: [String]
    public let features: [FeedbackFeature]

    /// Outside the namespaces `scripts/tracker-issues.py` manages, so triage never strips it.
    public var label: String {
        "component:\(id)"
    }

    init(
        _ id: String,
        _ title: String,
        symbol: String,
        summary: String,
        tracker: [String],
        features: [FeedbackFeature],
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.tracker = tracker
        self.features = features.map { $0.placed(in: id) }
            + (id == Self.otherID ? [] : [FeedbackFeature("other", "Something else in \(title)").placed(in: id)])
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, tracker, features, label
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(tracker, forKey: .tracker)
        try container.encode(features, forKey: .features)
        try container.encode(label, forKey: .label)
    }

    static let otherID = "other"
}

/// A feature within an area. Its `id` is `area.feature`, stable across releases, so reports
/// can be grouped by it.
public struct FeedbackFeature: Identifiable, Hashable, Sendable, Encodable {
    public let id: String
    public let title: String
    /// Other words people use for it: Lightroom's names, plain words, what it's built on.
    public let keywords: [String]

    init(_ id: String, _ title: String, _ keywords: [String] = []) {
        self.id = id
        self.title = title
        self.keywords = keywords
    }

    fileprivate func placed(in area: String) -> FeedbackFeature {
        FeedbackFeature("\(area).\(id)", title, keywords)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title
    }
}

/// An area and one of its features: what a report is about.
public struct FeedbackTopic: Identifiable, Hashable, Sendable {
    public let area: FeedbackArea
    public let feature: FeedbackFeature

    public var id: String {
        feature.id
    }

    /// "Masking › Objects", as issue titles and the picker show it.
    public var path: String {
        "\(area.title) › \(feature.title)"
    }
}

public extension FeedbackArea {
    static func area(_ id: String) -> FeedbackArea? {
        catalog.first { $0.id == id }
    }

    /// The topic for a feature ID such as `masking.objects`.
    static func topic(_ featureID: String) -> FeedbackTopic? {
        guard let areaID = featureID.split(separator: ".").first.map(String.init),
              let area = area(areaID),
              let feature = area.features.first(where: { $0.id == featureID })
        else { return nil }
        return FeedbackTopic(area: area, feature: feature)
    }

    /// Features matching every word of `query` in their title, their area's title or their
    /// keywords, best first, then in the picker's order.
    static func search(_ query: String, limit: Int = 12) -> [FeedbackTopic] {
        let words = SearchMatcher.words(query)
        guard !words.isEmpty else { return [] }
        var scored: [(topic: FeedbackTopic, score: Int, order: Int)] = []
        for area in catalog {
            for feature in area.features {
                let terms = [feature.title, area.title, "\(area.title) \(feature.title)"] + feature.keywords
                if let score = SearchMatcher.score(words, terms: terms) {
                    scored.append((FeedbackTopic(area: area, feature: feature), score, scored.count))
                }
            }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(limit)
            .map(\.topic)
    }
}

// MARK: - What the UI shows, as features

public extension FeedbackArea {
    /// The feature a Develop slider belongs to; `nil` for a mask's own sliders.
    static func featureID(for parameter: ParameterID) -> String? {
        if PanelID.cameraRecipeParameters.contains(parameter) {
            return "develop.camera-recipe"
        }
        if parameter.isPointColorScoped {
            return "develop.point-color"
        }
        switch parameter {
        case .temperature, .tint: return "develop.white-balance"
        case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: return "develop.tone"
        case .texture, .clarity, .dehaze, .vibrance, .saturation: return "develop.presence"
        case .noiseLuminance, .noiseLuminanceDetail, .noiseLuminanceContrast,
             .noiseColor, .noiseColorDetail, .noiseColorSmoothness:
            return "develop.noise-reduction"
        default: break
        }
        return PanelID.allCases.first { $0.parameters.contains(parameter) }.map(featureID(for:))
    }

    static func featureID(for panel: PanelID) -> String {
        switch panel {
        case .basic: "develop.tone"
        case .toneCurve: "develop.tone-curve"
        case .colorMixer: "develop.color-mixer"
        case .colorGrading: "develop.color-grading"
        case .detail: "develop.sharpening"
        case .lens: "develop.lens-corrections"
        case .transform: "develop.transform"
        case .effects: "develop.effects"
        case .calibration: "develop.calibration"
        }
    }

    /// `nil` for Edit, whose panels say more than the tool does.
    static func featureID(for tool: EditTool) -> String? {
        switch tool {
        case .edit: nil
        case .crop: "crop.crop"
        case .heal: "healing.heal"
        case .redEye: "healing.red-eye"
        case .masking: "masking.other"
        }
    }

    static func featureID(for kind: MaskKind) -> String {
        switch kind {
        case .subject: "masking.subject"
        case .sky: "masking.sky"
        case .background: "masking.background"
        case .objects: "masking.objects"
        case .people: "masking.people"
        case .landscape: "masking.landscape"
        case .depthRange: "masking.depth-range"
        case .brush: "masking.brush"
        case .linear: "masking.linear"
        case .radial: "masking.radial"
        case .colorRange: "masking.color-range"
        case .luminanceRange: "masking.luminance-range"
        case .existingMask: "masking.combining"
        }
    }

    /// The feature a history step comes from; `nil` for steps that don't say (opening, clearing).
    static func featureID(for action: HistoryAction) -> String? {
        switch action {
        case let .adjustment(parameter): featureID(for: parameter)
        case .auto: "develop.auto"
        case .treatment, .baseLook: "develop.treatment"
        case .whiteBalance: "develop.white-balance"
        case .toneCurve: "develop.tone-curve"
        case .upright: "develop.transform"
        case .crop: "crop.crop"
        case .straighten: "crop.straighten"
        case .rotate, .flip: "crop.rotate"
        case let .mask(kind): kind.map(featureID(for:)) ?? "masking.other"
        case .retouch: "healing.heal"
        case .recipe: "recipes.applying"
        case .paste: "sync.paste"
        case .snapshot: "history.snapshots"
        case .restore: "history.sessions"
        case .reset: "history.reset"
        case .open, .clear, .edit: nil
        }
    }

    /// The Healing tool's click: a picked person or object, else the spot's mode.
    static func featureID(for mode: RetouchSpot.Mode, pick: SpotPick) -> String {
        guard pick == .spot else { return "healing.picks" }
        switch mode {
        case .remove: return "healing.remove"
        case .heal: return "healing.heal"
        case .clone: return "healing.clone"
        }
    }
}
