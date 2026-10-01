import Foundation
import RedlampEngineAPI

/// Lightroom's three brushes: A and B to paint, and Erase.
public enum BrushChoice: String, CaseIterable, Codable, Sendable {
    case a = "A"
    case b = "B"
    case erase = "Erase"
}

/// One brush's settings, in Lightroom's units (all 0...100).
public struct BrushSettings: Codable, Hashable, Sendable {
    public var size: Double
    public var feather: Double
    public var flow: Double
    public var density: Double
    public var autoMask: Bool

    public init(
        size: Double = 25,
        feather: Double = 50,
        flow: Double = 100,
        density: Double = 100,
        autoMask: Bool = false,
    ) {
        self.size = size
        self.feather = feather
        self.flow = flow
        self.density = density
        self.autoMask = autoMask
    }

    /// The brush radius as a fraction of the image height: from a few pixels to a third of it,
    /// finer at the small end where precision matters.
    public var radius: Double {
        0.003 + 0.3 * pow(min(max(size, 1), 100) / 100, 2)
    }

    public subscript(parameter: ParameterID) -> Double {
        get {
            switch parameter {
            case .maskBrushSize: size
            case .maskBrushFeather: feather
            case .maskBrushFlow: flow
            case .maskBrushDensity: density
            default: parameter.spec.defaultValue
            }
        }
        set {
            let value = parameter.spec.clamp(newValue)
            switch parameter {
            case .maskBrushSize: size = value
            case .maskBrushFeather: feather = value
            case .maskBrushFlow: flow = value
            case .maskBrushDensity: density = value
            default: break
            }
        }
    }
}

/// The three brushes' settings, kept across launches like Lightroom's.
public struct BrushSettingsSet: Codable, Hashable, Sendable {
    public var a = BrushSettings()
    public var b = BrushSettings(size: 8, feather: 20)
    public var erase = BrushSettings(size: 15, feather: 50)

    public init() {}

    public subscript(choice: BrushChoice) -> BrushSettings {
        get {
            switch choice {
            case .a: a
            case .b: b
            case .erase: erase
            }
        }
        set {
            switch choice {
            case .a: a = newValue
            case .b: b = newValue
            case .erase: erase = newValue
            }
        }
    }

    private static let defaultsKey = "app.redlamp.brushes"

    static func saved(in defaults: UserDefaults = .standard) -> BrushSettingsSet {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(BrushSettingsSet.self, from: $0) }
            ?? BrushSettingsSet()
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
