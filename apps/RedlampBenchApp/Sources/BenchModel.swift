import Foundation
import Observation
import RedlampBench
import UIKit

/// The app's state: the folders on the phone, the hub, and the send queue.
@MainActor
@Observable
final class BenchModel {
    enum Hub: Equatable {
        case searching
        /// Found on the network, not paired yet.
        case found(name: String, url: URL)
        /// Asked to pair; waiting for Allow on the Mac.
        case asking(name: String)
        case connected(name: String)
        /// Paired before, but not reachable now: work waits in the queue.
        case away(name: String)
        case none
    }

    let library: BenchLibrary
    private(set) var tasks: [BenchFolder] = []
    private(set) var looks: [BenchFolder] = []
    private(set) var queue: [BenchLibrary.Queued] = []
    private(set) var sent: [String: String] = [:]
    private(set) var sentAt: [String: Date] = [:]
    /// The folder being uploaded, and how far it's got.
    private(set) var sending: (id: String, progress: Double?)?
    /// Counts folders the Lab confirmed, for the haptic that says so.
    private(set) var confirmed = 0
    /// Each folder's current step, by ID.
    private var steps: [String: Int] = UserDefaults.standard.dictionary(forKey: "steps") as? [String: Int] ?? [:]
    private(set) var hub: Hub = .none
    private(set) var syncing = false
    private(set) var message: String?
    /// The folders open on the navigation stack, by ID.
    var path: [String] = []
    /// A folder to open once the app is up.
    var opened: String?
    private var lastAttempt = Date.distantPast
    private var uploading = false
    private var sendAgain = false
    /// Labs on the network, as Bonjour reports them while the app is open.
    private var labs: [BonjourWatcher.Service] = []
    @ObservationIgnored private var watcher: BonjourWatcher?
    @ObservationIgnored private let presence = BonjourPresence()

    init(library: BenchLibrary = BenchShared.library) {
        self.library = library
        reload()
    }

    /// Reads the folders and the queue again: after a change here, or one the share extension
    /// made while the app was in the background.
    func reload() {
        tasks = library.tasks
        looks = library.looks
        queue = library.queue
        sent = library.sent
        sentAt = library.sentAt
    }

    func folder(_ id: String) -> BenchFolder? {
        tasks.first { $0.id == id } ?? looks.first { $0.id == id }
    }

    func status(_ folder: BenchFolder) -> FolderStatus {
        FolderStatus(folder, queue: queue, sent: sent, sentAt: sentAt, sending: sending)
    }

    /// Whether finished work has to wait for the Lab.
    var labAway: Bool {
        switch hub {
        case .connected: false
        default: true
        }
    }

    var waitingToSend: Int {
        queue.count
    }

    // MARK: - The hub

    /// This phone's name, as the Lab lists it.
    var device: String {
        library.settings.device ?? UIDevice.current.name
    }

    /// Watches for the Lab and announces the phone while the app is in the foreground.
    func startWatching() {
        guard watcher == nil else { return }
        let watcher = BonjourWatcher(type: BenchProtocol.serviceType) { [weak self] found in
            Task { @MainActor in self?.labsChanged(found) }
        }
        watcher.start()
        self.watcher = watcher
        presence.start(
            name: device, type: BenchProtocol.phoneServiceType,
            info: ["paired": library.settings.token == nil ? "0" : "1"],
        )
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        presence.stop()
    }

    private func labsChanged(_ found: [BonjourWatcher.Service]) {
        labs = found
        switch hub {
        case .connected, .asking:
            return
        default:
            Task { await refresh() }
        }
    }

    /// The Lab this phone is paired with if it's on the network, or else the first one found.
    private var lab: BonjourWatcher.Service? {
        labs.first { $0.name == library.settings.hubName } ?? labs.first
    }

