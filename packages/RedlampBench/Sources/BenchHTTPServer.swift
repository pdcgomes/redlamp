import Foundation
import Network

public struct BenchHTTPRequest: Sendable {
    public var method: String
    /// Percent-decoded, without the query.
    public var path: String
    public var query: [String: String]
    /// Lowercased names.
    public var headers: [String: String]
    /// The body, when it was small enough to keep in memory.
    public var body: Data
    /// The body, when it was large enough to stream to disk; removed after the response.
    public var bodyFile: URL?

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// The path's parts after a prefix such as `/api/tasks`; nil when it doesn't start with it.
    public func parts(after prefix: String) -> [String]? {
        guard path == prefix || path.hasPrefix(prefix + "/") else { return nil }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }
}

public struct BenchHTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        case file(URL)
    }

    public var status: Int
    public var headers: [String: String]
    public var body: Body

    public init(status: Int = 200, headers: [String: String] = [:], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: some Encodable, status: Int = 200) -> BenchHTTPResponse {
        let data = (try? JSONEncoder.bench.encode(value)) ?? Data("{}".utf8)
        return BenchHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: .data(data))
    }

    public static func error(_ status: Int, _ message: String) -> BenchHTTPResponse {
        json(["error": message], status: status)
    }

    public static func html(_ text: String) -> BenchHTTPResponse {
        BenchHTTPResponse(headers: ["Content-Type": "text/html; charset=utf-8"], body: .data(Data(text.utf8)))
    }

    public static func file(_ url: URL, type: String = "application/octet-stream") -> BenchHTTPResponse {
        BenchHTTPResponse(headers: ["Content-Type": type], body: .file(url))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}

/// A small HTTP/1.1 server for the local network: one request per connection, bodies with a
/// Content-Length only (no chunked uploads), large bodies streamed to a scratch file. It
/// advertises itself over Bonjour when given a service name.
public final class BenchHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BenchHTTPRequest) async -> BenchHTTPResponse

    public enum State: Sendable, Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
        case stopped
    }

    /// Bodies above this go to a scratch file instead of memory.
    static let memoryBodyLimit = 4 << 20
    static let headerLimit = 64 << 10

    private let queue = DispatchQueue(label: "app.redlamp.bench.http")
    private let queueKey = DispatchSpecificKey<Void>()
    private let handler: Handler
    private let maxBody: Int64
    private let scratch: URL
    private var listener: NWListener?

    public init(maxBody: Int64 = BenchLimits.bytes + (16 << 20), scratch: URL, handler: @escaping Handler) {
        self.handler = handler
        self.maxBody = maxBody
        self.scratch = scratch
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Starts listening on `port`, or on any free port when it's nil or another app has it.
    public func start(
        port: UInt16?,
        service: (name: String, type: String)?,
        onState: @escaping @Sendable (State) -> Void,
    ) throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let fixed = port.flatMap { NWEndpoint.Port(rawValue: $0) }
        let listener = try fixed.map { try NWListener(using: parameters, on: $0) } ?? NWListener(using: parameters)
        if let service {
            listener.service = NWListener.Service(name: service.name, type: service.type)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                onState(.ready(port: listener?.port?.rawValue ?? 0))
            case let .failed(error):
                // A taken port fails only once the listener starts: try again on any port.
                if fixed != nil, let self {
                    listener?.cancel()
                    do {
                        try start(port: nil, service: service, onState: onState)
                    } catch {
                        onState(.failed(error.localizedDescription))
                    }
                } else {
                    onState(.failed(error.localizedDescription))
                }
            case .cancelled:
                if fixed == nil || self?.listener === listener {
                    onState(.stopped)
                }
            default:
                onState(.starting)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            HTTPConnection(connection: connection, server: self).start()
        }
        // A retry after a taken port runs on the server's queue already.
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync { self.listener = listener }
        } else {
            self.listener = listener
        }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    fileprivate func respond(to request: BenchHTTPRequest) async -> BenchHTTPResponse {
        await handler(request)
    }

    fileprivate var limits: (maxBody: Int64, scratch: URL, queue: DispatchQueue) {
        (maxBody, scratch, queue)
    }
}

