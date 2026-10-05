import Foundation

/// A report's issue as GitHub has it now, from the relay's status route.
public struct IssueStatus: Codable, Sendable, Hashable {
    public var number: Int
    /// "open", "closed", or "missing" (deleted or moved where the relay can't see it).
    public var state: String
    /// "completed", "not_planned", "duplicate", "reopened" or `nil`.
    public var stateReason: String?
    public var title: String?
    public var comments: Int
    public var updatedAt: Date?
    public var milestone: String?
    public var url: URL?

    /// "Open", "Closed as completed", "Closed as a duplicate", "Removed".
    public var summary: String {
        switch (state, stateReason) {
        case ("open", _): "Open"
        case ("closed", "completed"): "Closed as completed"
        case ("closed", "not_planned"): "Closed as not planned"
        case ("closed", "duplicate"): "Closed as a duplicate"
        case ("closed", _): "Closed"
        default: "Removed"
        }
    }

    /// The label beside a report in Your Reports.
    public var badge: String {
        switch (state, stateReason) {
        case ("open", _): "Open"
        case ("closed", "completed"): "Completed"
        case ("closed", "not_planned"): "Not planned"
        case ("closed", "duplicate"): "Duplicate"
        case ("closed", _): "Closed"
        default: "Removed"
        }
    }

    /// GitHub's marks for an issue's state: a ringed dot while open, a tick once completed.
    public var symbol: String {
        switch (state, stateReason) {
        case ("open", _): "smallcircle.filled.circle"
        case ("closed", "not_planned"): "slash.circle"
        case ("closed", "duplicate"): "square.on.square"
        case ("closed", _): "checkmark.circle"
        default: "xmark.circle"
        }
    }

    /// The tracker ID the issue took when triaged into the roadmap ("MSK-18: …").
    public var trackerID: String? {
        title?.firstMatch(of: /^\[?((?:[A-Z]{2,4}|P1)-\d+)\]?[:\s]/).map { String($0.1) }
    }
}

public protocol FeedbackStatusSource: Sendable {
    func statuses(of numbers: [Int]) async throws -> [IssueStatus]
}

extension FeedbackRelay: FeedbackStatusSource {
    public func statuses(of numbers: [Int]) async throws -> [IssueStatus] {
        guard !numbers.isEmpty else { return [] }
        var components = URLComponents(url: endpoint.appending(path: "status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "numbers", value: numbers.map(String.init).joined(separator: ","))]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(client, forHTTPHeaderField: "X-Redlamp-Client")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FeedbackError.unreadableReply }
        struct Reply: Decodable {
            var issues: [IssueStatus]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Reply.self, from: data).issues
    }
}

/// A report this Mac sent, for Your Reports: anyone can read its issue, account or not.
public struct SentReport: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var number: Int
    public var url: URL
    public var title: String
    public var featureID: String?
    public var kind: FeedbackReport.Kind
    public var sent: Date
    public var status: IssueStatus?
    /// What the person last saw, so new replies and a change of state stand out.
    public var seenComments = 0
    public var seenState = "open"

    public var hasNews: Bool {
        guard let status else { return false }
        return status.comments > seenComments || status.state != seenState
    }

    public var topic: FeedbackTopic? {
        featureID.flatMap(FeedbackArea.topic)
    }
}

/// A report that couldn't reach redlamp.app, kept until it can be sent.
public struct QueuedReport: Codable, Sendable, Hashable, Identifiable {
    public var submission: FeedbackSubmission
    public var queued: Date

    public var id: UUID {
        submission.report
    }
}

/// The reports this Mac has sent and those waiting to be: Your Reports, its badge, and the outbox.
/// Kept in Application Support, never sent anywhere; checking the issues' state asks the relay.
@MainActor
@Observable
public final class FeedbackHistory {
    public static let shared = FeedbackHistory()

    public private(set) var reports: [SentReport] = []
    public private(set) var queued: [QueuedReport] = []
    public private(set) var isRefreshing = false
    public var checksForReplies: Bool {
        didSet { defaults.set(checksForReplies, forKey: Self.checksKey) }
    }

    /// The most reports the outbox keeps (each holds its screenshots); the oldest go first.
    public static let outboxLimit = 20
    /// How often, at most, the issues' state is checked without being asked.
    public static let refreshInterval: TimeInterval = 6 * 3600
    static let checksKey = "feedback.checksForReplies"

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored public var source: (any FeedbackStatusSource)?
    @ObservationIgnored public var sender: (any FeedbackSending)?
    @ObservationIgnored private var lastRefresh: Date?

    public init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "Redlamp/Feedback"),
        defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
    ) {
        self.directory = directory
        self.defaults = defaults
        self.now = now
        checksForReplies = defaults.object(forKey: Self.checksKey) as? Bool ?? true
        reports = Self.read([SentReport].self, from: directory.appending(path: "reports.json")) ?? []
        queued = Self.read([QueuedReport].self, from: directory.appending(path: "outbox.json")) ?? []
    }

    /// Reports whose issue has news: a reply or a change of state since they were last seen.
    public var newsCount: Int {
        reports.count { $0.hasNews }
    }

    public func record(_ report: FeedbackReport, number: Int, url: URL) {
        reports.removeAll { $0.id == report.id }
        reports.insert(SentReport(
            id: report.id, number: number, url: url, title: report.issueTitle, featureID: report.featureID,
            kind: report.kind, sent: now(),
        ), at: 0)
        save()
    }

    public func forget(_ id: UUID) {
        reports.removeAll { $0.id == id }
        queued.removeAll { $0.id == id }
        save()
    }

    /// Everything shown in Your Reports now counts as seen.
    public func markSeen() {
        for index in reports.indices {
            if let status = reports[index].status {
                reports[index].seenComments = status.comments
                reports[index].seenState = status.state
            }
        }
        save()
    }

    /// Asks the relay for the issues' state: when asked (`force`), or at most every six hours,
    /// and only once something has been sent and checking is on.
    public func refresh(force: Bool = false) async {
        guard let source, !reports.isEmpty, force || checksForReplies, !isRefreshing else { return }
        if !force, let lastRefresh, now().timeIntervalSince(lastRefresh) < Self.refreshInterval {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let statuses = try? await source.statuses(of: reports.map(\.number)) else { return }
        lastRefresh = now()
        let byNumber = Dictionary(statuses.map { ($0.number, $0) }) { first, _ in first }
        for index in reports.indices {
            if let status = byNumber[reports[index].number] {
                reports[index].status = status
            }
        }
        save()
    }

    // MARK: - The outbox

    public func enqueue(_ submission: FeedbackSubmission) {
        queued.removeAll { $0.id == submission.report }
        queued.append(QueuedReport(submission: submission, queued: now()))
        queued.removeFirst(max(0, queued.count - Self.outboxLimit))
        save()
    }

    /// Sends what's waiting; what can't be sent yet stays.
    public func sendQueued() async {
        guard let sender else { return }
        for item in queued {
            guard case let .filed(number, url)? = try? await sender.send(item.submission) else { continue }
            queued.removeAll { $0.id == item.id }
            reports.removeAll { $0.id == item.id }
            reports.insert(SentReport(
                id: item.id, number: number, url: url, title: item.submission.title, featureID: item.submission.area,
                kind: item.submission.kind, sent: now(),
            ), at: 0)
            save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(reports).write(to: directory.appending(path: "reports.json"), options: .atomic)
        try? encoder.encode(queued).write(to: directory.appending(path: "outbox.json"), options: .atomic)
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(type, from: $0) }
    }
}
