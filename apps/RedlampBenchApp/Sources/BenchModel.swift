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
        /// Found on the network, waiting for the Lab's pairing code.
        case found(name: String, url: URL)
        case connected(name: String)
        /// Paired before, but not reachable now: work waits in the queue.
        case away(name: String)
        case none
    }

    let library: BenchLibrary
    private(set) var tasks: [BenchFolder] = []
    private(set) var looks: [BenchFolder] = []
    private(set) var hub: Hub = .none
    private(set) var syncing = false
    private(set) var message: String?
    /// The folders open on the navigation stack, by ID.
    var path: [String] = []
    /// A folder to open once the app is up.
    var opened: String?
    private var lastAttempt = Date.distantPast

    init(library: BenchLibrary = BenchShared.library) {
        self.library = library
        reload()
    }

    func reload() {
        tasks = library.tasks
        looks = library.looks
    }

    func folder(_ id: String) -> BenchFolder? {
        library.folder(id)
    }

    var queued: Set<String> {
        Set(library.queue.map(\.id))
    }

    func isSent(_ folder: BenchFolder) -> Bool {
        library.sent[folder.id] == folder.resultsDigest
    }

    // MARK: - The hub

    /// Reaches the paired hub, or looks for one, then pulls tasks and sends what's queued.
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
        // The address may have changed (a new port, a new network): look again.
        if case .away = hub {} else {
            hub = .searching
        }
        let found = await BenchDiscovery.find()
        guard let first = found.first else {
            if settings.token == nil {
                hub = .none
            } else if case .searching = hub {
                hub = .away(name: settings.hubName ?? "the Lab")
            }
            return
        }
        if let token = settings.token {
            let client = BenchClient(base: first.url, token: token)
            if await (try? client.info())?.paired == true {
                var updated = library.settings
                updated.hub = first.url
                updated.hubName = first.name
                library.settings = updated
                hub = .connected(name: first.name)
                try? await sync(client)
                return
            }
        }
        hub = .found(name: first.name, url: first.url)
    }

    /// Refreshes at most every few minutes while the app is open.
    func refreshIfStale() async {
        if Date().timeIntervalSince(lastAttempt) > 180 {
            await refresh()
        }
    }

    func pair(code: String, device: String, url: URL, name _: String) async {
        do {
            let reply = try await BenchClient(base: url).pair(code: code, device: device)
            var settings = library.settings
            settings.hub = url
            settings.hubName = reply.hub
            settings.token = reply.token
            settings.device = device
            library.settings = settings
            message = nil
            hub = .connected(name: reply.hub)
            await refresh()
        } catch {
            message = "\(error)"
        }
    }

    /// Pairs with a hub at an address typed by hand, when Bonjour doesn't find it.
    func pair(code: String, device: String, address: String) async {
        let text = address.contains("://") ? address : "http://\(address)"
        guard let url = URL(string: text.hasSuffix("/") ? text : text + "/") else {
            message = "That isn't an address"
            return
        }
        await pair(code: code, device: device, url: url, name: address)
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

    private func send(_ client: BenchClient) async {
        for (id, outcome) in await library.sendQueued(client) {
            if case let .failure(error) = outcome {
                message = "Couldn't send \(library.folder(id)?.manifest.title ?? id): \(error)"
            }
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
        min(UserDefaults.standard.integer(forKey: "step.\(folder.id)"), max(0, folder.manifest.steps.count - 1))
    }

    func setStep(_ index: Int, for folder: BenchFolder) {
        UserDefaults.standard.set(index, forKey: "step.\(folder.id)")
    }
}

extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