/// One connection's request and response; all of its state is touched on the server's queue.
private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let server: BenchHTTPServer
    private let queue: DispatchQueue
    private var header = Data()
    private var request: BenchHTTPRequest?
    private var expected: Int64 = 0
    private var received: Int64 = 0
    private var bodyHandle: FileHandle?
    /// Set once the request is complete or refused: later bytes are ignored.
    private var answering = false

    init(connection: NWConnection, server: BenchHTTPServer) {
        self.connection = connection
        self.server = server
        queue = server.limits.queue
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                consume(data)
            }
            if answering {
                return
            } else if error != nil || isComplete {
                close()
            } else {
                receive()
            }
        }
    }

    private func consume(_ data: Data) {
        guard !answering else { return }
        guard request == nil else { return appendBody(data) }
        header.append(data)
        guard let end = header.range(of: Data("\r\n\r\n".utf8)) else {
            if header.count > BenchHTTPServer.headerLimit {
                send(.error(431, "request headers too large"))
            }
            return
        }
        let head = String(decoding: header[header.startIndex ..< end.lowerBound], as: UTF8.self)
        let rest = header[end.upperBound...]
        guard let parsed = Self.parse(head) else { return send(.error(400, "malformed request")) }
        if parsed.header("transfer-encoding") != nil {
            return send(.error(411, "send a Content-Length"))
        }
        expected = Int64(parsed.header("content-length") ?? "0") ?? -1
        guard expected >= 0 else { return send(.error(400, "bad Content-Length")) }
        guard expected <= server.limits.maxBody else { return send(.error(413, "body too large")) }
        request = parsed
        if parsed.header("expect")?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }
        if expected > BenchHTTPServer.memoryBodyLimit {
            let file = server.limits.scratch.appending(path: "body-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            bodyHandle = try? FileHandle(forWritingTo: file)
            request?.bodyFile = file
            guard bodyHandle != nil else { return send(.error(500, "no scratch space")) }
        }
        appendBody(Data(rest))
    }

    private func appendBody(_ data: Data) {
        guard !data.isEmpty || received >= expected else { return finishIfComplete() }
        let take = data.prefix(Int(max(0, expected - received)))
        if let bodyHandle {
            try? bodyHandle.write(contentsOf: take)
        } else {
            request?.body.append(take)
        }
        received += Int64(take.count)
        finishIfComplete()
    }

    private func finishIfComplete() {
        guard let request, received >= expected, !answering else { return }
        answering = true
        try? bodyHandle?.close()
        bodyHandle = nil
        Task {
            let response = await server.respond(to: request)
            queue.async { [self] in
                send(response)
            }
        }
    }

    private func send(_ response: BenchHTTPResponse) {
        answering = true
        var headers = response.headers
        let length = switch response.body {
        case let .data(data): Int64(data.count)
        case let .file(url): Int64((try? BenchFile.size(url)) ?? 0)
        }
        headers["Content-Length"] = "\(length)"
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        var head = "HTTP/1.1 \(response.status) \(BenchHTTPResponse.reason(response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [self] _ in
            switch response.body {
            case let .data(data): connection.send(content: data, completion: .contentProcessed { [self] _ in close() })
            case let .file(url): sendFile(try? FileHandle(forReadingFrom: url))
            }
        })
    }

    private func sendFile(_ handle: FileHandle?) {
        guard let handle, let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
            try? handle?.close()
            return close()
        }
        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil {
                try? handle.close()
                close()
            } else {
                sendFile(handle)
            }
        })
    }

    private func close() {
        if let file = request?.bodyFile {
            try? FileManager.default.removeItem(at: file)
        }
        connection.cancel()
    }

    static func parse(_ head: String) -> BenchHTTPRequest? {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://bench" + target) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return BenchHTTPRequest(
            method: String(parts[0]), path: components.path, query: query, headers: headers, body: Data(),
        )
    }
}
