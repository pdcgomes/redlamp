#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// The regression suite's entry point in the app (`--e2e <run directory> --e2e-launch <group>`).
    ///
    /// The supervisor (`scripts/e2e.py`) writes `plan-<group>.json` in the run directory: the
    /// scenarios to run in this launch, in order, whether focus is allowed, and the seed.
    @MainActor
    public enum Automation {
        struct Plan: Decodable {
            var scenarios: [String]
            var focus: Bool
            var seed: UInt64
            var photos: String
            var steps: [String]?
            var knownIssues: [String: String]?
            /// Stalls in the system's own code, by a frame of their stack, with why.
            var knownStalls: [String: String]?
        }

        /// `--e2e-list <file>` writes the catalogue (scenarios, their claims, and every claim the
        /// contract requires) and exits, before the app opens a window or an engine.
        public static func listIfRequested(arguments: [String]) {
            guard let index = arguments.firstIndex(of: "--e2e-list"), index + 1 < arguments.count else { return }
            let url = URL(fileURLWithPath: arguments[index + 1])
            do {
                try Catalogue.json().write(to: url, options: .atomic)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("couldn't write the catalogue: \(error)\n".utf8))
                exit(2)
            }
        }

        public static func startIfRequested(model: EditorModel, arguments: [String], host: AutomationHost? = nil) {
            func value(after flag: String) -> String? {
                arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            }
            guard let directory = value(after: "--e2e").map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
                return
            }
            let launch = value(after: "--e2e-launch") ?? LaunchGroup.main.rawValue
            let recorder = Recorder(directory: directory, launch: launch)
            guard let data = try? Data(contentsOf: directory.appending(path: "plan-\(launch).json")),
                  let plan = try? JSONDecoder().decode(Plan.self, from: data)
            else {
                recorder.write("launch-failed", ["reason": "no readable plan-\(launch).json"])
                NSApp.terminate(nil)
                return
            }
            // A run in the background keeps rendering at full speed.
            nonisolated(unsafe) let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled], reason: "Regression suite",
            )
            let app = RunningApp(
                model: model, recorder: recorder, photos: URL(fileURLWithPath: plan.photos),
                runDirectory: directory, allowsFocus: plan.focus, seed: plan.seed, steps: plan.steps ?? [],
                knownIssues: plan.knownIssues ?? [:], knownStalls: plan.knownStalls ?? [:], host: host,
            )
            let watchdog = Watchdog(recorder: recorder)
            recorder.write("launch", [
                "group": launch, "scenarios": plan.scenarios, "focus": plan.focus, "seed": plan.seed,
                "pid": Int(ProcessInfo.processInfo.processIdentifier), "footprintMB": Memory.footprint(),
                "bundle": Bundle.main.bundleIdentifier ?? "",
            ])
            let thread = Thread {
                Runner(app: app, recorder: recorder, watchdog: watchdog, launch: launch).run(plan.scenarios)
                ProcessInfo.processInfo.endActivity(activity)
            }
            thread.name = "Regression suite"
            thread.stackSize = 8 << 20
            watchdog.start()
            thread.start()
        }
    }

    struct Runner {
        let app: RunningApp
        let recorder: Recorder
        let watchdog: Watchdog
        let launch: String
        /// Whether the editor can still be used; a dialog that won't close ends the launch, and
        /// the supervisor runs the rest in a fresh one.
        private let state = UsableBox()
        private var usable: Bool {
            get { state.value }
            nonmutating set { state.value = newValue }
        }

        func run(_ ids: [String]) {
            let launched = Date()
            let catalogue = Dictionary(uniqueKeysWithValues: Catalogue.all.map { ($0.id, $0) })
            do {
                try app.wait("the editor window", timeout: 60) { _ in Views.editorWindow != nil }
                if launch != LaunchGroup.relaunch.rawValue {
                    try app.settle(timeout: 90)
                }
                recorder.write(
                    "ready",
                    ["seconds": Date().timeIntervalSince(launched), "footprintMB": Memory.footprint()],
                )
            } catch {
                recorder.write("launch-failed", ["reason": "\(error)"])
                finish()
                return
            }
            for id in ids {
                guard usable else {
                    recorder.write("launch-abandoned", ["reason": "a dialog wouldn't close", "next": id])
                    break
                }
                guard let scenario = catalogue[id] else {
                    recorder.write("scenario-end", ["scenario": id, "status": "failed", "message": "No scenario \(id)"])
                    continue
                }
                run(scenario)
            }
            finish()
        }

        private func run(_ scenario: Scenario) {
            guard usable else { return }
            recorder.currentScenario = scenario.id
            recorder.write("scenario-start", ["title": scenario.title])
            _ = watchdog.takeStalls()
            let monitor = try? MainThread.run { () -> MainThreadMonitorBox in
                let monitor = MainThreadMonitor()
                monitor.start()
                return MainThreadMonitorBox(monitor)
            }
            let started = Date()
            let before = Memory.footprint()
            var status = "passed"
            var message = ""
            do {
                try scenario.run(app)
            } catch let skip as ScenarioSkip {
                status = "skipped"
                message = skip.reason
            } catch {
                status = "failed"
                message = "\(error)"
            }
            let seconds = Date().timeIntervalSince(started)
            let summary = try? MainThread.run { () -> MainThreadMonitor.Summary? in
                monitor?.monitor.stop()
                return monitor?.monitor.summary()
            }
            let stalls = watchdog.takeStalls().filter { stall in
                guard let known = app.knownStalls
                    .first(where: { frame, _ in stall.stack.contains { $0.contains(frame) } })
                else { return true }
                recorder.write("known-stall", ["seconds": stall.seconds, "reason": known.value])
                return false
            }
            if status == "passed", let longest = stalls.map(\.seconds).max() {
                status = "failed"
                message = String(format: "The main thread stalled for %.1f s", longest)
            }
            var fields: [String: Any] = [
                "status": status, "seconds": seconds, "footprintMB": Memory.footprint(), "footprintBeforeMB": before,
            ]
            if !message.isEmpty {
                fields["message"] = message
            }
            if let summary = summary ?? nil {
                fields["mainP99ms"] = summary.p99
                fields["mainMaxms"] = summary.max
                fields["mainOverTwoFrames"] = summary.overTwoFrames
            }
            if status == "failed" {
                let shot = app.runDirectory.appending(path: "failures/\(scenario.id).png")
                try? FileManager.default.createDirectory(
                    at: shot.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                try? MainThread.run { Snapshot.capture(to: shot) }
                fields["snapshot"] = shot.path
            }
            recorder.write("scenario-end", fields)
            recorder.currentScenario = nil
            // After every scenario, so a launch stopped later keeps what it covered.
            recorder.writeCoverage(menuItems: [])
            usable = app.recover()
        }

        private func finish() {
            let menu = (try? MainThread.run { Menus.allTitles() }) ?? []
            recorder.writeCoverage(menuItems: menu)
            recorder.write("launch-end", ["footprintMB": Memory.footprint()])
            watchdog.stop()
            MainThread.post { NSApp.terminate(nil) }
        }
    }

    final class UsableBox: @unchecked Sendable {
        var value = true
    }

    /// Carries the monitor from the main thread to the driver's and back; it's only touched on main.
    final class MainThreadMonitorBox: @unchecked Sendable {
        let monitor: MainThreadMonitor
        init(_ monitor: MainThreadMonitor) {
            self.monitor = monitor
        }
    }

    extension RunningApp {
        /// Puts the editor back as a scenario expects to find it, whatever the last one left:
        /// no dialog, no palette, the Edit tool, the photo open. Returns whether it could.
        @discardableResult
        func recover() -> Bool {
            for _ in 0 ..< 3
                where (try? main({ _ in NSApp.modalWindow != nil || Views.editorWindow?.attachedSheet != nil })) ==
                true {
                _ = try? pressInSheet(KeyCombo(.escape))
                pause(0.3)
            }
            try? main { model in
                if let modal = NSApp.modalWindow {
                    NSApp.stopModal()
                    modal.sheetParent?.endSheet(modal)
                    modal.orderOut(nil)
                }
                if model.commandPalette != nil {
                    model.closeCommandPalette()
                }
                if model.drawingKind != nil {
                    model.perform(.cancel)
                }
                model.activeTool = .edit
                model.showShortcuts = false
                for window in NSApp.windows
                    where window.isVisible && !(window.windowController is EditorWindowController)
                    && window.level == .normal && window.title != "" && !window.isSheet {
                    window.close()
                }
            }
            pause(0.2)
            return (try? main { model in !model.isModalDialogOpen && Views.editorWindow?.attachedSheet == nil }) ??
                false
        }
    }
#endif
