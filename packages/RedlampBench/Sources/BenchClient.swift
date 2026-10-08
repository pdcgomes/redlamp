import Foundation
import Network

public enum BenchClientError: Error, CustomStringConvertible, Equatable {
    case http(Int, String)
    case badResponse
    case mismatch(String)

    public var description: String {
        switch self {
        case let .http(status, message): "the hub said \(status): \(message)"
        case .badResponse: "the hub's answer wasn't understood"
        case let .mismatch(path): "\(path) arrived damaged"
        }
    }
}

/// The phone's side of the hub's API (`BenchProtocol`).
public struct BenchClient: Sendable {
    public var base: URL
    public var token: String?
    private let session: URLSession

    public init(base: URL, token: String? = nil, session: URLSession = .shared) {
        self.base = base
        self.token = token
        self.session = session
    }

    public func info() async throws -> BenchProtocol.HubInfo {
        try await json(request("GET", "api/hub"))
    }

    public func pair(code: String, device: String) async throws -> BenchProtocol.PairReply {
        var request = request("POST", "api/pair")
        request.httpBody = try JSONEncoder.bench.encode(BenchProtocol.PairRequest(code: code, device: device))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await json(request)
    }

    /// Asks the owner to allow this phone; returns once they have, with the hub's reply.
    public func pairByApproval(device: String, timeout: Duration = .seconds(180)) async throws -> BenchProtocol
        .PairReply {
        var request = request("POST", "api/pair")
        request.httpBody = try JSONEncoder.bench.encode(BenchProtocol.PairRequest(device: device))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let pending: BenchProtocol.PairPending = try await json(request)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            let status = try await pairingStatus(pending.request)
            switch status.state {
            case .pending: continue
            case .approved:
                guard let token = status.token else { throw BenchClientError.badResponse }
                return BenchProtocol.PairReply(token: token, hub: status.hub)
            case .denied: throw BenchClientError.http(403, "the Lab didn't allow this phone")
            case .expired: throw BenchClientError.http(408, "the Lab didn't answer in time")
            }
        }
        throw BenchClientError.http(408, "the Lab didn't answer in time")
    }

    /// Where a pairing request stands: waiting, allowed (with the token), refused or expired.
    public func pairingStatus(_ request: String) async throws -> BenchProtocol.PairStatus {
        try await json(self.request("GET", "api/pair/\(request)"))
    }

    public func listings() async throws -> [BenchProtocol.Listing] {
        try await json(request("GET", "api/tasks"))
    }

    public func done() async throws -> [BenchProtocol.Receipt] {
        try await json(request("GET", "api/done"))
    }

    /// The hub's copy of a folder, or nil when it has none.
    public func receipt(_ id: String) async throws -> BenchProtocol.Receipt? {
        do {
            return try await json(request("GET", "api/done/\(id)"))
        } catch BenchClientError.http(404, _) {
            return nil
        }
    }

    /// Fetches every file of a listing into `destination` (replaced), checking each one's size
    /// and SHA-256 before anything replaces what was there.
    public func download(_ listing: BenchProtocol.Listing, to destination: URL) async throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for file in listing.files {
            guard BenchFile.isSafeRelativePath(file.path) else { throw BenchClientError.mismatch(file.path) }
            let (temporary, response) = try await session.download(for: request(
                "GET", "api/tasks/\(listing.id)/\(file.path)",
            ))
            try check(response, body: nil)
            let target = staging.appending(path: file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: target)
            guard try BenchFile.size(target) == file.bytes, try BenchFile.sha256(target) == file.sha256 else {
                throw BenchClientError.mismatch(file.path)
            }
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: destination)
        }
    }

    /// Sends a folder as one archive to the hub's inbox.
    /// Sends a folder as one archive, reporting the share uploaded as it goes.
    public func send(
        _ folder: BenchFolder,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> BenchProtocol.Receipt {
        let archive = FileManager.default.temporaryDirectory
            .appending(path: "\(folder.id)-\(UUID().uuidString).\(BenchArchive.fileExtension)")
        defer { try? FileManager.default.removeItem(at: archive) }
        try BenchArchive.make(folder.url, to: archive)
        var request = request("POST", "api/inbox")
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let (data, response) = try await session.upload(
            for: request, fromFile: archive, delegate: progress.map(UploadProgress.init),
        )
        try check(response, body: data)
        return try JSONDecoder.bench.decode(BenchProtocol.Receipt.self, from: data)
    }

    // MARK: - Plumbing

    private func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func json<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try check(response, body: data)
        do {
            return try JSONDecoder.bench.decode(T.self, from: data)
        } catch {
            throw BenchClientError.badResponse
        }
    }

    private func check(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw BenchClientError.badResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = body.flatMap { try? JSONDecoder.bench.decode([String: String].self, from: $0)["error"] }
            throw BenchClientError.http(
                http.statusCode,
                message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            )
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, didSendBodyData _: Int64,
        totalBytesSent sent: Int64, totalBytesExpectedToSend expected: Int64,
    ) {
        if expected > 0 {
            report(Double(sent) / Double(expected))
        }
    }
}

/// Resolves a hub that `BonjourWatcher` found to an address the phone's URLSession can reach.
public enum BenchDiscovery {
    private final class Box<T>: @unchecked Sendable {
        var value: T
        var finished = false
        init(_ value: T) {
            self.value = value
        }
    }

    /// The address of a service found by `BonjourWatcher`.
    public static func address(of service: BonjourWatcher.Service) async -> URL? {
        await resolve(service.endpoint)
    }

    /// Opens a connection to the service to learn its address, preferring IPv4, whose URLs need
    /// no interface scope.
    private static func resolve(_ endpoint: NWEndpoint) async -> URL? {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "app.redlamp.bench.resolve")
        return await withCheckedContinuation { continuation in
            // Both handlers run on `queue`, so `box` is only touched there.
            let box = Box<URL?>(nil)
            let finish: @Sendable (URL?) -> Void = { url in
                guard !box.finished else { return }
                box.finished = true
                connection.cancel()
                continuation.resume(returning: url)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let percent = text.firstIndex(of: "%") {
                            text = String(text[..<percent])
                        }
                        finish(URL(string: "http://\(text):\(port.rawValue)/"))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }
}
