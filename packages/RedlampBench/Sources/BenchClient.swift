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
    public func send(_ folder: BenchFolder) async throws -> BenchProtocol.Receipt {
        let archive = FileManager.default.temporaryDirectory
            .appending(path: "\(folder.id)-\(UUID().uuidString).\(BenchArchive.fileExtension)")
        defer { try? FileManager.default.removeItem(at: archive) }
        try BenchArchive.make(folder.url, to: archive)
        var request = request("POST", "api/inbox")
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let (data, response) = try await session.upload(for: request, fromFile: archive)
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

/// Finds hubs on the local network over Bonjour and resolves each to an address the phone's
/// URLSession can reach.
public enum BenchDiscovery {
    public struct Hub: Sendable, Hashable {
        public var name: String
        public var url: URL
    }

    public static func find(timeout: Duration = .seconds(3)) async -> [Hub] {
        let endpoints = await browse(timeout: timeout)
        var hubs: [Hub] = []
        for (name, endpoint) in endpoints {
            if let url = await resolve(endpoint) {
                hubs.append(Hub(name: name, url: url))
            }
        }
        return hubs
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        var finished = false
        init(_ value: T) {
            self.value = value
        }
    }

    private static func browse(timeout: Duration) async -> [(String, NWEndpoint)] {
        let queue = DispatchQueue(label: "app.redlamp.bench.browse")
        let browser = NWBrowser(for: .bonjour(type: BenchProtocol.serviceType, domain: nil), using: .tcp)
        let found = Box<[(String, NWEndpoint)]>([])
        browser.browseResultsChangedHandler = { results, _ in
            found.value = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint {
                    return (name, result.endpoint)
                }
                return nil
            }
        }
        browser.start(queue: queue)
        try? await Task.sleep(for: timeout)
        return queue.sync {
            browser.cancel()
            return found.value
        }
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
