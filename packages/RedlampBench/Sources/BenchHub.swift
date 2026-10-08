import CryptoKit
import Foundation

/// The Lab's hub (ARC-13): on the local network, behind a pairing code, it lists the outbox and
/// the templates for the phone, serves their files, and files what the phone sends back in Done
/// after checking it as untrusted input. The harness runs it; the iPhone app talks to it.
public actor BenchHub {
    public enum Event: Sendable {
        case state(BenchHTTPServer.State)
        case arrival(BenchStore.Arrival)
        case refused(String)
        case paired(device: String)
        case contact(device: String)
    }

    public struct Device: Codable, Sendable, Hashable {
        public var name: String
        public var paired: Date
        public var lastContact: Date?
        /// SHA-256 of the token; the token itself is only on the phone.
        var tokenHash: String
    }

    public nonisolated let store: BenchStore
    public nonisolated let name: String
    public private(set) var code: String
    public private(set) var devices: [Device] = []
    public private(set) var state: BenchHTTPServer.State = .stopped
    private var server: BenchHTTPServer?
    private var wrongCodes = 0
    private var hashes: [String: (modified: Date, bytes: Int, sha256: String)] = [:]
    private let events: @Sendable (Event) -> Void

    public init(store: BenchStore, name: String, events: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.store = store
        self.name = name
        self.events = events
        code = Self.newCode()
        devices = Self.loadDevices(store)
    }

    // MARK: - Running

    public func start(port: UInt16? = BenchProtocol.defaultPort, advertise: Bool = true) throws {
        guard server == nil else { return }
        try store.prepare()
        let server = BenchHTTPServer(scratch: store.url(.inbox).appending(path: ".uploads")) { [weak self] request in
            guard let self else { return .error(500, "the hub stopped") }
            return await handle(request)
        }
        try server.start(
            port: port, service: advertise ? (name, BenchProtocol.serviceType) : nil,
        ) { [weak self] state in
            Task { await self?.update(state) }
        }
        self.server = server
    }

    public func stop() {
        server?.stop()
        server = nil
        update(.stopped)
    }

    /// A new pairing code; phones already paired keep their tokens.
    public func renewCode() {
        code = Self.newCode()
        wrongCodes = 0
    }

    public func forget(device name: String) {
        devices.removeAll { $0.name == name }
        saveDevices()
    }

    private func update(_ state: BenchHTTPServer.State) {
        self.state = state
        events(.state(state))
    }

    // MARK: - Requests

    func handle(_ request: BenchHTTPRequest) async -> BenchHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"):
            return .html(Self.page)
        case ("GET", "/api/hub"):
            return .json(BenchProtocol.HubInfo(
                name: name,
                version: BenchProtocol.version,
                paired: device(request) != nil,
            ))
        case ("POST", "/api/pair"):
            return pair(request)
        default:
            break
        }
        guard let device = device(request) else { return .error(401, "pair with the code the Lab shows") }
        touch(device)
        if request.method == "GET", request.path == "/api/tasks" {
            return .json(listings())
        }
        if request.method == "GET", let parts = request.parts(after: "/api/tasks"), parts.count >= 2 {
            return file(task: parts[0], path: parts.dropFirst().joined(separator: "/"))
        }
        if request.method == "GET", request.path == "/api/done" {
            return .json(store.folders(.done).map(Self.receipt))
        }
        if request.method == "GET", let parts = request.parts(after: "/api/done"), parts.count == 1 {
            guard let folder = store.folder(parts[0], in: .done) else { return .error(404, "not in Done") }
            return .json(Self.receipt(folder))
        }
        if request.method == "POST", request.path == "/api/inbox" {
            return receive(request)
        }
        return .error(404, "no such endpoint")
    }

    private func pair(_ request: BenchHTTPRequest) -> BenchHTTPResponse {
        guard let pairing = try? JSONDecoder.bench.decode(BenchProtocol.PairRequest.self, from: request.body) else {
            return .error(400, "send a code and a device name")
        }
        let given = Data(pairing.code.trimmingCharacters(in: .whitespaces).utf8)
        guard given.count == code.utf8.count, zip(given, Data(code.utf8)).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            wrongCodes += 1
            if wrongCodes >= 5 {
                renewCode()
            }
            return .error(401, "that isn't the code the Lab shows")
        }
        wrongCodes = 0
        let token = (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
        let name = String(pairing.device.prefix(60))
        devices.removeAll { $0.name == name }
        devices.append(Device(name: name, paired: Date(), lastContact: Date(), tokenHash: Self.hash(token)))
        saveDevices()
        events(.paired(device: name))
        return .json(BenchProtocol.PairReply(token: token, hub: self.name))
    }

    private func device(_ request: BenchHTTPRequest) -> Device? {
        guard let value = request.header("authorization"), value.hasPrefix("Bearer ") else { return nil }
        let hash = Self.hash(String(value.dropFirst(7)))
        return devices.first { $0.tokenHash == hash }
    }

    private func touch(_ device: Device) {
        guard let index = devices.firstIndex(where: { $0.tokenHash == device.tokenHash }) else { return }
        let last = devices[index].lastContact ?? .distantPast
        devices[index].lastContact = Date()
        if Date().timeIntervalSince(last) > 60 {
            saveDevices()
        }
        events(.contact(device: device.name))
    }

    // MARK: - The outbox and templates

    /// Tasks waiting in the outbox, and the templates, with every file the phone should fetch.
    public func listings() -> [BenchProtocol.Listing] {
        let tasks = store.folders(.outbox).map { ($0, false) } + store.folders(.templates).map { ($0, true) }
        return tasks.compactMap { folder, template in
            guard let files = try? files(of: folder) else { return nil }
            let m = folder.manifest
            return BenchProtocol.Listing(
                id: m.id, title: m.title, kind: m.kind, revision: m.revision, withdrawn: m.withdrawn,
                template: template, created: m.created, files: files,
            )
        }
    }

    private func files(of folder: BenchFolder) throws -> [BenchProtocol.Listing.File] {
        var paths = [BenchManifest.fileName] + folder.manifest.assets.map(\.file)
        paths += folder.manifest.steps.compactMap(\.picture)
        if let screenshot = folder.manifest.look?.settingsScreenshot {
            paths.append(screenshot)
        }
        var seen = Set<String>()
        return try paths.filter { seen.insert($0).inserted }.map { path in
            guard let url = folder.file(path), BenchFile.isRegularFile(url) else {
                throw BenchError.notFound(path)
            }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values.contentModificationDate ?? .distantPast, bytes = values.fileSize ?? 0
            let sha256: String
            if let cached = hashes[url.path], cached.modified == modified, cached.bytes == bytes {
                sha256 = cached.sha256
            } else {
                sha256 = try BenchFile.sha256(url)
                hashes[url.path] = (modified, bytes, sha256)
            }
            return BenchProtocol.Listing.File(path: path, sha256: sha256, bytes: bytes)
        }
    }

    private func file(task id: String, path: String) -> BenchHTTPResponse {
        guard let folder = store.folder(id, in: .outbox) ?? store.folder(id, in: .templates) else {
            return .error(404, "no task \(id)")
        }
        guard let listed = try? files(of: folder), listed.contains(where: { $0.path == path }),
              let url = folder.file(path) else { return .error(404, "no file \(path) in \(id)") }
        return .file(url)
    }

    // MARK: - The inbox

    private func receive(_ request: BenchHTTPRequest) -> BenchHTTPResponse {
        let archive: URL
        if let file = request.bodyFile {
            archive = file
        } else {
            archive = store.url(.inbox).appending(path: ".uploads/body-\(UUID().uuidString)")
            do {
                try request.body.write(to: archive)
            } catch {
                return .error(500, "no room for the upload")
            }
        }
        defer {
            if request.bodyFile == nil {
                try? FileManager.default.removeItem(at: archive)
            }
        }
        #if os(macOS)
            do {
                let arrival = try store.receive(archive)
                events(.arrival(arrival))
                return .json(Self.receipt(arrival.folder))
            } catch {
                events(.refused("\(error)"))
                return .error(422, "\(error)")
            }
        #else
            return .error(405, "this hub can't unpack archives")
        #endif
    }

    static func receipt(_ folder: BenchFolder) -> BenchProtocol.Receipt {
        let received = (try? folder.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? folder.manifest.created
        return BenchProtocol.Receipt(
            id: folder.id, title: folder.manifest.look?.title ?? folder.manifest.title, kind: folder.manifest.kind,
            summary: folder.summary, complete: folder.isComplete, resultsDigest: folder.resultsDigest,
            received: received,
        )
    }

    // MARK: - Pairing state

    private struct DeviceFile: Codable {
        var devices: [Device]
    }

    private static func devicesURL(_ store: BenchStore) -> URL {
        store.root.appending(path: "hub-devices.json")
    }

    private static func loadDevices(_ store: BenchStore) -> [Device] {
        guard let data = try? Data(contentsOf: devicesURL(store)),
              let file = try? JSONDecoder.bench.decode(DeviceFile.self, from: data) else { return [] }
        return file.devices
    }

    private func saveDevices() {
        try? store.prepare()
        try? JSONEncoder.bench.encode(DeviceFile(devices: devices)).write(to: Self.devicesURL(store), options: .atomic)
    }

    static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0 ..< 1_000_000))
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let page: String = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "bench-page", withExtension: "html"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "<!doctype html><title>Redlamp Bench</title><p>The hub is running.</p>"
        }
        return text
    }()
}

private final class BundleToken {}
