#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Darwin
    import Foundation
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// `--library-perf <fixture> [--library-perf-library <folder>] [--library-perf-memory]
    /// [--library-perf-quit]`: the library in the
    /// app (docs/plans/2026-10-05-library-design.md, The stress harness), on a fixture made by
    /// `redlamp library fixture`. It indexes the fixture into a temporary library, its thumbnails
    /// included, and closes it as quitting does; then it checks a warm launch (the library open,
    /// searchable and caught up with the disk), opening the fixture with Show Photos in Subfolders in
    /// the filmstrip, its visible thumbnails, scrolling it and the Library grid end to end, held arrow
    /// keys through it at the key-repeat rate and at 120 Hz (the main thread, and blank frames: the
    /// canvas, or a cell near the active photo, without its thumbnail a frame after each step), and 200
    /// switches between Library and Develop in the editor's own views with a photo open (the main
    /// thread's work per switch until it's idle, and what the process read from disk meanwhile). The
    /// footprint is followed through every phase, then after a memory-pressure trim and a few idle
    /// seconds.
    /// Nothing joins the working set, and the temporary library is removed at the end;
    /// `--library-perf-library <folder>` keeps it in `<folder>` instead, where the next run finds it
    /// indexed.
    ///
    /// Writes /tmp/redlamp-perf.txt, ending with each budget's PASS or FAIL, and the metrics to
    /// /tmp/redlamp-perf.json, as `--folders-perf` does; with `--library-perf-quit` it then quits,
    /// with status 1 if a budget failed. `--library-perf-memory` also breaks the footprint down at
    /// each phase into /tmp/redlamp-memory.txt.
    @MainActor
    enum DebugLibraryPerformance {
        private struct Measured {
            var indexing: Duration = .zero
            var ready: Duration = .zero
            var searchable: Duration = .zero
            var launch: Duration = .zero
            var opened: Duration = .zero
            var fromLibrary = false
            var count = 0
            var visible: Duration = .zero
            var opening: MainThreadMonitor.Summary?
            var scrolling: MainThreadMonitor.Summary?
            var gridScrolling: MainThreadMonitor.Summary?
            var arrows: [(label: String, summary: MainThreadMonitor.Summary?, steps: Int, blank: Int)] = []
            var switches: [Double] = []
            var switchReads: UInt64 = 0
        }

        static func scheduleIfRequested(model: EditorModel) {
            let arguments = LaunchArguments.all
            guard let index = arguments.firstIndex(of: "--library-perf"), index + 1 < arguments.count else { return }
            let fixture = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await run(fixture: fixture, engine: model.engine)
            }
        }

        static func run(fixture: URL, engine: any EditingEngine) async {
            let arguments = LaunchArguments.all
            let fixture = fixture.standardizedFileURL
            var lines = [
                "Library performance on \(fixture.path)",
                "Cores: \(CoreCounts.performance) performance, \(CoreCounts.efficiency) efficiency",
                "Load average at the start: \(loadAverage())",
            ]
            var measured = Measured()
            let kept = arguments.firstIndex(of: "--library-perf-library").flatMap {
                $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true) : nil
            }
            let paths = LibraryPaths(root: kept ?? FileManager.default.temporaryDirectory
                .appending(path: "library-perf-\(UUID().uuidString)", directoryHint: .isDirectory))
            defer {
                if kept == nil {
                    try? FileManager.default.removeItem(at: paths.root)
                }
            }
            let thumbnail: @Sendable (URL, Int) -> CGImage? = { url, size in
                engine.decodeThumbnail(for: url, maxPixelSize: size)
            }

            DebugPerformance.trace("library-perf: indexing \(fixture.path)")
            let indexingStarted = ContinuousClock.now
            let indexed = await index(fixture, into: paths, thumbnail: thumbnail)
            measured.indexing = ContinuousClock.now - indexingStarted
            lines
                .append(
                    "Indexing the fixture into a new library, thumbnails included: \(indexed) photos in \(ms(measured.indexing))",
                )

            let packs = ThumbnailPacks(directory: FileManager.default.temporaryDirectory
                .appending(path: "library-perf-packs-\(UUID().uuidString)"))
            defer { try? FileManager.default.removeItem(at: packs.directory) }
            let loader = ThumbnailLoader(packs: packs) { url, size in engine.decodeThumbnail(
                for: url,
                maxPixelSize: size,
            ) }
            let library = FolderLibrary()
            let model = EditorModel(engine: engine, library: library, thumbnailLoader: loader)
            let memory = MemoryPhases(breakdowns: arguments.contains("--library-perf-memory")) {
                [
                    .count("photos shown", library.count),
                    .bytes("thumbnails in memory", loader.memoryUsed),
                    .count("thumbnails in memory", loader.cachedCount),
                ]
            }
            memory.start()
            await memory.mark("launch")
            lines.append(String(format: "Footprint before the library opens: %.0f MB", mb(memory.baseline)))

            DebugPerformance.trace("library-perf: warm launch")
            library.add([fixture])
            let service = LibraryService(paths: paths, sidecars: library.sidecars, thumbnail: thumbnail)
            let launched = ContinuousClock.now
            library.attach(service)
            while !service.isReady, service.state == .opening {
                try? await Task.sleep(for: .milliseconds(1))
            }
            measured.ready = ContinuousClock.now - launched
            if let engine = service.engine, let query = try? LibraryQuery(parsing: "rating>=1") {
                _ = try? await engine.search(query).first { @Sendable result in result.count != nil }
            }
            measured.searchable = ContinuousClock.now - launched
            while await !service.canShow(fixture, includingSubfolders: true),
                  ContinuousClock.now - launched < .seconds(30) {
                try? await Task.sleep(for: .milliseconds(2))
            }
            measured.launch = ContinuousClock.now - launched
            lines.append(
                "Warm launch: open in \(ms(measured.ready)), searchable in \(ms(measured.searchable)), caught up with the disk in \(ms(measured.launch))",
            )
            await memory.mark("launched")

            DebugPerformance.trace("library-perf: opening")
            let monitor = MainThreadMonitor()
            monitor.start()
            let openStarted = ContinuousClock.now
            library.setIncludesSubfolders(true)
            library.open(fixture)
            while library.isListing || library.count == 0, ContinuousClock.now - openStarted < .seconds(30) {
                try? await Task.sleep(for: .milliseconds(1))
            }
            measured.opened = ContinuousClock.now - openStarted
            measured.fromLibrary = library.isShownFromLibrary
            measured.count = library.count
            try? await Task.sleep(for: .milliseconds(200))
            monitor.stop()
            measured.opening = monitor.summary(seconds: seconds(ContinuousClock.now - openStarted))
            lines.append(
                "Opening it in the filmstrip: \(measured.count) photos in \(ms(measured.opened)), \(measured.fromLibrary ? "from the library" : "listed from the disk")",
            )
            lines.append(monitor.report(
                "Main thread opening it", seconds: seconds(ContinuousClock.now - openStarted),
            ))
            await memory.mark("opened")

            let visible = Array(model.items.prefix(15))
            let thumbnailsStarted = ContinuousClock.now
            await load(visible, with: loader)
            measured.visible = ContinuousClock.now - thumbnailsStarted
            lines.append("Visible thumbnails (15, from the store): \(ms(measured.visible))")
            await memory.mark("visible")

            let (scrolling, scrollReport) = await DebugFoldersPerformance.scroll(model)
            measured.scrolling = scrolling
            lines.append(scrollReport)
            await memory.mark("scrolled")

            let (gridScrolling, gridReport) = await scrollGrid(model)
            measured.gridScrolling = gridScrolling
            lines.append(gridReport)
            await memory.mark("grid scrolled")

            for (label, interval) in [("at the key-repeat rate (30 ms)", 0.030), ("at 120 Hz", 1.0 / 120)] {
                let held = await holdArrow(model, loader: loader, interval: interval, steps: 300)
                measured.arrows.append((label, held.summary, held.steps, held.blank))
                lines.append(String(
                    format: "Held arrow keys %@: %d steps, %d blank frames", label, held.steps, held.blank,
                ))
                lines.append(held.report)
            }
            await memory.mark("held arrows")

            let switched = await switchModules(model, count: 200)
            measured.switches = switched.durations
            measured.switchReads = switched.reads
            lines.append(switched.report)
            await memory.mark("switched")

            try? await Task.sleep(for: .seconds(3))
            await memory.mark("settled")
            loader.trim(to: 0)
            _ = malloc_zone_pressure_relief(nil, 0)
            await memory.mark("trimmed")
            try? await Task.sleep(for: .seconds(5))
            await memory.mark("idle")
            memory.stop()
            service.close()
            lines.append(memory.summary())

            let arrows = measured.arrows.compactMap(\.summary?.p99).max() ?? .infinity
            let blank = measured.arrows.reduce(0) { $0 + $1.blank }
            let browsing = browsingPeak(memory)
            DebugPerformance.writeMetrics([
                "library-launch": seconds(measured.launch) * 1000,
                "library-open": seconds(measured.opened) * 1000,
                "library-thumbs": seconds(measured.visible) * 1000,
                "library-main-scroll": measured.scrolling?.p99 ?? .infinity,
                "library-main-grid-scroll": measured.gridScrolling?.p99 ?? .infinity,
                "library-main-arrows": arrows,
                "library-blank-frames": Double(blank),
                "library-main-switch": percentile(measured.switches, 0.99),
                "library-switch-reads": Double(measured.switchReads),
                "library-peak-memory": browsing,
            ])
            let budgets = budgets(measured, arrows: arrows, blank: blank, browsing: browsing)
            finish(
                lines,
                budgets: budgets,
                memory: memory,
                title: "Memory on \(fixture.path), \(measured.count) photos",
            )
        }

        /// Indexes `fixture` into a new library at `paths` until it's caught up and its thumbnails
        /// are made, then closes it as quitting does; returns how many photos it holds.
        private static func index(
            _ fixture: URL, into paths: LibraryPaths, thumbnail: @escaping @Sendable (URL, Int) -> CGImage?,
        ) async -> Int {
            let service = LibraryService(paths: paths, sidecars: SidecarPlacement(), thumbnail: thumbnail)
            service.start(following: [fixture])
            let started = ContinuousClock.now
            var polls = 0
            while await !service.canShow(fixture, includingSubfolders: true),
                  ContinuousClock.now - started < .seconds(3600) {
                if case .unavailable = service.state {
                    break
                }
                polls += 1
                if polls % 100 == 0 {
                    let count = await (try? service.engine?.list(.allPhotographs))?.count ?? 0
                    DebugPerformance.trace("library-perf: \(count) photos indexed")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            var idle = 0
            while idle < 10, ContinuousClock.now - started < .seconds(3600) {
                let load = LibraryIndexer.scheduler.load()
                let busy = load.waiting.values.reduce(0, +) + load.running.values.reduce(0, +)
                idle = busy == 0 ? idle + 1 : 0
                try? await Task.sleep(for: .milliseconds(100))
            }
            let count = await (try? service.engine?.list(.allPhotographs))?.count ?? 0
            service.close()
            return count
        }

        /// Selects the first photo, then the next every `interval` for `steps` steps, as a held arrow
        /// key does, with the filmstrip on screen; a frame after each step, the canvas has to show the
        /// photo (its render or its thumbnail) and the cells beside the active one their thumbnails.
        private static func holdArrow(
            _ model: EditorModel, loader: ThumbnailLoader, interval: Double, steps: Int,
        ) async -> (summary: MainThreadMonitor.Summary?, report: String, steps: Int, blank: Int) {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1200, height: FilmstripViews.height), styleMask: [.borderless],
                backing: .buffered, defer: false,
            )
            let strip = FilmstripViews.make(model: model)
            window.contentView = strip
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            let start = model.selection.flatMap(model.library.index(of:)).map { $0 + 1 } ?? 0
            guard model.items.indices.contains(start) else { return (nil, "", 0, 0) }
            model.select(model.items[start].url)
            try? await Task.sleep(for: .milliseconds(500))
            let monitor = MainThreadMonitor()
            monitor.start()
            let frame = 1.0 / 120
            var blank = 0
            var taken = 0
            let began = CFAbsoluteTimeGetCurrent()
            for step in 0 ..< steps {
                let due = began + Double(step) * interval
                guard let index = model.selection.flatMap(model.library.index(of:)),
                      model.items.indices.contains(index + 1)
                else { break }
                model.selectNext()
                taken += 1
                try? await Task.sleep(for: .microseconds(Int(frame * 1_000_000)))
                let near = max(index + 1 - 5, 0) ... min(index + 1 + 5, model.items.count - 1)
                let canvasBlank = !model.hasFrame && model.selectionThumbnail == nil
                let cellBlank = near.contains { model.items[$0].isLocal && loader.cached(model.items[$0]) == nil }
                if canvasBlank || cellBlank {
                    blank += 1
                }
                let wait = due + interval - CFAbsoluteTimeGetCurrent()
                if wait > 0 {
                    try? await Task.sleep(for: .microseconds(Int(wait * 1_000_000)))
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - began
            monitor.stop()
            return (
                monitor.summary(seconds: elapsed),
                monitor.report("Main thread holding the arrow key", seconds: elapsed),
                taken, blank,
            )
        }

        /// Asks for every thumbnail at once and waits until they're all in.
        private static func load(_ items: [RedlampUI.LibraryItem], with loader: ThumbnailLoader) async {
            var remaining = items.count
            for item in items {
                loader.request(item, lane: .onScreen) { _ in remaining -= 1 }
            }
            while remaining > 0 {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        /// Scrolls an offscreen Library grid end to end in 4 s, at 120 Hz, watching the main thread.
        private static func scrollGrid(_ model: EditorModel) async -> (MainThreadMonitor.Summary?, String) {
            DebugPerformance.trace("library-perf: scrolling the grid")
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless],
                backing: .buffered, defer: false,
            )
            let grid = LibraryGridViews.make(model: model)
            window.contentView = grid
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            try? await Task.sleep(for: .milliseconds(300))
            let monitor = MainThreadMonitor()
            monitor.start()
            let duration = 4.0
            let started = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - started < duration {
                LibraryGridViews.scroll(grid, to: (CFAbsoluteTimeGetCurrent() - started) / duration)
                try? await Task.sleep(for: .microseconds(8333))
            }
            monitor.stop()
            return (
                monitor.summary(seconds: duration),
                monitor.report("Main thread scrolling the grid end to end", seconds: duration),
            )
        }

        /// Switches between Library and Develop `count` times in the editor window's own views, with a
        /// photo open and rendered in Develop: each switch's main-thread work, from the switch until the
        /// views that follow it have and the window is drawn and committed, the main thread over the whole
        /// phase, and the bytes the process read from disk meanwhile.
        private static func switchModules(
            _ model: EditorModel, count: Int,
        ) async -> (durations: [Double], reads: UInt64, report: String) {
            DebugPerformance.trace("library-perf: switching modules")
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false,
            )
            window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
            window.orderBack(nil)
            defer {
                model.showModule(.develop)
                window.orderOut(nil)
            }
            if model.selection == nil, let first = model.items.first {
                model.select(first.url)
            }
            let opening = ContinuousClock.now
            while !model.hasFrame || model.isLoading, ContinuousClock.now - opening < .seconds(30) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            // Library's grid loads its cells and their thumbnails the first time it's shown.
            model.showModule(.library)
            try? await Task.sleep(for: .milliseconds(500))
            model.showModule(.develop)
            try? await Task.sleep(for: .milliseconds(500))
            var durations: [Double] = []
            var parts: [(views: Double, drawing: Double)] = []
            let monitor = MainThreadMonitor()
            monitor.start()
            let reads = diskReads()
            let began = CFAbsoluteTimeGetCurrent()
            for index in 0 ..< count {
                let started = CFAbsoluteTimeGetCurrent()
                model.showModule(index.isMultiple(of: 2) ? .library : .develop)
                // The views follow the model in tasks of their own, queued on the main actor before this.
                await Task.yield()
                let followed = CFAbsoluteTimeGetCurrent()
                window.displayIfNeeded()
                CATransaction.flush()
                let drawn = CFAbsoluteTimeGetCurrent()
                durations.append((drawn - started) * 1000)
                parts.append(((followed - started) * 1000, (drawn - followed) * 1000))
                try? await Task.sleep(for: .milliseconds(30))
            }
            let read = diskReads() &- reads
            let elapsed = CFAbsoluteTimeGetCurrent() - began
            monitor.stop()
            let report = String(
                format: "Switching between Library and Develop: %d switches, each p50 %.2f ms, p99 %.2f ms, max %.2f ms "
                    +
                    "(the views following, p50 %.2f ms; drawing and committing, p50 %.2f ms); %llu bytes read from disk",
                durations.count, percentile(durations, 0.5), percentile(durations, 0.99), durations.max() ?? 0,
                percentile(parts.map(\.views), 0.5), percentile(parts.map(\.drawing), 0.5), read,
            )
            return (durations, read, report + "\n" + monitor.report("Main thread switching modules", seconds: elapsed))
        }

        /// The bytes the process has read from disk.
        private static func diskReads() -> UInt64 {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return result == 0 ? usage.ri_diskio_bytesread : 0
        }

        private static func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return .infinity }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }

        /// The highest footprint over launch while the library opened and the filmstrip and grid were
        /// browsed, before photos were opened in the editor.
        private static func browsingPeak(_ memory: MemoryPhases) -> Double {
            let base = mb(memory.baseline)
            let browsing: Set = ["launched", "opened", "visible", "scrolled", "grid scrolled"]
            return memory.phases.filter { browsing.contains($0.label) }.map { mb($0.peak) - base }.max() ?? .infinity
        }

        private static func budgets(
            _ measured: Measured, arrows: Double, blank: Int, browsing: Double,
        ) -> [Budget] {
            [
                .below("Warm launch: open, searchable, caught up", seconds(measured.launch) * 1000, 1000, unit: "ms"),
                .atLeast("Opened from the library (1 yes, 0 listed)", measured.fromLibrary ? 1 : 0, 1, unit: ""),
                .below(
                    "All \(measured.count) photos in the filmstrip",
                    seconds(measured.opened) * 1000,
                    300,
                    unit: "ms",
                ),
                .below("Main thread p99 opening them", measured.opening?.p99 ?? .infinity, 8.3, unit: "ms"),
                .below("Visible thumbnails from the store", seconds(measured.visible) * 1000, 400, unit: "ms"),
                .below("Main thread p99 while scrolling", measured.scrolling?.p99 ?? .infinity, 8.3, unit: "ms"),
                .below(
                    "Main thread p99 scrolling the grid", measured.gridScrolling?.p99 ?? .infinity, 8.3, unit: "ms",
                ),
                .below("Main thread p99 holding the arrow keys", arrows, 8.3, unit: "ms"),
                .below("Blank frames holding the arrow keys", Double(blank), 1, unit: ""),
                .below("Main thread p99 switching modules", percentile(measured.switches, 0.99), 8, unit: "ms"),
                .below("Disk reads switching modules", Double(measured.switchReads), 1, unit: "bytes"),
                .below("Peak footprint over launch, browsing", browsing, 250, unit: "MB"),
            ]
        }

        private static func finish(_ lines: [String], budgets: [Budget], memory: MemoryPhases, title: String) {
            let failed = budgets.filter { !$0.passed }
            let report = (lines + ["Budgets (load average \(loadAverage())):"] + budgets.map(\.line) + [
                failed.isEmpty
                    ? "Budgets: all \(budgets.count) met"
                    :
                    "Budgets: \(failed.count) of \(budgets.count) over: \(failed.map(\.name).joined(separator: "; "))",
            ]).joined(separator: "\n")
            print(report)
            if memory.breakdowns {
                let table = memory.report(title: title, notes: ["Load average at the end: \(loadAverage())"])
                try? (table + "\n").write(toFile: "/tmp/redlamp-memory.txt", atomically: true, encoding: .utf8)
            }
            try? (report + "\n").write(toFile: "/tmp/redlamp-perf.txt", atomically: true, encoding: .utf8)
            if LaunchArguments.all.contains("--library-perf-quit") {
                if failed.isEmpty {
                    NSApp.terminate(nil)
                } else {
                    exit(1)
                }
            }
        }

        private static func loadAverage() -> String {
            var loads = [Double](repeating: 0, count: 3)
            guard getloadavg(&loads, 3) == 3 else { return "unknown" }
            return loads.map { String(format: "%.1f", $0) }.joined(separator: " ")
        }

        private static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        private static func ms(_ duration: Duration) -> String {
            String(format: "%.1f ms", seconds(duration) * 1000)
        }
    }
#endif
