import Foundation
import RedlampEngineAPI

/// A partial recipe: applying it changes only what it specifies.
public struct Preset: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let group: String
    public let values: [ParameterID: Double]
    public let treatment: Treatment?
    public let profile: BuiltInProfile?
    public let pointCurve: [CurvePoint]?

    public init(
        id: String,
        name: String,
        group: String,
        values: [ParameterID: Double],
        treatment: Treatment? = nil,
        profile: BuiltInProfile? = nil,
        pointCurve: [CurvePoint]? = nil,
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.values = values
        self.treatment = treatment
        self.profile = profile
        self.pointCurve = pointCurve
    }

    public func apply(to recipe: EditRecipe) -> EditRecipe {
        var result = recipe
        for (parameter, value) in values {
            result[parameter] = value
        }
        if let treatment {
            result.treatment = treatment
        }
        if let profile {
            result.profile = profile.reference
        }
        if let pointCurve {
            result.pointCurve = pointCurve
        }
        return result
    }
}

public enum BuiltInPresets {
    public static let all: [Preset] = [
        Preset(id: "essentials.punchy", name: "Punchy", group: "Essentials", values: [
            .contrast: 25, .highlights: -20, .shadows: 15, .whites: 10, .blacks: -10, .vibrance: 25,
        ], profile: .vivid),
        Preset(id: "essentials.clean", name: "Clean & Bright", group: "Essentials", values: [
            .exposure: 0.3, .contrast: 5, .highlights: -35, .shadows: 30, .whites: 15, .vibrance: 12,
        ]),
        Preset(id: "essentials.soft", name: "Soft Matte", group: "Essentials", values: [
            .contrast: -20, .highlights: -25, .shadows: 20, .saturation: -12,
        ], pointCurve: [CurvePoint(x: 0, y: 0.08), CurvePoint(x: 0.5, y: 0.52), CurvePoint(x: 1, y: 0.95)]),
        Preset(id: "essentials.moody", name: "Moody", group: "Essentials", values: [
            .exposure: -0.3, .contrast: 20, .highlights: -40, .shadows: -10, .vibrance: -10,
            .gradeShadowsHue: 210, .gradeShadowsSaturation: 18, .vignetteAmount: -25,
        ]),
        Preset(id: "essentials.golden", name: "Golden Hour", group: "Essentials", values: [
            .temperature: 6800, .tint: 8, .vibrance: 20, .gradeHighlightsHue: 45,
            .gradeHighlightsSaturation: 25, .gradeShadowsHue: 25, .gradeShadowsSaturation: 10,
        ]),
        Preset(id: "bw.contrast", name: "High Contrast", group: "Black & White", values: [
            .contrast: 40, .highlights: -20, .shadows: -10, .whites: 20, .blacks: -25,
        ], treatment: .blackAndWhite),
        Preset(id: "bw.soft", name: "Soft Silver", group: "Black & White", values: [
            .contrast: -10, .shadows: 25, .grainAmount: 20,
        ], treatment: .blackAndWhite),
        Preset(id: "bw.selenium", name: "Selenium", group: "Black & White", values: [
            .contrast: 20, .gradeShadowsHue: 265, .gradeShadowsSaturation: 18,
            .gradeHighlightsHue: 40, .gradeHighlightsSaturation: 10,
        ], treatment: .blackAndWhite),
        Preset(id: "film.faded", name: "Faded Film", group: "Film Looks", values: [
            .contrast: -15, .saturation: -15, .grainAmount: 25, .grainSize: 30,
            .gradeShadowsHue: 190, .gradeShadowsSaturation: 12, .gradeHighlightsHue: 50, .gradeHighlightsSaturation: 12,
        ], pointCurve: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 0.3, y: 0.3), CurvePoint(x: 1, y: 0.92)]),
        Preset(id: "film.warm", name: "Warm Negative", group: "Film Looks", values: [
            .temperature: 6200, .contrast: 10, .saturationBlue: -20, .hueOrange: -8,
            .gradeMidtonesHue: 35, .gradeMidtonesSaturation: 10, .grainAmount: 18,
        ], profile: .portrait),
        Preset(id: "film.cross", name: "Cross Process", group: "Film Looks", values: [
            .contrast: 25, .hueGreen: 25, .gradeShadowsHue: 160, .gradeShadowsSaturation: 30,
            .gradeHighlightsHue: 60, .gradeHighlightsSaturation: 30,
        ]),
    ]

    public static var groups: [(name: String, presets: [Preset])] {
        var order: [String] = []
        var grouped: [String: [Preset]] = [:]
        for preset in all {
            if grouped[preset.group] == nil {
                order.append(preset.group)
            }
            grouped[preset.group, default: []].append(preset)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}
