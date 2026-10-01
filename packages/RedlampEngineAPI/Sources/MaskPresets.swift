import Foundation

/// A mask that can be applied to any photo, like Lightroom's mask and adaptive presets: its
/// adjustments, plus components that are either fixed shapes (gradients, ranges) or AI masks
/// computed again for each photo it is applied to.
public struct MaskPreset: Codable, Sendable, Hashable, Identifiable {
    public enum Component: Codable, Sendable, Hashable {
        /// A shape kept as it is.
        case shape(MaskShape, MaskOperation, inverted: Bool)
        /// An AI mask, computed for the photo.
        case ai(kind: MaskKind, part: PersonPart, MaskOperation, inverted: Bool)
    }

    public var id: String
    public var name: String
    public var components: [Component]
    public var amount: Double
    public var detail: Double
    public var adjustments: [String: Double]

    public init(
        id: String = UUID().uuidString, name: String, components: [Component], amount: Double = 100, detail: Double = 0,
        adjustments: [ParameterID: Double],
    ) {
        self.id = id
        self.name = name
        self.components = components
        self.amount = amount
        self.detail = detail
        self.adjustments = Dictionary(uniqueKeysWithValues: adjustments.map { ($0.key.rawValue, $0.value) })
    }

    /// A preset of `mask`: AI components become requests, everything but brush strokes (which
    /// belong to one photo) is kept.
    public init(_ mask: MaskLayer, name: String) {
        let components: [Component] = mask.components.compactMap { component in
            switch component.shape {
            case let .ai(ai):
                .ai(
                    kind: ai.kind, part: ai.part.flatMap(PersonPart.init(rawValue:)) ?? .entirePerson,
                    component.operation, inverted: component.inverted,
                )
            case .depthRange:
                .ai(kind: .depthRange, part: .entirePerson, component.operation, inverted: component.inverted)
            case .brush, .maskReference, .unknown:
                nil
            default:
                .shape(component.shape, component.operation, inverted: component.inverted)
            }
        }
        self.init(
            name: name, components: components, amount: mask.amount, detail: mask.detail,
            adjustments: mask.adjustments,
        )
    }

    public var localAdjustments: [ParameterID: Double] {
        Dictionary(uniqueKeysWithValues: adjustments.compactMap { key, value in
            ParameterID(rawValue: key).map { ($0, value) }
        })
    }

    /// The AI masks it computes when applied.
    public var aiKinds: [MaskKind] {
        components.compactMap {
            if case let .ai(kind, _, _, _) = $0 {
                kind
            } else {
                nil
            }
        }
    }

    /// Adaptive presets in the spirit of Lightroom's: each recomputes its mask for the photo.
    public static let builtIn: [MaskPreset] = [
        MaskPreset(
            id: "redlamp.blueSky", name: "Blue Sky",
            components: [.ai(kind: .sky, part: .entirePerson, .add, inverted: false)],
            adjustments: [.localTemperature: -12, .localExposure: -0.3, .localHighlights: -25, .localSaturation: 15],
        ),
        MaskPreset(
            id: "redlamp.brightenSubject", name: "Brighten Subject",
            components: [.ai(kind: .subject, part: .entirePerson, .add, inverted: false)],
            adjustments: [.localExposure: 0.35, .localShadows: 15, .localClarity: 8],
        ),
        MaskPreset(
            id: "redlamp.darkenBackground", name: "Darken Background",
            components: [.ai(kind: .background, part: .entirePerson, .add, inverted: false)],
            adjustments: [.localExposure: -0.5, .localSaturation: -15],
        ),
        MaskPreset(
            id: "redlamp.smoothSkin", name: "Smooth Skin",
            components: [.ai(kind: .people, part: .faceSkin, .add, inverted: false)],
            adjustments: [.localTexture: -35, .localClarity: -10],
        ),
        MaskPreset(
            id: "redlamp.whitenTeeth", name: "Whiten Teeth",
            components: [.ai(kind: .people, part: .teeth, .add, inverted: false)],
            adjustments: [.localExposure: 0.25, .localSaturation: -45],
        ),
        MaskPreset(
            id: "redlamp.popEyes", name: "Pop Eyes",
            components: [.ai(kind: .people, part: .iris, .add, inverted: false)],
            adjustments: [.localExposure: 0.3, .localClarity: 20, .localSaturation: 15],
        ),
    ]
}
