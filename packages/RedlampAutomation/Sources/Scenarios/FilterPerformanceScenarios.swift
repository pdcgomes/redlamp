#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The moments without a pick as a filter-bar term at the filter bar's budgets (LIB-41, LIB-18), on a copy of
    /// lib-20k's 2007 folder, or of the folder `REDLAMP_FILTER_FIXTURE` names, such as all of lib-20k: queries typed
    /// in the bar a key at a time, as `--library-perf` types its own, those with `is:unpicked-moment` and two without
    /// it to compare, each key that changes what the filter finds timed until its photos are on screen against 16 ms
    /// at p95 and the main thread watched against 8.3 ms at p99; then the Tighter–Looser setting stepped with the term
    /// on, each step until its photos are on screen. The copy is the scenario's own, a clone beside the fixture on its
    /// volume, removed afterwards; nothing of the fixture's is touched.
    extension FilterScenarios {
        static let fixture = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["REDLAMP_FILTER_FIXTURE"]
                ?? "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-20k/2007",
            isDirectory: true,
        )

        /// The queries typed, by what they measure.
        static let typedQueries: [(name: String, queries: [String])] = [
            ("moments", ["is:unpicked-moment", "is:unpicked-moment rating>=1", "camera:X-T5 -is:unpicked-moment"]),
            ("others", ["rating>=1", "camera:X-T5 -flag:reject"]),
        ]

        /// What the main thread measured, read on the driver's thread once it's done.
        final class Timings: @unchecked Sendable {
            var onScreen: [String: [Double]] = [:]
            var queried: [String: [Double]] = [:]
            var made: [String: [Double]] = [:]
            var missed = 0
            var found = 0
        }

        static let momentsPerformance = Scenario(
            "performance.library-filter-moments",
            "is:unpicked-moment typed in the filter bar a key at a time on a copy of lib-20k's 2007 folder (or of "
                +
                "REDLAMP_FILTER_FIXTURE), beside queries without it, and the Tighter–Looser setting stepped with it on",
            tiers: [.performance], claims: [],
        ) { app in
            guard FileManager.default.fileExists(atPath: fixture.path) else {
                throw ScenarioSkip("\(fixture.path) isn't on this Mac")
            }
            let scratch = try DragBudgetScratch(cloning: fixture)
            defer { scratch.remove(app) }
            let count = try scratch.show(app)
            try app.main { model in
                model.setGroupKey(.ungrouped)
                model.setLooseness(0)
                model.showLibrary(.grid)
                model.libraryFilters?.setFilter(LibraryFilter(sections: [.text]))
                model.libraryFilters?.setBarShown(true)
            }
            try app.wait("the filter bar's text to take the keyboard") { _ in
                (Views.editorWindow?.firstResponder as? NSTextView)?.delegate is NSTextField
            }
            app.pause(1)
            var lines =
                ["\(fixture.lastPathComponent): \(count) photos shown, load average \(DragBudgetScratch.load())"]
            let timings = Timings()

            for (name, queries) in typedQueries {
                let watched = try app.watchingMainThread(name) {
                    try app.run("\(name) typed", timeout: 600) { model in
                        await Self.typeQueries(queries, as: name, in: model, into: timings)
                    }
                }
                let onScreen = timings.onScreen[name] ?? []
                lines.append(String(
                    format: "%@ typed: %d keys changing the photos found, on screen p50 %.2f ms, p95 %.2f ms, "
                        + "max %.2f ms; the query p50 %.2f ms, p95 %.2f ms; the list p50 %.2f ms, p95 %.2f ms; "
                        + "main thread p50 %.2f ms, p99 %.2f ms, max %.1f ms",
                    name, onScreen.count, Self.percentile(onScreen, 0.5), Self.percentile(onScreen, 0.95),
                    onScreen.max() ?? 0,
                    Self.percentile(timings.queried[name] ?? [], 0.5), Self.percentile(
                        timings.queried[name] ?? [],
                        0.95,
                    ),
                    Self.percentile(timings.made[name] ?? [], 0.5), Self.percentile(timings.made[name] ?? [], 0.95),
                    watched.summary?.p50 ?? -1, watched.summary?.p99 ?? -1, watched.summary?.max ?? -1,
                ))
                app.record("e2e-filter-\(name)-on-screen-p95", Self.percentile(onScreen, 0.95))
                if let summary = watched.summary {
                    app.record("e2e-filter-\(name)-main-p99", summary.p99)
                }
            }

            let steps = try app.watchingMainThread("setting") {
                try app.run("the setting stepped with the term on", timeout: 600) { model in
                    await Self.stepSetting(in: model, into: timings)
                }
            }
            let stepped = timings.onScreen["setting"] ?? []
            lines.append(String(
                format: "is:unpicked-moment, %d photos at the default setting; %d steps of the setting, on screen "
                    + "p50 %.2f ms, p95 %.2f ms, max %.2f ms; main thread p99 %.2f ms, max %.1f ms; %d not listed "
                    + "within a second",
                timings.found, stepped.count, Self.percentile(stepped, 0.5), Self.percentile(stepped, 0.95),
                stepped.max() ?? 0,
                steps.summary?.p99 ?? -1, steps.summary?.max ?? -1, timings.missed,
            ))
            try app.main { model in
                model.libraryFilters?.setFilter(LibraryFilter())
                model.libraryFilters?.setBarShown(false)
                model.setLooseness(0)
            }
            try? (lines.joined(separator: "\n") + "\n").write(
                to: app.runDirectory.appending(path: "filter-moments-performance.txt"), atomically: true,
                encoding: .utf8,
            )
        }

        /// Types `queries` in the bar a key every 60 ms, timing each key that changes what the filter finds until the
        /// library has listed its photos and the window has drawn them.
        @MainActor private static func typeQueries(
            _ queries: [String], as name: String, in model: EditorModel, into timings: Timings,
        ) async {
            guard let window = Views.editorWindow, let filters = model.libraryFilters else { return }
            for query in queries {
                LibraryFilterBars.clear(in: window)
                _ = await listed(nil, filters, since: CFAbsoluteTimeGetCurrent())
                var typed = ""
                for character in query {
                    let before = (try? LibraryQuery(parsing: typed, asYouType: true)) ?? .all
                    typed.append(character)
                    let started = CFAbsoluteTimeGetCurrent()
                    guard LibraryFilterBars.type(String(character), in: window) else { return }
                    if let after = try? LibraryQuery(parsing: typed, asYouType: true), after != before {
                        if await listed(after == .all ? nil : after, filters, since: started) {
                            window.displayIfNeeded()
                            CATransaction.flush()
                            timings.onScreen[name, default: []].append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                            if let took = filters.lastListing {
                                timings.queried[name, default: []].append(milliseconds(took.query))
                                timings.made[name, default: []].append(milliseconds(took.list))
                            }
                        } else {
                            timings.missed += 1
                        }
                    }
                    let wait = started + 0.060 - CFAbsoluteTimeGetCurrent()
                    if wait > 0 {
                        try? await Task.sleep(for: .microseconds(Int(wait * 1_000_000)))
                    }
                }
            }
        }

        /// The setting stepped from the tightest to the loosest and back with `is:unpicked-moment` in the bar, a step
        /// every 200 ms, each until the library has listed its photos again and the window has drawn them.
        @MainActor private static func stepSetting(in model: EditorModel, into timings: Timings) async {
            guard let window = Views.editorWindow, let filters = model.libraryFilters else { return }
            LibraryFilterBars.clear(in: window)
            _ = await listed(nil, filters, since: CFAbsoluteTimeGetCurrent())
            LibraryFilterBars.type("is:unpicked-moment", in: window)
            let term = try? LibraryQuery(parsing: "is:unpicked-moment")
            guard await listed(term, filters, since: CFAbsoluteTimeGetCurrent()) else { return }
            timings.found = model.items.count
            for looseness in [1, 2, 3, 4, 3, 2, 1, 0, -1, -2, -3, -4, -3, -2, -1, 0] {
                let listings = filters.listings
                let started = CFAbsoluteTimeGetCurrent()
                model.setLooseness(looseness)
                while filters.listings == listings, CFAbsoluteTimeGetCurrent() - started < 1 {
                    try? await Task.sleep(for: .microseconds(250))
                }
                if filters.listings == listings {
                    timings.missed += 1
                } else {
                    window.displayIfNeeded()
                    CATransaction.flush()
                    timings.onScreen["setting", default: []].append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        /// Until the library has listed the photos of `query`, or a second has passed since `started`.
        @MainActor private static func listed(_ query: LibraryQuery?, _ filters: LibraryFilters, since started: Double)
            async -> Bool {
            while filters.lastListed?.query != query, CFAbsoluteTimeGetCurrent() - started < 1 {
                try? await Task.sleep(for: .microseconds(250))
            }
            return filters.lastListed?.query == query
        }

        private static func milliseconds(_ duration: Duration) -> Double {
            duration / .milliseconds(1)
        }

        private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
    }
#endif
