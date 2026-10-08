#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import Synchronization

    /// Group By at the grid's budgets (LIB-41), on a copy of lib-20k's 2007 folder, or of the folder
    /// `REDLAMP_GROUP_FIXTURE` (else `REDLAMP_DRAG_FIXTURE`) names, such as all of lib-20k: Group By changed through
    /// every key and moments' Tighter–Looser setting, twice, each change on screen against 16 ms; every group closed
    /// and opened; culling with ⇧ through the moments, moving on in the grid's order; and → held through the moments
    /// in the grid and in the loupe, the filmstrip following them. The main thread is watched through each against
    /// 8.3 ms at p99, and with `REDLAMP_GROUP_PROFILE` set, sampled. The copy is the scenario's own, a clone beside the
    /// fixture on its volume, removed afterwards; nothing of the fixture's is touched.
    enum GroupPerformanceScenarios {
        static let all: [Scenario] = [groups]

        static let fixture = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["REDLAMP_GROUP_FIXTURE"]
                ?? ProcessInfo.processInfo.environment["REDLAMP_DRAG_FIXTURE"]
                ?? "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-20k/2007",
            isDirectory: true,
        )

        /// The keys and settings Group By goes through, as `--library-perf` goes through them.
        static let keys: [GroupKey] = [.day, .camera, .folder, .lens, .orientation, .momentCamera, .moment]
        static let steps = [-1, -2, -3, -4, -3, -2, -1, 0, 1, 2, 3, 4, 3, 2, 1, 0]

        /// A change of Group By or the setting: from the change until its groups are in the grid and the window has
        /// drawn them; the grouping's parts off the main thread; from the change until the grouping was back on the
        /// main thread; and the main thread's work showing it, the views following it included. Milliseconds.
        struct Change: Sendable {
            var label: String
            var onScreen: Double
            var parts: [Double]
            var back: Double
            var adopting: Double
        }

        /// The changes measured on the main thread, for the driver's thread to read.
        final class Changes: Sendable {
            let made = Mutex<[Change]>([])
        }

        static let groups = Scenario(
            "performance.library-groups",
            "Group By changed through every key and setting on a copy of lib-20k's 2007 folder (or of "
                + "REDLAMP_GROUP_FIXTURE), every group closed and opened, culling with ⇧ through the moments, and → held "
                + "through them in the grid and the loupe",
            tiers: [.performance], claims: [],
        ) { app in
            guard FileManager.default.fileExists(atPath: fixture.path) else {
                throw ScenarioSkip("\(fixture.path) isn't on this Mac")
            }
            let scratch = try DragBudgetScratch(cloning: fixture)
            defer { scratch.remove(app) }
            let count = try scratch.show(app)
            try app.main { model in
                model.setLooseness(0)
                model.setGroupKey(.ungrouped)
                model.setCellStyle(.compact)
                model.setThumbnailSize(GridSize.standard)
                model.filmstripVisible = true
                model.showLibrary(.grid)
            }
            defer {
                try? app.main { model in
                    model.setLooseness(0)
                    model.setGroupKey(.ungrouped)
                    model.showLibrary(.grid)
                }
            }
            var lines =
                ["\(fixture.lastPathComponent): \(count) photos shown, load average \(DragBudgetScratch.load())"]
            func note(_ name: String, _ phase: (summary: MainThreadMonitor.Summary?, seconds: Double)) {
                if let summary = phase.summary {
                    app.record("e2e-groups-\(name)-p99", summary.p99)
                    app.record("e2e-groups-\(name)-max", summary.max)
                }
                lines.append(String(
                    format: "%@: %.2f s, main thread p50 %.2f ms, p99 %.2f ms, max %.1f ms, %d of %d turns over 8.3 ms",
                    name, phase.seconds, phase.summary?.p50 ?? -1, phase.summary?.p99 ?? -1,
                    phase.summary?.max ?? -1, phase.summary?.overFrame ?? -1, phase.summary?.iterations ?? -1,
                ))
            }
            func describe(_ name: String, _ times: [Double]) {
                let sorted = times.sorted()
                guard !sorted.isEmpty else { return }
                let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                app.record("e2e-groups-\(name)-p95", p95)
                app.record("e2e-groups-\(name)-max", sorted.last ?? 0)
                lines.append(String(
                    format: "%@, %d times: median %.2f ms, p95 %.2f ms, max %.2f ms", name, sorted.count,
                    sorted[sorted.count / 2], p95, sorted.last ?? 0,
                ))
            }
            let mainThread = try app.main { _ in mach_thread_self() }
            let profiling = ProcessInfo.processInfo.environment["REDLAMP_GROUP_PROFILE"] != nil
            func watched(
                _ name: String, _ body: () throws -> Void,
            ) throws -> (summary: MainThreadMonitor.Summary?, seconds: Double) {
                let profile = profiling ? StackPerformanceScenarios.StackCallProfile(thread: mainThread) : nil
                defer {
                    profile?.write(to: app.runDirectory.appending(path: "group-profile-\(name).txt"), inside: "Group")
                }
                return try app.watchingMainThread(name, body)
            }

            // The first grouping reads each photo's ID in the index.
            let first = try app.milliseconds {
                try app.main { $0.setGroupKey(.moment) }
                try app.wait("the photos grouped by moment", timeout: 60) { $0.gridGroups.list?.groups.key == .moment }
            }
            let moments = try app.main { $0.gridGroups.list?.groups.count ?? 0 }
            lines.append(String(format: "grouped by moment the first time (%d moments) in %.1f ms", moments, first))
            app.pause(1)

            // Group By changed through each key and setting, each once the last is on screen.
            let changes = Changes()
            let changing = try watched("change") {
                try app.run("Group By changed through every key and setting", timeout: 600) { model in
                    let groups = model.gridGroups
                    let wanted = keys.map { ($0.title, $0, 0) } + steps.map { ("the setting at \($0)", .moment, $0) }
                    for (label, key, looseness) in wanted + wanted {
                        let setting = MomentSetting(looseness: looseness)
                        let started = ContinuousClock.now
                        if key == groups.list?.groups.key {
                            model.setLooseness(looseness)
                        } else {
                            model.setGroupKey(key)
                        }
                        while groups.list.map({ $0.groups.key != key || $0.groups.setting != setting }) ?? true,
                              ContinuousClock.now - started < .seconds(2) {
                            try? await Task.sleep(for: .microseconds(250))
                        }
                        guard groups.list.map({ $0.groups.key == key && $0.groups.setting == setting }) == true
                        else { continue }
                        Views.editorWindow?.displayIfNeeded()
                        CATransaction.flush()
                        let measured = Change(
                            label: label, onScreen: Self.milliseconds(ContinuousClock.now - started),
                            parts: groups.lastGroupingParts.map(Self.milliseconds),
                            back: Self.milliseconds(groups.lastGrouping),
                            adopting: Self.milliseconds(groups.lastAdoption),
                        )
                        changes.made.withLock { $0.append(measured) }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
            }
            let made = changes.made.withLock { $0 }
            try app.expect(made.count == 2 * (keys.count + steps.count), "\(made.count) changes came on screen")
            describe("change-on-screen", made.map(\.onScreen))
            describe("change-back", made.map(\.back))
            describe("change-adopting", made.map(\.adopting))
            for (part, name) in ["ids", "engine", "groups", "list"].enumerated() {
                describe("change-\(name)", made.compactMap { $0.parts.indices.contains(part) ? $0.parts[part] : nil })
            }
            note("change", changing)
            for change in made.sorted(by: { $0.onScreen > $1.onScreen }).prefix(5) {
                lines.append(String(
                    format: "  %@: on screen %.2f ms, back %.2f ms (parts %@), adopting %.2f ms", change.label,
                    change.onScreen, change.back,
                    change.parts.map { String(format: "%.2f", $0) }.joined(separator: ", "),
                    change.adopting,
                ))
            }

            // Every moment closed and opened again, as Close All Groups and Open All Groups do.
            var toggled: [Double] = []
            let toggling = try watched("toggle-all") {
                for _ in 0 ..< 20 {
                    for close in [true, false] {
                        try toggled.append(app.main { model in
                            Self.timed {
                                model.perform(close ? .closeAllGroups : .openAllGroups)
                                Views.editorWindow?.displayIfNeeded()
                                CATransaction.flush()
                            }
                        })
                        app.pause(0.1)
                    }
                }
            }
            describe("toggle-all-on-screen", toggled)
            note("toggle-all", toggling)

            // ⇧3 and ⇧0 through the moments from the first photo on show, each moving on in the grid's order.
            try app.main { model in
                model.openAllGroups()
                if let first = model.gridGroups.endPhoto(first: true), let url = model.library.url(ofPhoto: first) {
                    model.select(url)
                }
            }
            app.pause(1)
            var culled: [Double] = []
            let culling = try watched("cull") {
                for step in 0 ..< 40 {
                    try culled.append(app.main { model in
                        Self.timed {
                            model.perform(step.isMultiple(of: 2) ? .rating3 : .rating0, shifted: true)
                            Views.editorWindow?.displayIfNeeded()
                            CATransaction.flush()
                        }
                    })
                    app.pause(0.1)
                }
            }
            describe("cull-on-screen", culled)
            note("cull", culling)
            try app.wait("the culling written", timeout: 120) { !$0.isWritingCulling }

            // → held through the moments, a key every 30 ms as key repeat sends them, in the grid and in the loupe.
            for view in [LibraryView.grid, .loupe] {
                try app.main { model in
                    model.showLibrary(view)
                    if let first = model.gridGroups.endPhoto(first: true), let url = model.library.url(ofPhoto: first) {
                        model.select(url)
                    }
                }
                app.pause(1)
                let walking = try watched("arrows-\(view)") {
                    for _ in 0 ..< 200 {
                        app.post { _ in
                            if let right = try? Keyboard.event(KeyCombo(.right)) {
                                NSApp.sendEvent(right)
                            }
                        }
                        app.pause(1.0 / 30)
                    }
                }
                note("arrows-\(view)", walking)
            }
            try? (lines.joined(separator: "\n") + "\n").write(
                to: app.runDirectory.appending(path: "group-performance.txt"), atomically: true, encoding: .utf8,
            )
        }

        static func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }

        @MainActor static func timed(_ body: () -> Void) -> Double {
            let clock = ContinuousClock()
            let start = clock.now
            body()
            return milliseconds(clock.now - start)
        }
    }
#endif
