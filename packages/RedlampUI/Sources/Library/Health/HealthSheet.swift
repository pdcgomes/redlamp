import AppKit
import RedlampLibrary

/// What Library Health's sheet shows (LIB-40): the batch that carries out the check's proposals, planned off the main
/// thread as the sheet comes up, in words: how many photos and what happens to them, what stays, and how to take it
/// back; the selected photos the check lists apart, which only a tick puts in it; then the batch's progress, or why
/// nothing was done.
@MainActor
final class HealthSheetModel {
    enum Phase {
        case planning
        case ready
        case running(done: Int, total: Int)
        case failed(String)
    }

    let findings: HealthFindings
    /// The photos selected that the check lists apart, which the batch takes only when `includesSelected` is ticked.
    let selectedApart: [Int64]
    private(set) var includesSelected = false
    private(set) var phase = Phase.planning
    private(set) var plan: HealthPlan?
    var onChange: (() -> Void)?
    private var planning: Task<Void, Never>?
    private let health: LibraryHealth
    /// From the sheet asked for to its plan in it, for the budgets.
    private(set) var planned: Duration?
    private let requested: ContinuousClock.Instant

    init(
        findings: HealthFindings, selectedApart: [Int64], health: LibraryHealth,
        requested: ContinuousClock.Instant = .now,
    ) {
        self.findings = findings
        self.selectedApart = selectedApart
        self.health = health
        self.requested = requested
    }

    var check: HealthCheck {
        findings.check
    }

    /// The photos the user chose beyond the proposals.
    var chosen: Set<Int64> {
        includesSelected ? Set(selectedApart) : []
    }

    /// Plans the batch for the proposals and the photos chosen, off the main thread.
    func makePlan() {
        planning?.cancel()
        plan = nil
        phase = .planning
        onChange?()
        let (health, findings, chosen) = (health, findings, chosen)
        planning = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<HealthPlan, any Error> in
                do {
                    return try await .success(health.plan(findings, choosing: chosen))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case let .success(made):
                plan = made
                phase = .ready
            case let .failure(error):
                phase = .failed(HealthWords.failure(error))
            }
            planned = planned ?? .now - requested
            onChange?()
        }
    }

    func setIncludesSelected(_ includes: Bool) {
        guard includes != includesSelected else { return }
        includesSelected = includes
        makePlan()
    }

    func running(done: Int, total: Int) {
        phase = .running(done: done, total: total)
        onChange?()
    }

    func failed(_ message: String) {
        phase = .failed(message)
        onChange?()
    }

    // MARK: - Words

    /// The photos the batch acts on, as planned; until then, the proposals and the photos chosen.
    var count: Int {
        plan?.photos.count ?? findings.proposed.count + chosen.count
    }

    var heading: String {
        HealthWords.question(check, count: count, kinds: kinds)
    }

    var countLine: String {
        guard let plan else { return "" }
        let groups = Set(plan.findings.compactMap(\.group)).count
        return HealthWords.count(check, count: plan.photos.count, groups: groups, bytes: plan.bytes)
    }

    var what: String {
        HealthWords.what(check)
    }

    var undo: String {
        HealthWords.undo(check)
    }

    var leftOut: String {
        HealthWords.leftOut(findings, choosing: chosen)
    }

    var choice: String {
        HealthWords.choice(check, count: selectedApart.count)
    }

    var actionTitle: String {
        HealthWords.action(check)
    }

    var status: String {
        switch phase {
        case .planning: HealthWords.planning(check)
        case .ready: plan?.batch.steps.isEmpty == true ? "Nothing to do: every photo the check found stays." : ""
        case let .running(done, total): HealthWords.progress(check, done: done, total: total)
        case let .failed(message): message
        }
    }

    var statusIsProblem: Bool {
        if case .failed = phase {
            return true
        }
        return false
    }

    var isRunning: Bool {
        if case .running = phase {
            return true
        }
        return false
    }

    var canAccept: Bool {
        if case .ready = phase {
            return plan?.batch.steps.isEmpty == false
        }
        return false
    }

    /// The kinds of the pairs' halves the batch moves, for the words.
    private var kinds: Set<PhotoRecord.Kind> {
        let acted = plan?.findings ?? findings.findings.filter { $0.isProposed || chosen.contains($0.photo) }
        return Set(acted.compactMap { finding in
            guard case let .pairHalf(kind, _) = finding.reason else { return nil }
            return kind
        })
    }
}

/// Library Health's sheet on the editor window, with the editor's other commands held while it's up; it closes once
/// the batch goes through, or on Cancel.
@MainActor
final class HealthSheetController: NSViewController {
    /// The sheet on screen, for the regression suite.
    private(set) weak static var current: HealthSheetController?

    let model: HealthSheetModel
    private weak var editor: EditorModel?
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let what = HealthSheetController.note("")
    private let undo = HealthSheetController.note("")
    private let leftOut = HealthSheetController.note("")
    private let choice = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let accept = NSButton(title: "", target: nil, action: nil)
    /// When the sheet went up, for the regression suite.
    private(set) var shown: ContinuousClock.Instant?
    private let requested: ContinuousClock.Instant

