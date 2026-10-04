import Foundation
import RedlampEngineAPI
import RedlampRecipes

/// What the relay did with a camera bench report.
public struct CameraBenchReceipt: Sendable, Hashable {
    /// The submission's ID in the private repository.
    public var id: String
    /// A dry run: checked, and nothing kept.
    public var dryRun: Bool
}

public enum CameraBenchSendError: LocalizedError, Equatable {
    case relay(status: Int, message: String)
    case unreadableReply
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case let .relay(status, message): "The results couldn't be sent (\(status)): \(message)"
        case .unreadableReply: "The results were sent, but the reply couldn't be read."
        case let .unreachable(reason): "Redlamp couldn't reach redlamp.app: \(reason)"
        }
    }
}

public protocol CameraBenchSending: Sendable {
    func send(_ report: Data) async throws -> CameraBenchReceipt
    /// The public evidence, for what each camera mode still needs; nil when it can't be had.
    func summary() async -> CameraBenchSummary?
}

/// The camera bench's relay on redlamp.app (`web/app/api/bench`), which keeps each report in a
/// private repository as the Redlamp Feedback app (CAM-16).
public struct CameraBenchRelay: CameraBenchSending {
    public static let defaultEndpoint = URL(string: "https://redlamp.app/api/bench")!

    public var endpoint: URL
    public var session: URLSession
    /// "Redlamp/0.2.2-prealpha", sent as `X-Redlamp-Client`.
    public var client: String

    public init(endpoint: URL = CameraBenchRelay.configuredEndpoint, session: URLSession = .shared, client: String) {
        self.endpoint = endpoint
        self.session = session
        self.client = client
    }

    /// `defaults write app.redlamp.mac CameraBenchEndpoint http://localhost:3000/api/bench`
    /// points a build at a local relay.
    public static var configuredEndpoint: URL {
        UserDefaults.standard.string(forKey: "CameraBenchEndpoint").flatMap(URL.init(string:)) ?? defaultEndpoint
    }

    /// Debug builds send dry runs, so working on Redlamp keeps nothing, unless
    /// `defaults write app.redlamp.mac CameraBenchSendsLive -bool YES`.
    public static var sendsLive: Bool {
        #if DEBUG
            UserDefaults.standard.bool(forKey: "CameraBenchSendsLive")
        #else
            true
        #endif
    }

    private struct Reply: Decodable {
        var id: String?
        var dryRun: Bool?
        var error: String?
    }

    public func send(_ report: Data) async throws -> CameraBenchReceipt {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Redlamp-Client")
        if !Self.sendsLive {
            request.setValue("1", forHTTPHeaderField: "X-Redlamp-Dry-Run")
        }
        request.httpBody = report
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CameraBenchSendError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard (200 ..< 300).contains(status) else {
            throw CameraBenchSendError.relay(
                status: status, message: reply?.error ?? HTTPURLResponse.localizedString(forStatusCode: status),
            )
        }
        guard let id = reply?.id else { throw CameraBenchSendError.unreadableReply }
        return CameraBenchReceipt(id: id, dryRun: reply?.dryRun ?? false)
    }

    public func summary() async -> CameraBenchSummary? {
        let url = endpoint.appending(path: "summary")
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(CameraBenchSummary.self, from: data)
    }
}

/// A random ID per Mac, sent with camera bench reports so contributors can be counted; never
/// published, and replaced when reset.
public enum CameraBenchContributor {
    static let key = "CameraBenchContributor"

    public static func id(in defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: key) {
            return id
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }

    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
