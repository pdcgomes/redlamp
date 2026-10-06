import AppKit
import SwiftUI

/// A system font, described once and resolved identically for SwiftUI and AppKit.
public struct FontSpec: Sendable, Hashable {
    public enum Weight: Sendable, Hashable {
        case regular, medium, semibold, bold

        public var nsWeight: NSFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }

        var swiftUIWeight: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    public var size: CGFloat
    public var weight: Weight
    public var monospacedDigits: Bool
    /// Extra letter spacing, in points (SwiftUI's `tracking`).
    public var tracking: CGFloat

    public init(size: CGFloat, weight: Weight = .regular, monospacedDigits: Bool = false, tracking: CGFloat = 0) {
        self.size = size
        self.weight = weight
        self.monospacedDigits = monospacedDigits
        self.tracking = tracking
    }

    public func weight(_ weight: Weight) -> FontSpec {
        var copy = self
        copy.weight = weight
        return copy
    }

    public var font: Font {
        let font = Font.system(size: size, weight: weight.swiftUIWeight)
        return monospacedDigits ? font.monospacedDigit() : font
    }

    public var nsFont: NSFont {
        monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight.nsWeight)
            : .systemFont(ofSize: size, weight: weight.nsWeight)
    }
}

public enum Typography {
    public static let label = FontSpec(size: 11)
    public static let value = FontSpec(size: 11, monospacedDigits: true)
    public static let panelTitle = FontSpec(size: 11.5, weight: .semibold)
    public static let section = FontSpec(size: 10, weight: .semibold, tracking: 0.6)
    public static let caption = FontSpec(size: 10)
    public static let badge = FontSpec(size: 9, weight: .medium)
}
