import Foundation
import Testing
@testable import RedlampUI

/// Your Reports and the outbox: what's kept, what counts as news, when the issues are checked,
/// and reports that wait until they can be sent.
@MainActor
struct FeedbackHistoryTests {
    private final class Source: FeedbackStatusSource, @unchecked Sendable {
        var statuses: [IssueStatus] = []
        var asked: [[Int]] = []

        func statuses(of numbers: [Int]) async throws -> [IssueStatus] {
            asked.append(numbers)
            return statuses
        }
    }

    private final class Sender: FeedbackSending, @unchecked Sendable {
        var result: Result<FeedbackResult, FeedbackError> = .success(.filed(
            number: 7,
            url: URL(string: "https://github.com/o/r/issues/7")!,
        ))

        func send(_: FeedbackSubmission) async throws -> FeedbackResult {
            try result.get()
        }
    }

    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 812_000_000)
    }

    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "FeedbackHistoryTests-\(UUID().uuidString)")
    private let defaults = UserDefaults(suiteName: "FeedbackHistoryTests-\(UUID().uuidString)")!
    private let clock = Clock()

    private func history() -> FeedbackHistory {
        FeedbackHistory(directory: directory, defaults: defaults) { [clock] in clock.now }
    }

    private func status(_ number: Int, state: String = "open", comments: Int = 0, title: String? = nil) -> IssueStatus {
        IssueStatus(
            number: number,
            state: state,
            stateReason: state == "closed" ? "completed" : nil,
            title: title,
            comments: comments,
        )
    }

    private func submission(_ id: UUID = UUID()) -> FeedbackSubmission {
        FeedbackSubmission(
            report: id, kind: .bug, area: "export.dialog", title: "[Export › Export Dialog] It hangs", body: "Body",
            labels: ["in-app", "bug", "component:export"], attachments: [], dryRun: false,
        )
    }

    @Test func `sent reports are kept across launches, newest first`() throws {
        var first = FeedbackReport()
        first.title = "One"
        var second = FeedbackReport()
        second.title = "Two"
        second.featureID = "export.dialog"
        let history = history()
        try history.record(first, number: 1, url: #require(URL(string: "https://github.com/o/r/issues/1")))
        try history.record(second, number: 2, url: #require(URL(string: "https://github.com/o/r/issues/2")))
        let again = self.history()
        #expect(again.reports.map(\.number) == [2, 1])
        #expect(again.reports.first?.title == "[Export › Export Dialog] Two")
        again.forget(second.id)
        #expect(self.history().reports.map(\.number) == [1])
    }

    @Test func `a reply or a change of state is news until it's seen`() async throws {
        let source = Source()
        let history = history()
        history.source = source
        try history.record(FeedbackReport(), number: 5, url: #require(URL(string: "https://github.com/o/r/issues/5")))
        source.statuses = [status(5)]
        await history.refresh(force: true)
        #expect(history.newsCount == 0)
        source.statuses = [status(5, comments: 2)]
        await history.refresh(force: true)
        #expect(history.newsCount == 1)
        history.markSeen()
        #expect(history.newsCount == 0)
        source.statuses = [status(5, state: "closed", comments: 2)]
        await history.refresh(force: true)
        #expect(history.newsCount == 1)
        #expect(history.reports.first?.status?.summary == "Closed as completed")
    }

    @Test func `issues are checked every six hours at most unless asked, and only when there's something to check`(
    ) async throws {
        let source = Source()
        let history = history()
        history.source = source
        await history.refresh()
        #expect(source.asked.isEmpty)
        try history.record(FeedbackReport(), number: 5, url: #require(URL(string: "https://github.com/o/r/issues/5")))
        await history.refresh()
        await history.refresh()
        #expect(source.asked == [[5]])
        clock.now += FeedbackHistory.refreshInterval + 1
        await history.refresh()
        #expect(source.asked.count == 2)
        history.checksForReplies = false
        clock.now += FeedbackHistory.refreshInterval + 1
        await history.refresh()
        #expect(source.asked.count == 2)
        await history.refresh(force: true)
        #expect(source.asked.count == 3)
        #expect(self.history().checksForReplies == false)
    }

    @Test func `a report triaged into the roadmap shows its tracker ID`() {
        #expect(status(1, title: "MSK-18: Objects drop the first selection").trackerID == "MSK-18")
        #expect(status(1, title: "[Masking › Objects] Objects drop").trackerID == nil)
        #expect(status(1, state: "missing").summary == "Removed")
    }

    @Test func `a report that couldn't be sent waits, and moves to the sent list once it is`() async throws {
        let sender = Sender()
        sender.result = .failure(.unreachable("offline"))
        let history = history()
        history.sender = sender
        let id = UUID()
        history.enqueue(submission(id))
        await history.sendQueued()
        #expect(self.history().queued.map(\.id) == [id])
        sender.result = try .success(.filed(number: 7, url: #require(URL(string: "https://github.com/o/r/issues/7"))))
        await history.sendQueued()
        #expect(history.queued.isEmpty)
        #expect(history.reports.map(\.number) == [7])
        #expect(history.reports.first?.id == id)
        #expect(history.reports.first?.featureID == "export.dialog")
    }

    @Test func `GitHub's own page gets as much of the report as fits, and the clipboard all of it`() {
        var long = submission()
        long.body = "![Screenshot 1](attachment:screenshot-1.jpg)\n" + String(
            repeating: "Words with spaces. ",
            count: 4000,
        )
        let url = FeedbackFallbacks.newIssueURL(for: long)
        #expect(url.absoluteString.count <= FeedbackFallbacks.urlLimit)
        #expect(url.absoluteString.hasPrefix("https://github.com/pdcgomes/redlamp/issues/new?title="))
        let text = FeedbackFallbacks.clipboardText(for: long)
        #expect(text.hasPrefix("# [Export › Export Dialog] It hangs\n\nScreenshot 1 (attach screenshot-1.jpg here)"))
        #expect(text.count > 70000)
    }

    @Test func `a saved report is a folder with its files linked`() throws {
        var report = submission()
        report.body = "![Screenshot 1](attachment:screenshot-1.jpg)"
        report.attachments = [FeedbackSubmission.Attachment(
            name: "screenshot-1.jpg",
            type: "image/jpeg",
            data: Data([0xFF, 0xD8, 0xFF]),
        )]
        let folder = directory.appending(path: "Saved Report")
        try FeedbackFallbacks.save(report, to: folder)
        let markdown = try String(contentsOf: folder.appending(path: "report.md"), encoding: .utf8)
        #expect(markdown.contains("![Screenshot 1](screenshot-1.jpg)"))
        #expect(markdown.contains("Labels: in-app, bug, component:export"))
        #expect(try Data(contentsOf: folder.appending(path: "screenshot-1.jpg")) == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func `the sheet keeps an unreachable report for later and is done with its draft`() async {
        let relay = Sender()
        relay.result = .failure(.unreachable("The Internet connection appears to be offline."))
        let sheet = FeedbackSheetModel(
            context: FeedbackReportTests.context(), system: FeedbackReportTests.system, windowShot: nil,
            sender: relay, dryRun: false, defaults: defaults,
        )
        sheet.acceptNote()
        sheet.report.title = "It hangs"
        sheet.report.body = "Exporting never ends."
        await sheet.send()
        #expect(sheet.unreachable)
        var queued: FeedbackSubmission?
        sheet.onQueue = { queued = $0 }
        sheet.queue()
        #expect(sheet.phase == .queued)
        #expect(queued?.title == "[Masking › Objects] It hangs")
        #expect(queued?.dryRun == false)
        #expect(defaults.data(forKey: FeedbackSheetModel.draftKey) == nil)
    }
}

/// The relay client against a stubbed network: what it sends, and what it makes of each answer.
@Suite(.serialized)
struct FeedbackRelayTests {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var answer: (Int, String) = (201, "{}")
        nonisolated(unsafe) static var failure: URLError?
        nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []

        override class func canInit(with _: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            var body = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 65536)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(buffer, count: count)
                }
                stream.close()
            }
            Self.requests.append((request, body))
            if let failure = Self.failure {
                client?.urlProtocol(self, didFailWithError: failure)
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.answer.0,
                httpVersion: nil,
                headerFields: nil,
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.answer.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func relay() -> FeedbackRelay {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        Stub.requests = []
        Stub.failure = nil
        return FeedbackRelay(
            endpoint: URL(string: "https://relay.test/api/feedback")!,
            session: URLSession(configuration: configuration),
            client: "Redlamp/test (1)",
        )
    }

    private let submission = FeedbackSubmission(
        report: UUID(uuidString: "6F1C2A7E-0B5D-4C3B-9E2A-1D4F5A6B7C8D")!, kind: .bug, area: "masking.objects",
        title: "[Masking › Objects] Drops", body: "Body", labels: ["in-app", "bug", "component:masking"],
        attachments: [FeedbackSubmission.Attachment(
            name: "screenshot-1.jpg",
            type: "image/jpeg",
            data: Data([0xFF, 0xD8, 0xFF]),
        )],
        dryRun: false,
    )

    @Test func `a report goes as the JSON the relay checks, and comes back as an issue`() async throws {
        let relay = relay()
        Stub.answer = (201, #"{"number":12,"url":"https://github.com/pdcgomes/redlamp/issues/12"}"#)
        let result = try await relay.send(submission)
        #expect(try result == .filed(
            number: 12,
            url: #require(URL(string: "https://github.com/pdcgomes/redlamp/issues/12")),
        ))
        let (request, body) = try #require(Stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Redlamp-Client") == "Redlamp/test (1)")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["report", "kind", "area", "title", "body", "labels", "attachments", "dryRun"])
        #expect(json["report"] as? String == "6F1C2A7E-0B5D-4C3B-9E2A-1D4F5A6B7C8D")
        #expect(json["kind"] as? String == "bug")
        let attachment = try #require((json["attachments"] as? [[String: Any]])?.first)
        #expect(attachment["data"] as? String == Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
    }

    @Test func `a dry run, a refusal and no network each read as such`() async throws {
        let relay = relay()
        Stub.answer = (200, #"{"dryRun":true,"title":"T","body":"B","labels":["bug"]}"#)
        #expect(try await relay.send(submission) == .dryRun(title: "T", body: "B", labels: ["bug"]))

        Stub.answer = (503, #"{"error":"Reports can't be filed right now."}"#)
        await #expect(throws: FeedbackError.relay(status: 503, message: "Reports can't be filed right now.")) {
            try await relay.send(submission)
        }

        Stub.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await relay.send(submission)
            Issue.record("expected the relay to be unreachable")
        } catch let FeedbackError.unreachable(reason) {
            #expect(!reason.isEmpty)
        }
    }

    @Test func `statuses come from the relay's status route`() async throws {
        let relay = relay()
        Stub.answer = (
            200,
            #"{"issues":[{"number":12,"state":"closed","stateReason":"not_planned","title":"MSK-18: Drops","comments":3,"updatedAt":"2026-10-04T08:01:59Z","milestone":"Phase 3: Pro masking","url":"https://github.com/pdcgomes/redlamp/issues/12"},{"number":13,"state":"missing","stateReason":null,"title":null,"comments":0,"updatedAt":null,"milestone":null,"url":null}]}"#,
        )
        let statuses = try await relay.statuses(of: [12, 13])
        #expect(Stub.requests.first?.0.url?.absoluteString == "https://relay.test/api/feedback/status?numbers=12,13")
        #expect(statuses.map(\.summary) == ["Closed as not planned", "Removed"])
        #expect(statuses.first?.trackerID == "MSK-18")
        #expect(statuses.first?.updatedAt != nil)
    }
}
