import Foundation

/// A mask's adjustments under a name, to give any mask, as Lightroom's Effect menu has: Redlamp's
/// own, and the user's, saved from a mask. An effect is the mask's sliders (its Color among them)
/// and its Curves; the mask's components, Amount, Detail, Invert and Point Color aren't part of it.
public struct MaskEffect: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// By `ParameterID` raw value, as `MaskPreset` keeps them.
    public var adjustments: [String: Double]
    /// The Curves; nil while they're straight.
    public var curves: MaskCurves?

    public init(
        id: String = UUID().uuidString, name: String, adjustments: [ParameterID: Double], curves: MaskCurves? = nil,
    ) {
        self.id = id
        self.name = name
        self.adjustments = Dictionary(uniqueKeysWithValues: adjustments.map { ($0.key.rawValue, $0.value) })
        self.curves = curves
    }

    /// The effect `mask` has: its sliders and its Curves.
    public init(_ mask: MaskLayer, name: String) {
        self.init(name: name, adjustments: mask.adjustments, curves: mask.curves)
    }

    /// Its sliders this build knows.
    public var localAdjustments: [ParameterID: Double] {
        Dictionary(uniqueKeysWithValues: adjustments.compactMap { key, value in
            ParameterID(rawValue: key).flatMap { $0.isLocal ? ($0, value) : nil }
        })
    }

    /// Whether it leaves every slider at 0 and the Curves straight, so a mask with no adjustments
    /// has it.
    public var isEmpty: Bool {
        MaskLayer(name: name, components: []).has(self)
    }

    /// Redlamp's effects, with values of its own. Smooth Skin, Whiten Teeth and Pop Eyes are the
    /// adjustments of the mask presets of those names, so a mask one of them made shows it.
    public static let builtIn: [MaskEffect] = [
        MaskEffect(id: "redlamp.effect.dodge", name: "Dodge", adjustments: [.localExposure: 0.35]),
        MaskEffect(id: "redlamp.effect.burn", name: "Burn", adjustments: [.localExposure: -0.35]),
        MaskEffect(id: "redlamp.effect.warm", name: "Warm", adjustments: [.localTemperature: 15]),
        MaskEffect(id: "redlamp.effect.cool", name: "Cool", adjustments: [.localTemperature: -15]),
        MaskEffect(
            id: "redlamp.effect.addDetail", name: "Add Detail", adjustments: [.localTexture: 20, .localClarity: 10],
        ),
        MaskEffect(id: "redlamp.effect.reduceHaze", name: "Reduce Haze", adjustments: [.localDehaze: 20]),
        MaskEffect(
            id: "redlamp.effect.smoothSkin", name: "Smooth Skin", adjustments: [.localTexture: -35, .localClarity: -10],
        ),
        MaskEffect(
            id: "redlamp.effect.whitenTeeth", name: "Whiten Teeth",
            adjustments: [.localExposure: 0.25, .localSaturation: -45],
        ),
        MaskEffect(
            id: "redlamp.effect.popEyes", name: "Pop Eyes",
            adjustments: [.localExposure: 0.3, .localClarity: 20, .localSaturation: 15],
        ),
    ]
}

public extension MaskLayer {
    /// Gives the mask `effect`'s sliders and Curves; a slider the effect doesn't set goes back to
    /// 0, and adjustments a newer Redlamp wrote go with them. Its components, Amount, Detail,
    /// Invert and Point Color stay as they are.
    mutating func apply(_ effect: MaskEffect) {
        let kept = (amount: amount, detail: detail, pointColor: pointColor)
        resetAdjustments()
        amount = kept.amount
        detail = kept.detail
        pointColor = kept.pointColor
        for (parameter, value) in effect.localAdjustments {
            self[parameter] = value
        }
        curves = effect.curves
    }

    /// Whether the mask's sliders and Curves are `effect`'s.
    func has(_ effect: MaskEffect) -> Bool {
        var probe = MaskLayer(name: name, components: [])
        probe.apply(effect)
        return probe.adjustments == adjustments && probe.curves == curves
    }

    /// Whether any slider is off 0 or a curve is bent.
    var isAdjusted: Bool {
        !adjustments.isEmpty || curves != nil
    }
}
