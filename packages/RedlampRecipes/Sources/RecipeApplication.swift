import Foundation
import RedlampEngineAPI

public extension Recipe {
    static let amountRange: ClosedRange<Double> = 0 ... 200

    /// Applies the recipe to an edit.
    ///
    /// Only included groups change. Within them, every parameter moves from the edit's
    /// current value towards the recipe's (its default when the recipe doesn't list it)
    /// by `amount` percent: 0 changes nothing, 100 is the recipe exactly, 200 goes twice
    /// as far, clamped to each slider's range. Temperature interpolates in mireds.
    ///
    /// White balance modes that depend on the photo (As Shot, Auto) are resolved through
    /// `whiteBalance`; when it returns nil the edit keeps its temperature and tint.
    ///
    /// A switched-off panel (UX-30) comes back on when the recipe changes one of its settings, as
    /// any change does, or sets one to a value that does something, so the recipe's look shows.
    func apply(
        to edit: EditRecipe,
        amount: Double = 100,
        whiteBalance: (WhiteBalanceMode) -> WhiteBalanceValue? = { $0.presetValue },
    ) -> EditRecipe {
        let t = min(max(amount, Recipe.amountRange.lowerBound), Recipe.amountRange.upperBound) / 100
        guard t > 0 else { return edit }
        var result = edit

        func blend(_ parameter: ParameterID, to target: Double) {
            let current = edit[parameter]
            if parameter == .temperature {
                let from = 1e6 / max(current, 1)
                let to = 1e6 / max(target, 1)
                result[parameter] = 1e6 / max(from + (to - from) * t, 1)
            } else {
                result[parameter] = current + (target - current) * t
            }
        }

        for group in includes.sorted() {
            switch group {
            case .treatment:
                if let treatment = settings.treatment, t >= 0.5 {
                    result.treatment = treatment
                }
            case .baseLook:
                if let look = baseLook {
                    result.baseLook = look.withAmount(look.amount * t)
                }
            case .whiteBalance:
                blend(.wbShiftRed, to: settings[.wbShiftRed])
                blend(.wbShiftBlue, to: settings[.wbShiftBlue])
                // A recipe that only fine-tunes (shifts) leaves the photo's white balance alone.
                if settings.whiteBalanceMode == nil, settings.values[.temperature] == nil,
                   settings.values[.tint] == nil {
                    break
                }
                let mode = settings.whiteBalanceMode ?? .custom
                let target: WhiteBalanceValue? = if mode == .custom {
                    WhiteBalanceValue(
                        temperature: settings.values[.temperature] ?? edit[.temperature],
                        tint: settings.values[.tint] ?? edit[.tint],
                    )
                } else {
                    whiteBalance(mode)
                }
                if let target {
                    blend(.temperature, to: target.temperature)
                    blend(.tint, to: target.tint)
                    result.whiteBalanceMode = abs(t - 1) < 0.001 ? mode : .custom
                }
            case .toneCurve:
                for parameter in group.parameters {
                    blend(parameter, to: settings[parameter])
                }
                result.pointCurve = Self.blendCurve(
                    edit.pointCurve,
                    settings.pointCurve ?? EditRecipe.linearPointCurve,
                    t,
                )
            default:
                for parameter in group.parameters {
                    blend(parameter, to: settings[parameter])
                }
            }
        }
        let controlled = Set(includes.flatMap(\.parameters))
        for panel in result.panelsOff {
            let curve = panel == .toneCurve && includes.contains(.toneCurve) && result.hasPointCurve
            if curve || panel.parameters.contains(where: {
                controlled.contains($0) && abs(result[$0] - SwitchablePanel.neutralValue($0)) > 1e-9
            }) {
                result.setPanel(panel, on: true)
            }
        }
        result.appliedRecipe = AppliedRecipe(id: id, version: version, name: name, amount: t * 100)
        return result
    }

    /// Blends two point curves by sampling both at their combined x positions.
    private static func blendCurve(_ from: [CurvePoint], _ to: [CurvePoint], _ t: Double) -> [CurvePoint] {
        if t >= 0.999, t <= 1.001 {
            return to
        }
        let xs = Set(from.map(\.x) + to.map(\.x)).sorted()
        let blended = xs.map { x in
            let a = evaluate(from, at: x)
            let b = evaluate(to, at: x)
            return CurvePoint(x: x, y: min(max(a + (b - a) * t, 0), 1))
        }
        return blended.count >= 2 ? blended : to
    }

    private static func evaluate(_ curve: [CurvePoint], at x: Double) -> Double {
        let points = curve.sorted { $0.x < $1.x }
        guard let first = points.first, let last = points.last else { return x }
        if x <= first.x {
            return first.y
        }
        if x >= last.x {
            return last.y
        }
        for (a, b) in zip(points, points.dropFirst()) where x <= b.x {
            let span = max(b.x - a.x, 1e-9)
            return a.y + (b.y - a.y) * (x - a.x) / span
        }
        return last.y
    }

    /// The same recipe as the edit would look with it applied on a fresh photo.
    func edit(whiteBalance: (WhiteBalanceMode) -> WhiteBalanceValue? = { $0.presetValue }) -> EditRecipe {
        apply(to: EditRecipe(), whiteBalance: whiteBalance)
    }
}
