import AppKit
import RedlampDesign

/// A Library panel's rows as AppKit lays them out (LIB-21, LIB-22): a vertical stack, as tall as its rows at
/// the column's width. Rows hold one line each, so their heights don't depend on the width.
class PanelStackView: NSView, HeightProviding {
    let stack = NSStackView()
    private let width: NSLayoutConstraint

    init(spacing: CGFloat = 6) {
        width = stack.widthAnchor.constraint(equalToConstant: 280)
        super.init(frame: CGRect(x: 0, y: 0, width: 280, height: 60))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            width,
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if self.width.constant != width {
            self.width.constant = width
        }
        return ceil(stack.fittingSize.height)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    override func layout() {
        super.layout()
        if width.constant != bounds.width {
            width.constant = bounds.width
        }
    }

    /// Adds `view` as a row as wide as the panel.
    func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// The rows changed: the column lays the panel out again.
    func rowsChanged() {
        invalidateColumnLayout()
    }
}

@MainActor
enum PanelControls {
    static func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Typography.label.nsFont
        label.textColor = secondary ? Palette.secondaryLabel.nsColor : Palette.value.nsColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func button(_ title: String, identifier: String, action: @escaping @MainActor () -> Void) -> NSButton {
        let button = ActionButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Typography.label.nsFont
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    static func symbolButton(
        _ symbol: String, _ description: String, identifier: String, action: @escaping @MainActor () -> Void,
    ) -> NSButton {
        let button = ActionButton(title: "", action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.isBordered = false
        button.toolTip = description
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(description)
        return button
    }

    /// A row of views side by side, the first one taking the room left.
    static func row(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        row.distribution = .fill
        views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }
}

/// A button that runs a closure.
final class ActionButton: NSButton {
    var onPress: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        onPress = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func pressed() {
        onPress()
    }
}

/// A sheet of labelled fields with Cancel and a default button, over the editor window. Shortcuts stay off
/// while it's up.
@MainActor
final class PanelSheet: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let grid = NSGridView()
    private let model: EditorModel
    private var done: (@MainActor () -> Bool)?
    private static var shown: [PanelSheet] = []

    init(title: String, model: EditorModel) {
        self.model = model
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.title = title
        super.init()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A row: a label and a control, or a control alone across both columns.
    func add(_ label: String?, _ control: NSView) {
        if let label {
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            grid.addRow(with: [text, control])
        } else {
            let row = grid.addRow(with: [NSGridCell.emptyContentView, control])
            row.cell(at: 0).xPlacement = .trailing
        }
    }

    /// Shows the sheet over the editor window; `done` runs on the default button and says whether the sheet
    /// may close. False when there's no window to show it over.
    @discardableResult
    func begin(button: String, first: NSView? = nil, done: @escaping @MainActor () -> Bool) -> Bool {
        guard let parent = EditorWindowController.frontWindow, !model.isModalDialogOpen else { return false }
        self.done = done
        let content = NSView()
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1B}"
        let ok = NSButton(title: button, target: self, action: #selector(confirm))
        ok.keyEquivalent = "\r"
        ok.setAccessibilityIdentifier("panelSheet.ok")
        let buttons = NSStackView(views: [cancel, ok])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = first
        model.isModalDialogOpen = true
        Self.shown.append(self)
        parent.beginSheet(window)
        return true
    }

    @objc private func confirm() {
        guard done?() ?? true else { return }
        close()
    }

    @objc private func cancel() {
        close()
    }

    /// Closes the sheet without its default button.
    func end() {
        close()
    }

    private func close() {
        model.isModalDialogOpen = false
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        Self.shown.removeAll { $0 === self }
    }
}