    /// Reaches the paired hub, or the one on the network, then pulls tasks and sends what's queued.
    func refresh() async {
        guard !syncing else { return }
        syncing = true
        defer {
            syncing = false
            reload()
        }
        lastAttempt = Date()
        let settings = library.settings
        if let client = BenchShared.client(library) {
            do {
                let info = try await client.info()
                if info.paired {
                    hub = .connected(name: info.name)
                    try await sync(client)
                    return
                }
            } catch {
                hub = .away(name: settings.hubName ?? "the Lab")
            }
        }
        // The address may have changed (a new port, a new network): use what Bonjour sees.
        guard let lab, let url = await BenchDiscovery.address(of: lab) else {
            if settings.token == nil {
                hub = watcher == nil ? .none : .searching
            } else {
                hub = .away(name: settings.hubName ?? "the Lab")
            }
            return
        }
        if let token = settings.token {
            let client = BenchClient(base: url, token: token)
            if await (try? client.info())?.paired == true {
                var updated = library.settings
                updated.hub = url
                updated.hubName = lab.name
                library.settings = updated
                hub = .connected(name: lab.name)
                try? await sync(client)
                return
            }
        }
        hub = .found(name: lab.name, url: url)
    }

    /// Refreshes at most every few minutes while the app is open.
    func refreshIfStale() async {
        if Date().timeIntervalSince(lastAttempt) > 180 {
            await refresh()
        }
    }

    /// Asks the Lab found on the network to pair, and waits for Allow on the Mac.
    func pairWithLab() async {
        guard case let .found(name, url) = hub else { return }
        hub = .asking(name: name)
        message = nil
        do {
            let reply = try await BenchClient(base: url).pairByApproval(device: device)
            await paired(reply, url: url)
        } catch let BenchClientError.http(status, _) where status == 403 || status == 408 {
            message = status == 403 ? "\(name) didn't allow this phone" : "No answer from \(name); try again"
            hub = .found(name: name, url: url)
        } catch {
            message = "\(error)"
            hub = .found(name: name, url: url)
        }
    }

    func pair(code: String, device: String, url: URL) async {
        do {
            let reply = try await BenchClient(base: url).pair(code: code, device: device)
            var settings = library.settings
            settings.device = device
            library.settings = settings
            await paired(reply, url: url)
        } catch {
            message = "\(error)"
        }
    }

    private func paired(_ reply: BenchProtocol.PairReply, url: URL) async {
        var settings = library.settings
        settings.hub = url
        settings.hubName = reply.hub
        settings.token = reply.token
        settings.device = settings.device ?? device
        library.settings = settings
        message = nil
        hub = .connected(name: reply.hub)
        if watcher != nil {
            stopWatching()
            startWatching()
        }
        await refresh()
    }

    /// Pairs with a hub at an address typed by hand, when Bonjour doesn't find it.
    func pair(code: String, device: String, address: String) async {
        let text = address.contains("://") ? address : "http://\(address)"
        guard let url = URL(string: text.hasSuffix("/") ? text : text + "/") else {
            message = "That isn't an address"
            return
        }
        await pair(code: code, device: device, url: url)
    }

    private func sync(_ client: BenchClient) async throws {
        let report = try await library.pull(client)
        var notes: [String] = []
        if !report.added.isEmpty {
            notes.append("\(report.added.count) new task\(report.added.count == 1 ? "" : "s")")
        }
        if report.kitUpdated {
            notes.append("the capture kit updated")
        }
        message = notes.isEmpty ? nil : notes.joined(separator: ", ").capitalizedFirst
        await send(client)
    }

    /// Sends the queue, once at a time: what's queued meanwhile goes in another round.
    private func send(_ client: BenchClient) async {
        guard !uploading else {
            sendAgain = true
            return
        }
        uploading = true
        defer { uploading = false }
        repeat {
            sendAgain = false
            let outcomes = await library.sendQueued(client) { event in
                Task { @MainActor [weak self] in self?.sendingChanged(event) }
            }
            sending = nil
            for (id, outcome) in outcomes {
                switch outcome {
                case .success: confirmed += 1
                case let .failure(error): message = "Couldn't send \(folder(id)?.manifest.title ?? id): \(error)"
                }
            }
            reload()
        } while sendAgain
    }

