import Foundation

/// How a report starts when it comes from a message on screen ("Report This Problem…").
public struct FeedbackPrefill: Sendable, Hashable {
    public var kind: FeedbackReport.Kind
    public var featureID: String?
    /// The message, quoted at the start of "What happened".
    public var message: String?

    public init(kind: FeedbackReport.Kind = .bug, featureID: String? = nil, message: String? = nil) {
        self.kind = kind
        self.featureID = featureID
        self.message = message
    }
}

/// The Report a Bug or Send Feedback sheet: the note asking people to be kind, the report
/// being written (kept as a draft until it's sent), what goes with it, and sending.
@MainActor
@Observable
public final class FeedbackSheetModel {
    public enum Phase: Equatable {
        case note
        case form
        case sending
        case sent(FeedbackResult)
        /// Kept in the outbox until redlamp.app can be reached.
        case queued
    }

    public var phase: Phase
    public var report: FeedbackReport {
        didSet { saveDraft() }
    }

    public let context: FeedbackContext
    public let system: SystemSnapshot
    public var log: [String] = []
    /// Redlamp's window as it was when the sheet opened; sent only when asked.
    public let windowShot: FeedbackReport.Screenshot?
    public var includesWindowShot = false
    public var error: String?
    /// The last send couldn't reach redlamp.app, so the report can wait in the outbox.
    public private(set) var unreachable = false
    public private(set) var restoredDraft = false
    public let dryRun: Bool
    private let sender: any FeedbackSending
    @ObservationIgnored private let defaults: UserDefaults
    /// Called with what was sent and what the relay did, for Your Reports.
    @ObservationIgnored public var onSent: ((FeedbackReport, FeedbackResult) -> Void)?
    /// Puts a report in the outbox.
    @ObservationIgnored public var onQueue: ((FeedbackSubmission) -> Void)?

    /// Raise it when the note's words change, so everyone reads them again.
    static let noteVersion = 1
    static let noteKey = "feedback.noteAccepted"
    static let draftKey = "feedback.draft"

    public init(
        context: FeedbackContext, system: SystemSnapshot, windowShot: FeedbackReport.Screenshot?,
        prefill: FeedbackPrefill? = nil, sender: any FeedbackSending, dryRun: Bool, defaults: UserDefaults = .standard,
    ) {
        self.context = context
        self.system = system
        self.windowShot = windowShot
        self.sender = sender
        self.dryRun = dryRun
        self.defaults = defaults
        var report = FeedbackReport()
        if let prefill {
            report.kind = prefill.kind
            report.featureID = prefill.featureID ?? context.suggestion
            report.body = prefill.message.map { "Redlamp said: “\($0)”\n\n" } ?? ""
        } else if let draft = Self.draft(in: defaults) {
            report = draft
            restoredDraft = true
        } else {
            report.featureID = context.suggestion
        }
        if context.photo == nil {
            report.details.photo = false
        }
        self.report = report
        phase = defaults.integer(forKey: Self.noteKey) >= Self.noteVersion ? .form : .note
    }

    public var isSuggested: Bool {
        report.featureID != nil && report.featureID == context.suggestion
    }

    /// The photo, the activity and the log together: whether the report is about what the
    /// person was doing just now.
    public var aboutSession: Bool {
        get { report.details.photo || report.details.activity || report.details.log }
        set {
            report.details.photo = newValue && context.photo != nil
            report.details.activity = newValue
            report.details.log = newValue
        }
    }

    public var screenshots: [FeedbackReport.Screenshot] {
        (includesWindowShot ? windowShot.map { [$0] } ?? [] : []) + report.screenshots
    }

    public var canAddScreenshot: Bool {
        screenshots.count < FeedbackReport.screenshotLimit
    }

    public func add(_ screenshot: FeedbackReport.Screenshot) {
        guard canAddScreenshot else { return }
        report.screenshots.append(screenshot)
    }

    public func removeScreenshot(_ id: UUID) {
        if id == windowShot?.id {
            includesWindowShot = false
        } else {
            report.screenshots.removeAll { $0.id == id }
        }
    }

    /// The report as it will be sent, the window's screenshot first.
    public var outgoing: FeedbackReport {
        var report = report
        report.screenshots = Array(screenshots.prefix(FeedbackReport.screenshotLimit))
        return report
    }

    public var canSend: Bool {
        report.isComplete && report.topic != nil && phase == .form
    }

    public var previewBody: String {
        outgoing.issueBody(context: context, system: system, log: log)
    }

    public func acceptNote() {
        defaults.set(Self.noteVersion, forKey: Self.noteKey)
        phase = .form
    }

    /// The last things the person did, as numbered steps they can edit.
    public func insertRecentSteps() {
        let since = context.captured.addingTimeInterval(-FeedbackReport.activityWindow)
        let events = context.activity
            .filter { $0.time >= since && $0.kind != .system && $0.kind != .message }
            .suffix(12)
        guard !events.isEmpty else { return }
        let steps = events.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        report.steps = report.steps.isEmpty ? steps : report.steps + "\n" + steps
    }

    public func startOver() {
        var fresh = FeedbackReport()
        fresh.featureID = context.suggestion
        fresh.details.photo = context.photo != nil
        report = fresh
        includesWindowShot = false
        restoredDraft = false
        defaults.removeObject(forKey: Self.draftKey)
    }

    public func send() async {
        guard canSend else { return }
        error = nil
        unreachable = false
        phase = .sending
        let outgoing = outgoing
        do {
            let submission = try outgoing.submission(context: context, system: system, log: log, dryRun: dryRun)
            let result = try await sender.send(submission)
            if case .filed = result {
                defaults.removeObject(forKey: Self.draftKey)
            }
            onSent?(outgoing, result)
            phase = .sent(result)
        } catch {
            self.error = error.localizedDescription
            if case .unreachable = error as? FeedbackError {
                unreachable = true
            }
            phase = .form
        }
    }

    /// The report as the relay would get it, for the outbox, a file or GitHub's own page.
    public func submission() throws -> FeedbackSubmission {
        try outgoing.submission(context: context, system: system, log: log, dryRun: false)
    }

    /// Keeps the report until Redlamp can reach redlamp.app; the draft is done with.
    public func queue() {
        guard let submission = try? submission(), let onQueue else { return }
        onQueue(submission)
        defaults.removeObject(forKey: Self.draftKey)
        phase = .queued
    }

    private func saveDraft() {
        var draft = report
        draft.screenshots = []
        defaults.set(try? JSONEncoder().encode(draft), forKey: Self.draftKey)
    }

    private static func draft(in defaults: UserDefaults) -> FeedbackReport? {
        guard let data = defaults.data(forKey: draftKey),
              let draft = try? JSONDecoder().decode(FeedbackReport.self, from: data),
              !(draft.title + draft.body + draft.expected + draft.steps).trimmingCharacters(in: .whitespacesAndNewlines)
              .isEmpty
        else { return nil }
        return draft
    }
}
