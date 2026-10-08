import Foundation
import Network

/// Watches the local network for a Bonjour service for as long as it runs, reporting the list each
/// time it changes: the phone watches for the Lab's hub, and the Lab for phones running Redlamp
/// Bench.
public final class BonjourWatcher: @unchecked Sendable {
    public struct Service: Sendable, Hashable, Identifiable {
        public var name: String
        /// The service's TXT record.
        public var info: [String: String]
        let endpoint: NWEndpoint

        public var id: String {
            name
        }
    }

    private let type: String
    private let queue = DispatchQueue(label: "app.redlamp.bench.watch")
    private let changed: @Sendable ([Service]) -> Void
    private var browser: NWBrowser?

    public init(type: String, changed: @escaping @Sendable ([Service]) -> Void) {
        self.type = type
        self.changed = changed
    }

    public func start() {
        queue.sync {
            guard browser == nil else { return }
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [changed] results, _ in
                changed(results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    var info: [String: String] = [:]
                    if case let .bonjour(record) = result.metadata {
                        info = record.dictionary
                    }
                    return Service(name: name, info: info, endpoint: result.endpoint)
                }.sorted { $0.name < $1.name })
            }
            browser.start(queue: queue)
            self.browser = browser
        }
    }

    public func stop() {
        queue.sync {
            browser?.cancel()
            browser = nil
        }
    }
}

/// Advertises a Bonjour service that only says "here I am": the iPhone app, so the Lab can list
/// it nearby. It takes no connections.
public final class BonjourPresence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.redlamp.bench.presence")
    private var listener: NWListener?

    public init() {}

    public func start(name: String, type: String, info: [String: String]) {
        queue.sync {
            listener?.cancel()
            guard let listener = try? NWListener(using: .tcp) else { return }
            listener.service = NWListener.Service(name: name, type: type, txtRecord: NWTXTRecord(info))
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }
}