    private func sendingChanged(_ event: BenchLibrary.Sending) {
        switch event {
        case let .started(id):
            sending = (id, nil)
        case let .progress(id, done):
            // A redraw for each percent, not for each packet.
            if sending?.id == id, let shown = sending?.progress, abs(shown - done) < 0.01, done < 1 {
                return
            }
            sending = (id, done)
        case .finished:
            sending = nil
            reload()
        }
    }

    /// Sends what's queued, with time to finish if the app goes to the background.
    func sendQueued() async {
        guard !library.queue.isEmpty, let client = BenchShared.client(library) else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Send to the Lab")
        await send(client)
        UIApplication.shared.endBackgroundTask(task)
        reload()
    }

    // MARK: - Working a folder

    func answer(_ folder: BenchFolder, question: String, with choice: String) {
        guard var folder = library.folder(folder.id) else { return }
        folder.results.answers[question] = choice
        try? folder.saveResults()
        afterChange(folder)
    }

    func note(_ folder: BenchFolder, _ text: String) {
        guard var folder = library.folder(folder.id) else { return }
        folder.results.note = text.isEmpty ? nil : text
        try? folder.saveResults()
        reload()
    }

    func pair(_ result: BenchResult, with asset: String?, in folder: BenchFolder) {
        guard var folder = library.folder(folder.id) else { return }
        try? folder.pair(result: result.id, with: asset)
        afterChange(folder)
    }

    func remove(_ result: BenchResult, from folder: BenchFolder) {
        guard var folder = library.folder(folder.id) else { return }
        try? folder.removeResult(result.id)
        reload()
    }

    /// Sends what's queued now, as Try Again does after a failure.
    func retry() {
        Task { await refresh() }
    }

    /// The owner says a manual task is done.
    func markDone(_ folder: BenchFolder) {
        guard var folder = library.folder(folder.id) else { return }
        folder.results.completed = Date()
        try? folder.saveResults()
        afterChange(folder)
    }

    /// Queues a folder even though it isn't complete.
    func sendNow(_ folder: BenchFolder) {
        guard let folder = library.folder(folder.id) else { return }
        library.enqueue(folder)
        reload()
        Task { await refresh() }
    }

    func delete(_ folder: BenchFolder) {
        try? library.remove(folder.id)
        reload()
    }

    func used(_ folder: BenchFolder) {
        library.markUsed(folder.id)
    }

    /// Results filed by the app itself (Add from Photos), as the share extension files them.
    func add(_ files: [(url: URL, name: String)], to folder: BenchFolder) {
        do {
            let (updated, _) = try BenchShared.file(files, into: folder.id, library: library)
            afterChange(updated)
        } catch {
            message = "\(error)"
        }
    }

    private func afterChange(_ folder: BenchFolder) {
        if library.enqueueIfComplete(folder) {
            Task { await sendQueued() }
        }
        reload()
    }

    // MARK: - Looks

    var kitAvailable: Bool {
        library.kit != nil
    }

    func newLook(_ look: BenchManifest.LookReference, screenshot: URL?) -> BenchFolder? {
        do {
            let folder = try library.newLook(look, screenshot: screenshot)
            reload()
            return folder
        } catch {
            message = "\(error)"
            return nil
        }
    }

    /// The last look reference, to prefill the next one with its variant counted up.
    var nextLook: BenchManifest.LookReference? {
        guard var look = looks.first?.manifest.look else { return nil }
        if let variant = look.variant, let number = Int(variant) {
            look.variant = "\(number + 1)"
        }
        look.settingsScreenshot = nil
        return look
    }

    /// Apps typed before, for New Look's suggestions.
    var knownApps: [String] {
        Array(Set(looks.compactMap { $0.manifest.look?.app }.filter { !$0.isEmpty })).sorted()
    }

    // MARK: - Steps

    func step(for folder: BenchFolder) -> Int {
        min(steps[folder.id] ?? 0, max(0, folder.manifest.steps.count - 1))
    }

    func setStep(_ index: Int, for folder: BenchFolder) {
        steps[folder.id] = max(0, min(index, folder.manifest.steps.count - 1))
        UserDefaults.standard.set(steps, forKey: "steps")
    }
}

extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
