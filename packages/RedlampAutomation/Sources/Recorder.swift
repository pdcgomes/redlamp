#if DEBUG || REDLAMP_PROFILING
    import Foundation
    import Synchronization

    /// Writes the run's events as JSON Lines, as they happen (`events.jsonl`), so a crash or a
    /// hang still leaves everything up to it for the supervisor, and the coverage at the end.
    final class Recorder: Sendable {
        private let events: URL
        private let coverageURL: URL
        private let state = Mutex<State>(State())

        private struct State {
            var handle: FileHandle?
            var coverage: [String: Set<String>] = [:]
            var scenario: String?
        }

        init(directory: URL, launch: String) {
            events = directory.appending(path: "events-\(launch).jsonl")
            coverageURL = directory.appending(path: "coverage-\(launch).json")
            if !FileManager.default.fileExists(atPath: events.path) {
                FileManager.default.createFile(atPath: events.path, contents: nil)
            }
            let handle = try? FileHandle(forWritingTo: events)
            _ = try? handle?.seekToEnd()
            state.withLock { $0.handle = handle }
        }

        var currentScenario: String? {
            get { state.withLock { $0.scenario } }
            set { state.withLock { $0.scenario = newValue } }
        }

        /// One line: `event` and its fields, with the time and the scenario running.
        func write(_ event: String, _ fields: [String: Any] = [:]) {
            var line = fields
            line["event"] = event
            line["time"] = Date().timeIntervalSince1970
            state.withLock { state in
                if let scenario = state.scenario, line["scenario"] == nil {
                    line["scenario"] = scenario
                }
                guard JSONSerialization.isValidJSONObject(line),
                      var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
                else { return }
                data.append(0x0A)
                state.handle?.write(data)
                try? state.handle?.synchronize()
            }
        }

        func cover(_ claim: Claim, via path: InputPath) {
            state.withLock { _ = $0.coverage[claim.description, default: []].insert(path.rawValue) }
        }

        /// Adds this launch's coverage to what earlier launches of the same group recorded.
        func writeCoverage(menuItems: [String]) {
            var coverage = state.withLock { $0.coverage }
            if let data = try? Data(contentsOf: coverageURL),
               let earlier = (try? JSONSerialization
                   .jsonObject(with: data) as? [String: Any])?["claims"] as? [String: [String]] {
                for (claim, paths) in earlier {
                    coverage[claim, default: []].formUnion(paths)
                }
            }
            let object: [String: Any] = [
                "claims": coverage.mapValues { $0.sorted() },
                "menuItems": menuItems,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: coverageURL, options: .atomic)
            }
        }
    }
#endif
