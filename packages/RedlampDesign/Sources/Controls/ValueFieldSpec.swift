import Foundation
import RedlampEngineAPI

/// What a value field needs to show, step, scrub and read back a number.
public protocol ValueFieldSpec: Sendable {
    /// The arrow keys' step; Shift multiplies it by ten.
    var step: Double { get }
    func clamp(_ value: Double) -> Double
    func quantize(_ value: Double) -> Double
    func formatted(_ value: Double) -> String
    func parse(_ text: String, current: Double?) -> Double?
    /// The value's place along its range, 0...1, in the scale a drag moves it in.
    func position(for value: Double) -> Double
    func value(atPosition position: Double) -> Double
}

extension ParameterSpec: ValueFieldSpec {}

/// A value field's rules for a number that isn't one of the edit's parameters, such as a
/// brush's size or an overlay's opacity: linear over its range, with `digits` decimals and an
/// optional unit after the number.
public struct FieldSpec: ValueFieldSpec, Hashable {
    public let range: ClosedRange<Double>
    public let step: Double
    public let digits: Int
    public let unit: String

    public init(range: ClosedRange<Double>, step: Double = 1, digits: Int = 0, unit: String = "") {
        self.range = range
        self.step = step
        self.digits = digits
        self.unit = unit
    }

    public func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    public func quantize(_ value: Double) -> Double {
        let scale = pow(10, Double(digits))
        return (clamp(value) * scale).rounded() / scale
    }

    public func formatted(_ value: Double) -> String {
        String(format: "%.\(digits)f", value) + unit
    }

    public func parse(_ text: String, current: Double?) -> Double? {
        ParameterSpec.evaluate(text, current: current).map(clamp)
    }

    public func position(for value: Double) -> Double {
        (clamp(value) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    public func value(atPosition position: Double) -> Double {
        range.lowerBound + min(max(position, 0), 1) * (range.upperBound - range.lowerBound)
    }
}
