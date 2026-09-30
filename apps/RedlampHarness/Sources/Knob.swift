import SwiftUI

/// A labelled slider with a monospaced readout, for tuning values in a scene's inspector.
struct Knob<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    var step: Value.Stride?

    init(_ title: String, _ value: Binding<Value>, _ range: ClosedRange<Value>, step: Value.Stride? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.3f", Double(value)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}
