/// A white balance expressed as correlated color temperature and tint.
public struct WhiteBalanceValue: Codable, Sendable, Hashable {
    public var temperature: Double
    public var tint: Double

    public init(temperature: Double, tint: Double) {
        self.temperature = temperature
        self.tint = tint
    }
}

/// The white balance popup, with Lightroom's preset values for raw files.
public enum WhiteBalanceMode: String, Codable, Sendable, Hashable, CaseIterable {
    case asShot
    case auto
    case daylight
    case cloudy
    case shade
    case tungsten
    case fluorescent
    case flash
    case custom

    public var name: String {
        switch self {
        case .asShot: "As Shot"
        case .auto: "Auto"
        case .daylight: "Daylight"
        case .cloudy: "Cloudy"
        case .shade: "Shade"
        case .tungsten: "Tungsten"
        case .fluorescent: "Fluorescent"
        case .flash: "Flash"
        case .custom: "Custom"
        }
    }

    /// Fixed values for the illuminant presets; `nil` for modes computed per image.
    public var presetValue: WhiteBalanceValue? {
        switch self {
        case .daylight: WhiteBalanceValue(temperature: 5500, tint: 10)
        case .cloudy: WhiteBalanceValue(temperature: 6500, tint: 10)
        case .shade: WhiteBalanceValue(temperature: 7500, tint: 10)
        case .tungsten: WhiteBalanceValue(temperature: 2850, tint: 0)
        case .fluorescent: WhiteBalanceValue(temperature: 3800, tint: 21)
        case .flash: WhiteBalanceValue(temperature: 5500, tint: 0)
        case .asShot, .auto, .custom: nil
        }
    }
}
