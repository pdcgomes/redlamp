import AppKit
import RedlampDesign
import SwiftUI

/// The panels' value field for SwiftUI-hosted controls, the same view as a slider row's:
/// drag it to scrub, click it to type.
struct ValueFieldControl: NSViewRepresentable {
    let spec: any ValueFieldSpec
    let value: Double
    var identifier: String?
    var onBegin: () -> Void = {}
    var onChange: (Double) -> Void
    var onEnd: () -> Void = {}
    /// A typed or stepped value, which comes without `onBegin` and `onEnd`; `onChange` when nil.
    var onCommit: ((Double) -> Void)?

    /// The width a field needs for `widest` and its well.
    static func width(for widest: String) -> CGFloat {
        TextLine.width(widest, font: Typography.value) + 2 * ValueFieldView.wellPadding
    }

    func makeNSView(context _: Context) -> ValueFieldView {
        let field = ValueFieldView(spec: spec, value: value)
        field.trailingInset = ValueFieldView.wellPadding
        if let identifier {
            field.setAccessibilityIdentifier(identifier)
        }
        return field
    }

    func updateNSView(_ field: ValueFieldView, context: Context) {
        field.spec = spec
        field.value = value
        field.isEnabled = context.environment.isEnabled
        field.onBegin = onBegin
        field.onChange = onChange
        field.onEnd = onEnd
        field.onCommit = onCommit ?? onChange
    }
}
