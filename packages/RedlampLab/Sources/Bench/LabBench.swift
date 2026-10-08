import Foundation
import Observation
import RedlampBench
import SystemConfiguration

/// The Recipe Lab's bench hub (ARC-13): one per process, remembered on or off. It serves the
/// outbox and the capture kit to the iPhone app, and files what comes back in Done. The harness
/// starts it at launch; the Lab's Bench tab shows it.
@MainActor
@Observable
public final class LabBench {
    public static let shared = LabBench()
    static let enabledKey = "bench.hub.enabled"

    public struct Event: Identifiable, Sendable {
        public let id = UUID()
        public let at: Date
        public let text: String
        public let isProblem: Bool
    }

    public nonisolated let store: BenchStore
    public private(set) var state: BenchHTTPServer.State = .stopped
    public private(set) var code = ""
    public private(set) var devices: [BenchHub.Device] = []
    public private(set) var outbox: [BenchFolder] = []
    public private(set) var done: [BenchFolder] = []
    public private(set) var templates: [BenchFolder] = []
    public private(set) var events: [Event] = []
    /// Called on every arrival; the Lab's Looks tab fits look references from here.
    @ObservationIgnored public var onArrival: (@MainActor (BenchStore.Arrival) -> Void)?
    @ObservationIgnored private var hub: BenchHub?
    @ObservationIgnored private let defaults: UserDefaults

    public init(store: BenchStore = BenchStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        refresh()
    }

    public var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    /// The hub's name on the network: "Redlamp Lab on <this Mac>".
    public nonisolated static var hubName: String {
        "Redlamp Lab on \(Host.current().localizedName ?? "this Mac")"
    }

    /// The address a browser can use: the Mac's Bonjour name, which needs no DNS lookup
    /// (`ProcessInfo.hostName` can block the main thread on one).
    public var address: String? {
        guard case let .ready(port) = state else { return nil }
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } ?? "localhost"
        return "http://\(host):\(port)/"
    }

    // MARK: - Running

    /// Starts the hub if it was on when the Lab last ran.
    public func startIfEnabled() {
        if isEnabled {
            start()
        }
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        enabled ? start() : stop()
    }

    public func start() {
        guard hub == nil else { return }
        let hub = BenchHub(store: store, name: Self.hubName) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.hub = hub
        Task {
            do {
                try await hub.start()
                code = await hub.code
                devices = await hub.devices
            } catch {
                state = .failed("\(error)")
                self.hub = nil
            }
        }
    }

    public func stop() {
        guard let hub else { return }
        self.hub = nil
        Task { await hub.stop() }
        state = .stopped
    }

    public func renewCode() {
        guard let hub else { return }
        Task {
            await hub.renewCode()
            code = await hub.code
        }
    }

    public func forget(_ device: BenchHub.Device) {
        guard let hub else { return }
        Task {
            await hub.forget(device: device.name)
            devices = await hub.devices
        }
    }

    public func refresh() {
        outbox = store.folders(.outbox)
        done = store.folders(.done)
        templates = store.folders(.templates)
    }

    private func handle(_ event: BenchHub.Event) {
        switch event {
        case let .state(state):
            self.state = state
        case let .arrival(arrival):
            let title = arrival.folder.manifest.look?.title ?? arrival.folder.manifest.title
            note("\(title): \(arrival.summary)" + (arrival.folder.isComplete ? "" : ", not complete yet"))
            refresh()
            onArrival?(arrival)
        case let .refused(reason):
            note("Refused an upload: \(reason)", problem: true)
        case let .paired(device):
            note("Paired \(device)")
            Task {
                if let hub {
                    devices = await hub.devices
                }
            }
        case .contact:
            Task {
                if let hub {
                    devices = await hub.devices
                }
            }
        }
    }

    private func note(_ text: String, problem: Bool = false) {
        events.insert(Event(at: Date(), text: text, isProblem: problem), at: 0)
        events = Array(events.prefix(50))
    }

    // MARK: - Arrivals by hand

    /// Files a `.redtask` opened in the harness, or a bench folder dropped on the Lab.
    @discardableResult
    public func receive(_ url: URL) -> BenchStore.Arrival? {
        do {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let arrival = try isFolder ? store.file(url) : store.receive(url)
            let title = arrival.folder.manifest.look?.title ?? arrival.folder.manifest.title
            note("\(title): \(arrival.summary) (from \(url.lastPathComponent))")
            refresh()
            onArrival?(arrival)
            return arrival
        } catch {
            note("Couldn't file \(url.lastPathComponent): \(error)", problem: true)
            return nil
        }
    }
}
