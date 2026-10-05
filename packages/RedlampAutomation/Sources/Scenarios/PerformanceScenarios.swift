#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// Adds `value` for `metric` (an ID in docs/performance/metrics.json) to the run's metrics.json.
        func record(_ metric: String, _ value: Double) {
            let url = runDirectory.appending(path: "metrics.json")
            var metrics = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Double] ?? [:]
            metrics[metric] = value
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: url, options: .atomic)
            }
            recorder.write("metric", ["metric": metric, "value": value])
        }

        /// How long `body` takes, in milliseconds.
        func milliseconds(_ body: () throws -> Void) rethrows -> Double {
            let start = Date()
            try body()
            return Date().timeIntervalSince(start) * 1000
        }
    }

    enum PerformanceScenarios {
        static let all: [Scenario] = [openAndSwitch, drag, export, palette]

        static let openAndSwitch = Scenario(
            "performance.open", "Opening each raw from the filmstrip to its first frame, and memory after all of them",
            tiers: [.performance], claims: [.feature("performance.slow-editing")],
        ) { app in
            let raws = ["arw", "raf", "cr3", "nef", "dng"]
            let names = try app.photoNames().filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }
            var times: [Double] = []
            for name in names + names {
                try app.open(names.first { $0 != name } ?? name)
                try times.append(app.milliseconds { try app.open(name) })
            }
            let sorted = times.sorted()
            app.record("e2e-open", sorted[sorted.count / 2])
            app.record("e2e-footprint", Memory.footprint())
            app.covered(.feature("performance.slow-editing"), via: .key)
        }

        static let drag = Scenario(
            "performance.drag", "Dragging Exposure at 120 events a second: the main thread and the frames",
            tiers: [.performance], claims: [],
        ) { app in
            try app.openWorking()
            try app.main { $0.expandedPanels = Set(PanelID.allCases) }
            app.pause(0.5)
            let monitor = try MainThread.run { () -> MainThreadMonitorBox in
                let monitor = MainThreadMonitor()
                monitor.start()
                return MainThreadMonitorBox(monitor)
            }
            let frames = try app.frames()
            try app.main { $0.beginEdit(.exposure) }
            let start = Date()
            var step = 0
            while Date().timeIntervalSince(start) < 3 {
                let value = sin(Double(step) / 20) * 2
                app.post { $0.setSliderValue(.exposure, value) }
                step += 1
                app.pause(1.0 / 120)
            }
            try app.main { $0.endEdit(name: nil) }
            let seconds = Date().timeIntervalSince(start)
            let summary = try MainThread.run { () -> MainThreadMonitor.Summary? in
                monitor.monitor.stop()
                return monitor.monitor.summary()
            }
            let delivered = try app.frames() - frames
            app.record("e2e-drag-fps", Double(delivered) / seconds)
            if let summary {
                app.record("e2e-drag-p99", summary.p99)
            }
            try app.choose(.resetAll)
        }

        static let export = Scenario(
            "performance.export", "Exporting a full-size JPEG",
            tiers: [.performance], claims: [],
        ) { app in
            try app.openWorking()
            var settings = ExportSettings()
            settings.revealInFinder = false
            _ = try app.export(settings, as: "warm-up")
            let time = try app.milliseconds { _ = try app.export(settings, as: "full-size") }
            app.record("e2e-export", time)
        }

        static let palette = Scenario(
            "performance.palette", "⌘K to the command palette, and photo to photo",
            tiers: [.performance], claims: [],
        ) { app in
            try app.openWorking()
            var times: [Double] = []
            for _ in 0 ..< 5 {
                try times.append(app.milliseconds {
                    try app.press(.commandPalette)
                    try app.wait("the palette") { $0.commandPalette != nil }
                })
                try app.press(KeyCombo(.escape))
                try app.wait("the palette to close") { $0.commandPalette == nil }
            }
            app.record("e2e-palette", times.sorted()[times.count / 2])
        }
    }
#endif
