import AppKit
import Observation
import OSLog
import RedlampLibrary

/// The naming templates people save (LIB-25), beside Lightroom Classic's nine and Redlamp's own, for Rename
/// Photos and the import window, and the named counters renames carry on, in the library's folder as
/// `Naming Presets.json`. A preset this version can't read, a newer Redlamp's, is kept as it was written.
@MainActor
@Observable
public final class NamingPresetStore {
    /// The presets saved, in the order they were saved.
    public private(set) var saved: [NamingPreset] = []
    /// Where `{counter:…}` carries on from, as the last rename left it.
    public private(set) var counters = NamingCounters()
    /// The template and options Rename Photos used last, which it opens with.
    public private(set) var lastRename: NamingPreset?
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var unread: [Data] = []
    /// The file is written off the main thread, in order, and before the app quits: a rename's writes took tens of
    /// milliseconds of the main thread under load.
    @ObservationIgnored private let writes = DispatchQueue(label: "app.redlamp.naming-presets", qos: .utility)

    private nonisolated static let log = Logger(subsystem: "app.redlamp.mac", category: "library")
    private static var stores: [URL: NamingPresetStore] = [:]

    /// Nil keeps them in memory only.
    public init(url: URL?) {
        self.url = url
        if url != nil {
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil,
            ) { [writes] _ in writes.sync {} }
        }
        guard let url, let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        for preset in object["presets"] as? [Any] ?? [] {
            guard let data = try? JSONSerialization.data(withJSONObject: preset) else { continue }
            if let read = try? JSONDecoder().decode(NamingPreset.self, from: data) {
                saved.append(read)
            } else {
                unread.append(data)
            }
        }
        if let counters = object["counters"], let data = try? JSONSerialization.data(withJSONObject: counters) {
            self.counters = (try? JSONDecoder().decode(NamingCounters.self, from: data)) ?? NamingCounters()
        }
        if let last = object["lastRename"], let data = try? JSONSerialization.data(withJSONObject: last) {
            lastRename = try? JSONDecoder().decode(NamingPreset.self, from: data)
        }
    }

    /// The store of the library whose folder `paths` names, made once.
    public static func shared(for paths: LibraryPaths) -> NamingPresetStore {
        let url = paths.root.appending(path: "Naming Presets.json")
        if let store = stores[url] {
            return store
        }
        let store = NamingPresetStore(url: url)
        stores[url] = store
        return store
    }

    /// The built-in presets, then those saved.
    public var all: [NamingPreset] {
        NamingPreset.builtIn + saved
    }

    /// Saves `template` with `options` as `name`, in place of a saved preset of that name, ignoring case; nil
    /// for an empty name or a built-in preset's.
    @discardableResult
    public func save(_ name: String, template: NamingTemplate, options: NamingOptions) -> NamingPreset? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let same = { (preset: NamingPreset) in preset.name.caseInsensitiveCompare(name) == .orderedSame }
        guard !name.isEmpty, !NamingPreset.builtIn.contains(where: same) else { return nil }
        let preset: NamingPreset
        if let index = saved.firstIndex(where: same) {
            saved[index].name = name
            saved[index].template = template
            saved[index].options = options
            preset = saved[index]
        } else {
            preset = NamingPreset(name: name, template: template, options: options)
            saved.append(preset)
        }
        write()
        return preset
    }

    public func delete(_ id: String) {
        guard saved.contains(where: { $0.id == id }) else { return }
        saved.removeAll { $0.id == id }
        write()
    }

    /// The counters as a rename left them.
    func setCounters(_ moved: NamingCounters) {
        guard moved != counters else { return }
        counters = moved
        write()
    }

    func setLastRename(_ template: NamingTemplate, options: NamingOptions) {
        guard lastRename?.template != template || lastRename?.options != options else { return }
        lastRename = NamingPreset(id: "last-rename", name: "Last Rename", template: template, options: options)
        write()
    }

    /// Returns once what was saved so far is on disk.
    func flush() {
        writes.sync {}
    }

    private func write() {
        guard let url else { return }
        let data: Data
        do {
            let encoder = JSONEncoder()
            var presets = try unread.map { try JSONSerialization.jsonObject(with: $0) }
            presets += try saved.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
            var object: [String: Any] = try [
                "presets": presets, "counters": JSONSerialization.jsonObject(with: encoder.encode(counters)),
            ]
            if let lastRename {
                object["lastRename"] = try JSONSerialization.jsonObject(with: encoder.encode(lastRename))
            }
            data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        } catch {
            return Self.failed(error)
        }
        writes.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                try data.write(to: url, options: .atomic)
            } catch {
                Self.failed(error)
            }
        }
    }

    private nonisolated static func failed(_ error: any Error) {
        log.error("The naming presets weren't saved: \(String(describing: error), privacy: .public)")
    }
}
