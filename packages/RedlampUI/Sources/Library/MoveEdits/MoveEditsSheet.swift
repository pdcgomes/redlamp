import AppKit
import RedlampLibrary

/// Move Edits and Metadata… (LIB-11, DEC-43), a sheet on the editor window: where a root keeps its edits and metadata
/// and where they'd go, how many of its photos have them, what moving does, and why it can't when it can't; then the
/// move's progress, with Cancel putting back what it moved, and its outcome when there's something to say. It closes
/// once a move goes through or is put back.
@MainActor
final class MoveEditsSheetController: NSViewController {
    /// The sheet on screen, for the regression suite.
    private(set) weak static var current: MoveEditsSheetController?

    let model: MoveEditsModel
    private weak var editor: EditorModel?
    private let heading = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let kept = NSTextField(labelWithString: "")
    private let goingTo = NSTextField(labelWithString: "")
    private let what = MoveEditsSheetController.note("")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let move = NSButton(title: "Move", target: nil, action: nil)
    /// When the sheet went up, after the command that asked for it, for the regression suite.
    private(set) var shown: ContinuousClock.Instant?
    private let requested: ContinuousClock.Instant

    static let width: CGFloat = 520

    init(model: MoveEditsModel, editor: EditorModel, requested: ContinuousClock.Instant) {
        self.model = model
        self.editor = editor
        self.requested = requested
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the sheet on the editor window, with the editor's other commands held while it's up.
    @discardableResult
    static func present(
        _ model: MoveEditsModel, editor: EditorModel, requested: ContinuousClock.Instant = .now,
    ) -> MoveEditsSheetController? {
        guard let window = EditorWindowController.frontWindow, window.attachedSheet == nil else { return nil }
        let controller = MoveEditsSheetController(model: model, editor: editor, requested: requested)
        let sheet = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        sheet.title = "Move Edits and Metadata"
        sheet.contentViewController = controller
        editor.isModalDialogOpen = true
        current = controller
        window.beginSheet(sheet)
        return controller
    }

    override func loadView() {
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingMiddle
        count.setAccessibilityIdentifier("moveEdits.count")
        kept.setAccessibilityIdentifier("moveEdits.kept")
        goingTo.setAccessibilityIdentifier("moveEdits.destination")
        let grid = NSGridView(views: [
            [Self.label("Kept now"), kept],
            [Self.label("Moving to"), goingTo],
        ])
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let how = Self.note(MoveEditsModel.how)

        status.font = .systemFont(ofSize: 11)
        status.setAccessibilityIdentifier("moveEdits.status")
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.setAccessibilityIdentifier("moveEdits.progress")

        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("moveEdits.cancel")
        move.target = self
        move.action = #selector(moveClicked)
        move.keyEquivalent = "\r"
        move.setAccessibilityIdentifier("moveEdits.move")
        let buttons = NSStackView(views: [NSView(), cancel, move])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, count, grid, how, what, status, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: heading)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for view in [heading, count, how, what, status, progress, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
        model.onChange = { [weak self] in self?.update() }
        update()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        shown = shown ?? .now
        if case .checking = model.phase, let sidecars = editor?.library.service?.core?.sidecars {
            Task { await model.check(sidecars) }
        }
    }

    /// The time from the command to the sheet on screen, its numbers in it.
    var shownAfter: Duration? {
        shown.map { $0 - requested }
    }

    static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Sets only what changed: the progress comes ten times a second while the sheet's wrapping labels would be laid
    /// out again for each.
    private func update() {
        for (field, text) in [
            (heading, model.heading), (count, model.count), (kept, model.kept), (goingTo, model.goingTo),
            (what, model.what), (status, model.status),
        ] where field.stringValue != text {
            field.stringValue = text
        }
        let color: NSColor = model.statusIsProblem ? .systemRed : .secondaryLabelColor
        if status.textColor != color {
            status.textColor = color
        }
        if status.isHidden != model.status.isEmpty {
            status.isHidden = model.status.isEmpty
        }
        if case let .moving(shown) = model.phase, shown.total > 0 {
            progress.isHidden = false
            progress.doubleValue = Double(shown.done) / Double(shown.total)
        } else {
            progress.isHidden = !model.isMoving
            progress.doubleValue = 0
        }
        let title = model.isOver ? "Close" : "Cancel"
        if cancel.title != title {
            cancel.title = title
        }
        cancel.isEnabled = !(model.isPuttingBack || model.control.isCancelled)
        move.isHidden = model.isOver
        move.isEnabled = model.canMove
    }

    @objc private func cancelClicked() {
        guard cancel.isEnabled else { return }
        if model.isMoving {
            model.cancel()
        } else {
            close()
        }
    }

    @objc private func moveClicked() {
        guard move.isEnabled, let editor else { return }
        Task {
            if await editor.moveEdits(model) {
                close()
            }
        }
    }

    /// Runs the move a quit interrupted, from the sheet's start.
    func finishUnfinished() {
        guard let editor else { return }
        Task {
            if await editor.moveEdits(model) {
                close()
            }
        }
    }

    func close() {
        guard let sheet = view.window else { return }
        editor?.isModalDialogOpen = false
        sheet.sheetParent?.endSheet(sheet)
        if Self.current === self {
            Self.current = nil
        }
    }
}

/// What Move Edits and Metadata's sheet shows, for the regression suite.
@_spi(Harness) public struct MoveEditsSheetState: Sendable, Equatable {
    public var heading: String
    public var count: String
    public var kept: String
    public var goingTo: String
    public var status: String
    public var canMove: Bool
    public var isMoving: Bool
    public var isOver: Bool
    /// The disk has been looked through: the count is the disk's.
    public var isChecked: Bool
    /// From the command to the sheet on screen with its numbers, and to its numbers read from the index.
    public var shownAfter: Duration?
    public var surveyedAfter: Duration?
}

@_spi(Harness) public extension EditorModel {
    /// Move Edits and Metadata's sheet, while it's up.
    var moveEditsSheet: MoveEditsSheetState? {
        guard let controller = MoveEditsSheetController.current else { return nil }
        let model = controller.model
        return MoveEditsSheetState(
            heading: model.heading, count: model.count, kept: model.kept, goingTo: model.goingTo,
            status: model.status, canMove: model.canMove, isMoving: model.isMoving, isOver: model.isOver,
            isChecked: model.plan != nil, shownAfter: controller.shownAfter, surveyedAfter: model.surveyed,
        )
    }
}
