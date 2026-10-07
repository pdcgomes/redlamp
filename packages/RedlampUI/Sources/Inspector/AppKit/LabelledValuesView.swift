import AppKit
import RedlampDesign
import RedlampEngineAPI

extension ValueFieldView {
    /// A field that edits `parameter` as its slider would: a scrub is one History step, a typed
    /// value another. Its owner keeps `value` in step with the model.
    static func editing(_ parameter: ParameterID, in model: EditorModel) -> ValueFieldView {
        let field = ValueFieldView(spec: parameter.spec, value: model.value(parameter))
        field.setAccessibilityIdentifier("slider.\(parameter.rawValue).value")
        field.onBegin = { model.beginEdit(parameter) }
        field.onChange = { model.setValue(parameter, $0) }
        field.onEnd = { model.endEdit() }
        field.onCommit = { model.setValue(parameter, $0) }
        return field
    }
}

/// A row of labelled numbers, each label before its value field, sharing the row's width
/// equally (`H 210   S 35`), after an optional title in the panels' label column. With a
/// hint, the row shows that instead of its fields.
final class LabelledValuesView: LayerDrawnView {
    let fields: [ValueFieldView]
    private let labels: [String]
    private let title: String?

    var hint: String? {
        didSet {
            if hint != oldValue {
                fields.forEach { $0.isHidden = hint != nil }
                setNeedsContentDisplay()
            }
        }
    }

    init(title: String? = nil, _ items: [(label: String, field: ValueFieldView)]) {
        self.title = title
        labels = items.map(\.label)
        fields = items.map(\.field)
        super.init(frame: .zero)
        for field in fields {
            field.trailingInset = ValueFieldView.wellPadding
            addSubview(field)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Metrics.rowHeight)
    }

    private var columns: [CGRect] {
        let start = title == nil ? 0 : Metrics.labelWidth + Metrics.rowSpacing
        let width = max(bounds.width - start, 0) / CGFloat(max(fields.count, 1))
        return fields.indices.map { CGRect(x: start + CGFloat($0) * width, y: 0, width: width, height: bounds.height) }
    }

    override func drawContent(in _: CGRect) {
        if let hint {
            TextLine.draw(
                hint, font: Typography.caption, color: Palette.secondaryLabel.nsColor,
                in: bounds, alignment: .center, scale: backingScale,
            )
            return
        }
        if let title {
            TextLine.draw(
                title, font: Typography.label, color: Palette.label.nsColor,
                in: CGRect(x: 0, y: 0, width: Metrics.labelWidth, height: bounds.height), scale: backingScale,
            )
        }
        for (label, column) in zip(labels, columns) where !label.isEmpty {
            TextLine.draw(label, font: Typography.label, color: Palette.label.nsColor, in: column, scale: backingScale)
        }
    }

    override func layout() {
        super.layout()
        for (index, column) in columns.enumerated() {
            let labelWidth = labels[index].isEmpty ? 0 : TextLine.width(labels[index], font: Typography.label) + 2
            let width = min(Metrics.valueWidth, column.width - labelWidth) + ValueFieldView.wellPadding
            fields[index].frame = CGRect(
                x: column.maxX - width + ValueFieldView.wellPadding, y: 0, width: width, height: bounds.height,
            )
        }
    }
}