    static let width: CGFloat = 480

    init(model: HealthSheetModel, editor: EditorModel, requested: ContinuousClock.Instant) {
        self.model = model
        self.editor = editor
        self.requested = requested
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the sheet on the editor window and starts planning its batch.
    @discardableResult
    static func present(
        _ model: HealthSheetModel, editor: EditorModel, requested: ContinuousClock.Instant = .now,
    ) -> HealthSheetController? {
        guard let window = EditorWindowController.frontWindow, window.attachedSheet == nil else { return nil }
        let controller = HealthSheetController(model: model, editor: editor, requested: requested)
        let sheet = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 260), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        sheet.title = "Library Health"
        sheet.contentViewController = controller
        editor.isModalDialogOpen = true
        current = controller
        window.beginSheet(sheet)
        model.makePlan()
        return controller
    }

    override func loadView() {
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.setAccessibilityIdentifier("health.heading")
        count.textColor = .secondaryLabelColor
        count.setAccessibilityIdentifier("health.count")
        what.setAccessibilityIdentifier("health.what")
        undo.setAccessibilityIdentifier("health.undo")
        leftOut.setAccessibilityIdentifier("health.leftOut")
        choice.target = self
        choice.action = #selector(choiceClicked)
        choice.setAccessibilityIdentifier("health.choice")
        status.font = .systemFont(ofSize: 11)
        status.setAccessibilityIdentifier("health.status")
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.setAccessibilityIdentifier("health.progress")
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("health.cancel")
        accept.target = self
        accept.action = #selector(acceptClicked)
        accept.keyEquivalent = "\r"
        accept.title = model.actionTitle
        accept.setAccessibilityIdentifier("health.accept")
        let buttons = NSStackView(views: [NSView(), cancel, accept])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, count, what, undo, leftOut, choice, status, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: heading)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for view in [heading, count, what, undo, leftOut, status, progress, buttons] as [NSView] {
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
    }

    /// The time from the command to the sheet on screen.
    var shownAfter: Duration? {
        shown.map { $0 - requested }
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
            (heading, model.heading), (count, model.countLine), (what, model.what), (undo, model.undo),
            (leftOut, model.leftOut), (status, model.status),
        ] where field.stringValue != text {
            field.stringValue = text
        }
        for (field, hidden) in [(count, model.countLine.isEmpty), (leftOut, model.leftOut.isEmpty)]
            where field.isHidden != hidden {
            field.isHidden = hidden
        }
        if choice.title != model.choice {
            choice.title = model.choice
        }
        choice.isHidden = model.selectedApart.isEmpty
        choice.state = model.includesSelected ? .on : .off
        choice.isEnabled = !model.isRunning
        let color: NSColor = model.statusIsProblem ? .systemRed : .secondaryLabelColor
        if status.textColor != color {
            status.textColor = color
        }
        if status.isHidden != model.status.isEmpty {
            status.isHidden = model.status.isEmpty
        }
        if case let .running(done, total) = model.phase, total > 0 {
            progress.isHidden = false
            progress.doubleValue = Double(done) / Double(total)
        } else {
            progress.isHidden = true
        }
        cancel.isEnabled = !model.isRunning
        accept.isEnabled = model.canAccept
    }

    @objc private func choiceClicked() {
        model.setIncludesSelected(choice.state == .on)
    }

    @objc private func cancelClicked() {
        guard cancel.isEnabled else { return }
        close()
    }

    @objc private func acceptClicked() {
        guard accept.isEnabled, let editor else { return }
        Task {
            if await editor.acceptHealthPlan(model) {
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

/// What Library Health's sheet shows, for the regression suite.
@_spi(Harness) public struct HealthSheetState: Sendable, Equatable {
    public var heading: String
    public var count: String
    public var what: String
    public var undo: String
    public var leftOut: String
    public var choice: String?
    public var status: String
    public var canAccept: Bool
    public var isRunning: Bool
    /// From the command to the sheet on screen, and to its plan in it.
    public var shownAfter: Duration?
    public var plannedAfter: Duration?
}

@_spi(Harness) public extension EditorModel {
    /// Library Health's sheet, while it's up.
    var healthSheet: HealthSheetState? {
        guard let controller = HealthSheetController.current else { return nil }
        let model = controller.model
        return HealthSheetState(
            heading: model.heading, count: model.countLine, what: model.what, undo: model.undo,
            leftOut: model.leftOut, choice: model.selectedApart.isEmpty ? nil : model.choice, status: model.status,
            canAccept: model.canAccept, isRunning: model.isRunning, shownAfter: controller.shownAfter,
            plannedAfter: model.planned,
        )
    }

    /// Ticks or clears the sheet's choice of the photos selected that the check lists apart.
    func chooseSelectedInHealthSheet(_ includes: Bool) {
        HealthSheetController.current?.model.setIncludesSelected(includes)
    }
}
