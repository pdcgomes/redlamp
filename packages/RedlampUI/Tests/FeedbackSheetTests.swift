import Foundation
import Testing
@testable import RedlampUI

/// The sheet: the note shown once, the draft kept until it's sent, what goes with a report,
/// and what happens when it's sent.
@MainActor
struct FeedbackSheetTests {
    private final class Relay: FeedbackSending, @unchecked Sendable {
        var result: Result<FeedbackResult, FeedbackError> = .success(.filed(
            number: 42,
            url: URL(string: "https://github.com/pdcgomes/redlamp/issues/42")!,
        ))
        var sent: [FeedbackSubmission] = []

        func send(_ submission: FeedbackSubmission) async throws -> FeedbackResult {
            sent.append(submission)
            return try result.get()
        }
    }

    private let defaults = UserDefaults(suiteName: "FeedbackSheetTests-\(UUID().uuidString)")!

    private func sheet(
        context: FeedbackContext = FeedbackReportTests.context(), prefill: FeedbackPrefill? = nil,
        relay: Relay = Relay(),
        windowShot: FeedbackReport.Screenshot? = nil,
    ) -> FeedbackSheetModel {
        FeedbackSheetModel(
            context: context, system: FeedbackReportTests.system, windowShot: windowShot, prefill: prefill,
            sender: relay, dryRun: false, defaults: defaults,
        )
    }

    private func shot(_ source: String) -> FeedbackReport.Screenshot {
        FeedbackReport.Screenshot(jpeg: Data([0xFF, 0xD8]), width: 10, height: 10, source: source)
    }

    private func fill(_ sheet: FeedbackSheetModel) {
        sheet.report.title = "Objects drop"
        sheet.report.body = "The first object goes."
    }

    @Test func `the note shows until it's read, and again when its words change`() {
        let first = sheet()
        #expect(first.phase == .note)
        first.acceptNote()
        #expect(first.phase == .form)
        #expect(sheet().phase == .form)
        defaults.set(FeedbackSheetModel.noteVersion - 1, forKey: FeedbackSheetModel.noteKey)
        #expect(sheet().phase == .note)
    }

    @Test func `a new report starts at the suggested area, and a message's report at its own`() {
        #expect(sheet().report.featureID == "masking.objects")
        #expect(sheet().isSuggested)
        let prefilled = sheet(prefill: FeedbackPrefill(featureID: "saving.not-saved", message: "Disk full"))
        #expect(prefilled.report.featureID == "saving.not-saved")
        #expect(prefilled.report.body.hasPrefix("Redlamp said: “Disk full”"))
        #expect(!prefilled.isSuggested)
    }

    @Test func `an unsent report comes back, until it's started over`() {
        let first = sheet()
        fill(first)
        first.report.kind = .idea
        let again = sheet()
        #expect(again.restoredDraft)
        #expect(again.report.title == "Objects drop")
        #expect(again.report.kind == .idea)
        again.startOver()
        #expect(again.report.title.isEmpty && !again.restoredDraft)
        #expect(!sheet().restoredDraft)
    }

    @Test func `with no photo open, the photo's details are off`() {
        var context = FeedbackReportTests.context()
        context.photo = nil
        let sheet = sheet(context: context)
        #expect(!sheet.report.details.photo)
        sheet.aboutSession = true
        #expect(!sheet.report.details.photo && sheet.report.details.activity && sheet.report.details.log)
        sheet.aboutSession = false
        #expect(!sheet.aboutSession)
    }

    @Test func `the window's screenshot goes first and only when asked, up to three in all`() {
        let window = shot("Redlamp's window")
        let sheet = sheet(windowShot: window)
        #expect(sheet.screenshots.isEmpty)
        sheet.includesWindowShot = true
        sheet.add(shot("a.png"))
        sheet.add(shot("b.png"))
        sheet.add(shot("c.png"))
        #expect(sheet.screenshots.map(\.source) == ["Redlamp's window", "a.png", "b.png"])
        #expect(!sheet.canAddScreenshot)
        sheet.removeScreenshot(window.id)
        #expect(sheet.outgoing.screenshots.map(\.source) == ["a.png", "b.png"])
    }

    @Test func `recent steps are numbered from the last 15 minutes`() {
        let sheet = sheet()
        sheet.report.kind = .bug
        sheet.insertRecentSteps()
        let steps = sheet.report.steps.split(separator: "\n")
        #expect(steps.first == "1. Opened Photo A: RAF, Fujifilm X-T5, 7728 × 5152, with an edit, in 1.4 s")
        #expect(steps.count == 5)
    }

    @Test func `a report needs a title, words and an area to be sent`() {
        let sheet = sheet()
        sheet.acceptNote()
        #expect(!sheet.canSend)
        fill(sheet)
        #expect(sheet.canSend)
        sheet.report.featureID = nil
        #expect(!sheet.canSend)
    }

    @Test func `sending files the issue, clears the draft and tells Your Reports`() async throws {
        let relay = Relay()
        let sheet = sheet(relay: relay)
        sheet.acceptNote()
        fill(sheet)
        var told: FeedbackResult?
        sheet.onSent = { _, result in told = result }
        await sheet.send()
        #expect(try sheet.phase == .sent(.filed(
            number: 42,
            url: #require(URL(string: "https://github.com/pdcgomes/redlamp/issues/42")),
        )))
        #expect(told == sheet.phase.result)
        let submission = try #require(relay.sent.first)
        #expect(submission.title == "[Masking › Objects] Objects drop")
        #expect(submission.labels == ["in-app", "bug", "component:masking"])
        #expect(submission.attachments.map(\.name) == ["diagnostics.json"])
        #expect(!submission.dryRun)
        #expect(defaults.data(forKey: FeedbackSheetModel.draftKey) == nil)
    }

    @Test func `a failed send keeps the report and says why`() async {
        let relay = Relay()
        relay.result = .failure(.relay(status: 503, message: "Feedback is turned off"))
        let sheet = sheet(relay: relay)
        sheet.acceptNote()
        fill(sheet)
        await sheet.send()
        #expect(sheet.phase == .form)
        #expect(sheet.error == "The report couldn't be filed (503): Feedback is turned off")
        #expect(sheet.report.title == "Objects drop")
        #expect(defaults.data(forKey: FeedbackSheetModel.draftKey) != nil)
    }

    @Test func `a dry run files nothing and keeps the draft`() async {
        let relay = Relay()
        relay.result = .success(.dryRun(title: "t", body: "b", labels: ["bug"]))
        let sheet = sheet(relay: relay)
        sheet.acceptNote()
        fill(sheet)
        await sheet.send()
        #expect(sheet.phase == .sent(.dryRun(title: "t", body: "b", labels: ["bug"])))
        #expect(defaults.data(forKey: FeedbackSheetModel.draftKey) != nil)
    }
}

private extension FeedbackSheetModel.Phase {
    var result: FeedbackResult? {
        if case let .sent(result) = self {
            result
        } else {
            nil
        }
    }
}
