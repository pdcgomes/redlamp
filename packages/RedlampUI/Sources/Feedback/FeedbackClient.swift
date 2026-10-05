import Foundation

/// A report as the relay receives it: the issue's title, body and labels, and the files the
/// body links to.
public struct FeedbackSubmission: Codable, Sendable, Hashable {
    public struct Attachment: Codable, Sendable, Hashable {
        public var name: String
        public var type: String
        /// Base64 in the JSON.
        public var data: Data
    }

    public var report: UUID
    public var kind: FeedbackReport.Kind
    public var area: String?
    public var title: String
    public var body: String
    public var labels: [String]
    public var attachments: [Attachment]
    /// The relay renders the issue and files nothing.
    public var dryRun: Bool
}

/// What the relay did with a report.
public enum FeedbackResult: Sendable, Hashable {
    case filed(number: Int, url: URL)
    /// A dry run: the issue it would have filed.
    case dryRun(title: String, body: String, labels: [String])
}

public enum FeedbackError: LocalizedError, Equatable {
    case relay(status: Int, message: String)
    case unreadableReply
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case let .relay(status, message): "The report couldn't be filed (\(status)): \(message)"
        case .unreadableReply: "The report was sent, but the reply couldn't be read."
        case let .unreachable(reason): "Redlamp couldn't reach redlamp.app: \(reason)"
        }
    }
}

public protocol FeedbackSending: Sendable {
    func send(_ submission: FeedbackSubmission) async throws -> FeedbackResult
}

/// The relay on redlamp.app, which files reports as GitHub issues as the Redlamp Feedback bot,
/// so nobody needs a GitHub account (`web/app/api/feedback`).
public struct FeedbackRelay: FeedbackSending {
    public static let defaultEndpoint = URL(string: "https://redlamp.app/api/feedback")!

    public var endpoint: URL
    public var session: URLSession
    /// "Redlamp/0.2.1-prealpha (412)", sent as `X-Redlamp-Client`.
    public var client: String

    public init(endpoint: URL = FeedbackRelay.configuredEndpoint, session: URLSession = .shared, client: String) {
        self.endpoint = endpoint
        self.session = session
        self.client = client
    }

    /// `defaults write app.redlamp.mac FeedbackEndpoint http://localhost:3000/api/feedback`
    /// points a build at a local relay.
    public static var configuredEndpoint: URL {
        UserDefaults.standard.string(forKey: "FeedbackEndpoint").flatMap(URL.init(string:)) ?? defaultEndpoint
    }

    /// Debug and profiling builds send dry runs, so working on Redlamp files no issues, unless
    /// `defaults write app.redlamp.mac FeedbackSendsLive -bool YES`.
    public static var sendsLive: Bool {
        #if DEBUG || REDLAMP_PROFILING
            UserDefaults.standard.bool(forKey: "FeedbackSendsLive")
        #else
            true
        #endif
    }

    private struct Reply: Decodable {
        var number: Int?
        var url: URL?
        var dryRun: Bool?
        var title: String?
        var body: String?
        var labels: [String]?
        var error: String?
    }

    public func send(_ submission: FeedbackSubmission) async throws -> FeedbackResult {
        var request = URLRequest(url: endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Redlamp-Client")
        request.httpBody = try JSONEncoder().encode(submission)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedbackError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard (200 ..< 300).contains(status) else {
            throw FeedbackError.relay(
                status: status,
                message: reply?.error ?? HTTPURLResponse.localizedString(forStatusCode: status),
            )
        }
        if reply?.dryRun == true, let title = reply?.title, let body = reply?.body {
            return .dryRun(title: title, body: body, labels: reply?.labels ?? [])
        }
        guard let number = reply?.number, let url = reply?.url else { throw FeedbackError.unreadableReply }
        return .filed(number: number, url: url)
    }
}

public extension FeedbackReport {
    /// The report with its screenshots and diagnostics, ready for the relay.
    func submission(
        context: FeedbackContext,
        system: SystemSnapshot,
        log: [String],
        dryRun: Bool,
    ) throws -> FeedbackSubmission {
        var attachments = screenshots.prefix(Self.screenshotLimit).enumerated().map { index, shot in
            FeedbackSubmission.Attachment(name: Self.screenshotName(index), type: "image/jpeg", data: shot.jpeg)
        }
        if let diagnostics = try diagnostics(context: context, system: system, log: log) {
            attachments.append(FeedbackSubmission.Attachment(
                name: Self.diagnosticsName,
                type: "application/json",
                data: diagnostics,
            ))
        }
        return FeedbackSubmission(
            report: id, kind: kind, area: featureID, title: issueTitle,
            body: issueBody(context: context, system: system, log: log),
            labels: labels, attachments: attachments, dryRun: dryRun,
        )
    }
}
