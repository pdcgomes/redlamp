#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Darwin
    import Foundation
    import RedlampDesign
    import RedlampDocument
    import RedlampEngine
    import RedlampEngineAPI
    import RedlampLibrary
    import RedlampServices
    @_spi(Harness) import RedlampUI
    import Synchronization

    /// `--library-perf <fixture> [--library-perf-library <folder>] [--library-perf-memory]
    /// [--library-perf-profile] [--library-perf-quit]`: the library in the
    /// app (docs/plans/2026-10-05-library-design.md, The stress harness), on a fixture made by
    /// `redlamp library fixture`. It indexes the fixture into a temporary library, its thumbnails
    /// included, and closes it as quitting does; then it checks a warm launch (the library open,
    /// searchable and caught up with the disk), opening the fixture with Show Photos in Subfolders in
    /// the filmstrip, its visible thumbnails, scrolling it and the Library grid end to end (with compact
    /// cells at the standard size, expanded cells, and the largest thumbnails), the fixture's queries
    /// typed in the filter bar a character at a time (the main thread, and each key's photos on
    /// screen), held arrow
    /// keys through it at the key-repeat rate and at 120 Hz (the main thread, and blank frames: the
    /// canvas, or a cell near the active photo, without its thumbnail a frame after each step), and 200
    /// switches between Library and Develop in the editor's own views with a photo open (the main
    /// thread's work per switch until it's idle, and what the process read from disk meanwhile), the
    /// edited photos rendered in the background (LIB-17): the grid scrolled as they render, renders a
    /// second with Develop idle and busy, and Develop's own render times with renders running and paused,
    /// and culling every photo at once (LIB-15): a rating, a flag, a label and the mark, each undone, each
    /// on screen and in every sidecar, the sidecars checked to read as they did after the last Undo.
    /// The footprint is followed through every phase, then after a memory-pressure trim and a few idle
    /// seconds.
    /// Nothing joins the working set, and the temporary library is removed at the end;
    /// `--library-perf-library <folder>` keeps it in `<folder>` instead, where the next run finds it
    /// indexed.
    ///
    /// Writes /tmp/redlamp-perf.txt, ending with each budget's PASS or FAIL, and the metrics to
    /// /tmp/redlamp-perf.json, as `--folders-perf` does; with `--library-perf-quit` it then quits,
    /// with status 1 if a budget failed. `--library-perf-memory` also breaks the footprint down at
    /// each phase into /tmp/redlamp-memory.txt, and `--library-perf-profile` samples the main thread
    /// while the grid scrolls into /tmp/redlamp-profile.txt. Every turn of the main thread's run loop
    /// longer than half a second is sampled (with `--library-perf-turns`, while typing and culling every turn
    /// longer than 16 ms), and where they went written to /tmp/redlamp-stalls.txt, with what changed in each
    /// culling step.
    @MainActor
    enum DebugLibraryPerformance {
        private static var stalls: StallSampler?

        /// Names the phase in the debug log and in the stall report, its turns sampled once they run longer
        /// than `sampling` (half a second when nil).
        private static func phase(_ name: String, sampling: Duration? = nil) {
            let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) library-perf: \(name)\n"
            log.async {
                guard let handle = FileHandle(forWritingAtPath: "/tmp/redlamp-debug.log") else {
                    try? line.write(toFile: "/tmp/redlamp-debug.log", atomically: true, encoding: .utf8)
                    return
                }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
            stalls?.enter(name, sampling: LaunchArguments.all.contains("--library-perf-turns") ? sampling : nil)
        }

        /// Phases are logged off the main thread: opening the log can take a frame or more on a busy Mac,
        /// within the phases measured.
        private static let log = DispatchQueue(label: "app.redlamp.library-perf.log", qos: .utility)

        /// What the stall report adds about each phase: what changed in it.
        private static var notes: [String] = []

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
            /// The grid scrolled again with other cells: expanded, and the largest.
            var gridPhases: [(label: String, summary: MainThreadMonitor.Summary?)] = []
            var arrows: [(label: String, summary: MainThreadMonitor.Summary?, steps: Int, blank: Int)] = []
            var switches: [Double] = []
            var switchReads: UInt64 = 0
            /// The grid scrolled as edited photos render.
            var editScrolling: MainThreadMonitor.Summary?
            /// Typing the fixture's queries in the filter bar: the main thread, and each key's photos on screen.
            var typing: MainThreadMonitor.Summary?
            var typed: [Double] = []
            /// Culling every photo at once (LIB-15): the main thread, each change's main-thread work until it's
            /// drawn, each batch's time to reach every sidecar, and the sidecars not as they were after Undo.
            var culling: MainThreadMonitor.Summary?
            var culled: [Double] = []
            var cullWrites: [Double] = []
            var cullLeft = 0
            var cullCount = 0
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
            let stalls = StallSampler()
            self.stalls = stalls
            stalls.start()
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

            phase("indexing \(fixture.path)")
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

            phase("warm launch")
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

            phase("opening")
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

            phase("the visible thumbnails")
            let visible = Array(model.items.prefix(15))
            let thumbnailsStarted = ContinuousClock.now
            await load(visible, with: loader)
            measured.visible = ContinuousClock.now - thumbnailsStarted
            lines.append("Visible thumbnails (15, from the store): \(ms(measured.visible))")
            await memory.mark("visible")

            phase("scrolling the filmstrip")
            let (scrolling, scrollReport) = await DebugFoldersPerformance.scroll(model)
            measured.scrolling = scrolling
            lines.append(scrollReport)
            await memory.mark("scrolled")

            let (gridScrolling, gridReport) = await scrollGrid(model)
            measured.gridScrolling = gridScrolling
            lines.append(gridReport)
            await memory.mark("grid scrolled")
            for (label, size, style) in [
                ("expanded cells", GridSize.standard, GridCellStyle.expanded),
                ("the largest thumbnails, from the preview tier", GridSize.range.upperBound, .compact),
            ] {
                let (summary, report) = await scrollGrid(model, size: size, style: style, label: label)
                measured.gridPhases.append((label, summary))
                lines.append(report)
            }
            await memory.mark("grid phases")

            let (typing, typed, typingReport) = await typeInFilterBar(model)
            measured.typing = typing
            measured.typed = typed
            lines.append(typingReport)
            await memory.mark("typed")

            for (label, interval) in [("at the key-repeat rate (30 ms)", 0.030), ("at 120 Hz", 1.0 / 120)] {
                phase("holding the arrow keys \(label)")
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

            let edits = await renderEdits(model, memory: memory)
            measured.editScrolling = edits.scrolling
            lines += edits.lines

            let culled = await cull(model)
            (measured.culling, measured.culled, measured.cullWrites) = (culled.summary, culled.onScreen, culled.writes)
            (measured.cullLeft, measured.cullCount) = (culled.left, culled.count)
            lines.append(culled.report)
            await memory.mark("culled")

            phase("settling")
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
            stalls.stop()
            self.stalls = nil
            lines.append((stalls.summary ?? "No main-thread turn over 500 ms") + " (/tmp/redlamp-stalls.txt)")
            try? ((notes + [stalls.report()]).joined(separator: "\n") + "\n")
                .write(toFile: "/tmp/redlamp-stalls.txt", atomically: true, encoding: .utf8)

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
                "library-main-grid-scroll-rendering": measured.editScrolling?.p99 ?? .infinity,
                "library-main-filter-typing": measured.typing?.p99 ?? .infinity,
                "library-filter-first-page": percentile(measured.typed, 0.95),
                "library-main-culling": measured.culling?.p99 ?? .infinity,
                "library-cull-on-screen": measured.culled.max() ?? .infinity,
                "library-cull-written": measured.cullWrites.max() ?? .infinity,
            ])
            let budgets: [Budget] = budgets(measured, arrows: arrows, blank: blank, browsing: browsing)
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

        /// Scrolls an offscreen Library grid end to end in 4 s, at 120 Hz, watching the main thread: at the
        /// thumbnail size and cell style given, and back to the standard ones after.
        private static func scrollGrid(
            _ model: EditorModel, size: Double = GridSize.standard, style: GridCellStyle = .compact,
            label: String? = nil,
        ) async -> (MainThreadMonitor.Summary?, String) {
            phase("scrolling the grid\(label.map { ", \($0)" } ?? "")")
            model.setThumbnailSize(size)
            model.setCellStyle(style)
            defer {
                model.setThumbnailSize(GridSize.standard)
                model.setCellStyle(.compact)
            }
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
            let sampler = LaunchArguments.all.contains("--library-perf-profile") ? MainThreadSampler() : nil
            monitor.start()
            sampler?.start()
            let duration = 4.0
            let started = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - started < duration {
                LibraryGridViews.scroll(grid, to: (CFAbsoluteTimeGetCurrent() - started) / duration)
                try? await Task.sleep(for: .microseconds(8333))
            }
            monitor.stop()
            sampler?.stop()
            if let sampler {
                try? await Task.sleep(for: .milliseconds(20))
                try? sampler.report().write(toFile: "/tmp/redlamp-profile.txt", atomically: true, encoding: .utf8)
            }
            let title = "Main thread scrolling the grid end to end\(label.map { ", \($0)" } ?? "")"
            return (monitor.summary(seconds: duration), monitor.report(title, seconds: duration))
        }

        /// Types the fixture's queries in the filter bar a character at a time, a key every 60 ms, in the
        /// editor window's own views with the grid and the metadata columns shown: the main thread over
        /// the phase, and for each key that changes what the filter finds, the time from the key until
        /// the photos it finds are on screen.
        private static func typeInFilterBar(
            _ model: EditorModel,
        ) async -> (MainThreadMonitor.Summary?, [Double], String) {
            phase("typing in the filter bar, opening the bar")
            guard let filters = model.libraryFilters else { return (nil, [], "Typing in the filter bar: no library") }
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false,
            )
            window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
            window.setContentSize(NSSize(width: 1600, height: 1000))
            window.orderBack(nil)
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
            }
            let count = model.items.count
            model.showLibrary(.grid)
            filters.setFilter(LibraryFilter(sections: [.text, .metadata]))
            filters.setBarShown(true)
            try? await Task.sleep(for: .milliseconds(500))
            /// Until the library has listed what the bar's text reads as, or a second.
            func listed(_ text: String, since started: Double) async -> Bool {
                let query = (try? LibraryQuery(parsing: text, asYouType: true)).map { $0 == .all ? nil : $0 }
                guard let query else { return false }
                while filters.lastListed?.query != query, CFAbsoluteTimeGetCurrent() - started < 1 {
                    try? await Task.sleep(for: .microseconds(250))
                }
                return filters.lastListed?.query == query
            }
            phase("typing in the filter bar", sampling: .milliseconds(16))
            let monitor = MainThreadMonitor()
            let sampler = LaunchArguments.all.contains("--library-perf-profile") ? MainThreadSampler() : nil
            monitor.start()
            sampler?.start()
            var onScreen: [Double] = []
            var keys = 0
            var missed = 0
            let began = CFAbsoluteTimeGetCurrent()
            for query in FixtureQuery.corpus {
                LibraryFilterBars.clear(in: window)
                _ = await listed("", since: CFAbsoluteTimeGetCurrent())
                var typed = ""
                for character in query.text {
                    let before = (try? LibraryQuery(parsing: typed, asYouType: true)) ?? .all
                    typed.append(character)
                    let started = CFAbsoluteTimeGetCurrent()
                    guard LibraryFilterBars.type(String(character), in: window) else { break }
                    keys += 1
                    if let after = try? LibraryQuery(parsing: typed, asYouType: true), after != before {
                        if await listed(typed, since: started) {
                            window.displayIfNeeded()
                            CATransaction.flush()
                            onScreen.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                        } else {
                            missed += 1
                        }
                    }
                    let wait = started + 0.060 - CFAbsoluteTimeGetCurrent()
                    if wait > 0 {
                        try? await Task.sleep(for: .microseconds(Int(wait * 1_000_000)))
                    }
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - began
            monitor.stop()
            sampler?.stop()
            phase("typing in the filter bar, clearing the filter")
            if let sampler {
                try? await Task.sleep(for: .milliseconds(20))
                try? sampler.report().write(
                    toFile: "/tmp/redlamp-profile-typing.txt",
                    atomically: true,
                    encoding: .utf8,
                )
            }
            filters.setFilter(LibraryFilter())
            filters.setBarShown(false)
            let cleared = CFAbsoluteTimeGetCurrent()
            while model.items.count != count || model.library.isFiltered, CFAbsoluteTimeGetCurrent() - cleared < 10 {
                try? await Task.sleep(for: .milliseconds(5))
            }
            model.showModule(.develop)
            let report = String(
                format: "Typing the fixture's %d queries in the filter bar: %d keys, %d changing the photos found, "
                    + "on screen p50 %.2f ms, p95 %.2f ms, max %.2f ms; %d not listed within a second",
                FixtureQuery.corpus.count, keys, onScreen.count, percentile(onScreen, 0.5), percentile(onScreen, 0.95),
                onScreen.max() ?? 0, missed,
            )
            return (
                monitor.summary(seconds: elapsed), onScreen,
                report + "\n" + monitor.report("Main thread typing in the filter bar", seconds: elapsed),
            )
        }

        /// Switches between Library and Develop `count` times in the editor window's own views, with a
        /// photo open and rendered in Develop: each switch's main-thread work, from the switch until the
        /// views that follow it have and the window is drawn and committed, the main thread over the whole
        /// phase, and the bytes the process read from disk meanwhile.
        private static func switchModules(
            _ model: EditorModel, count: Int,
        ) async -> (durations: [Double], reads: UInt64, report: String) {
            phase("switching modules")
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

        /// Edited photos rendered in the background (LIB-17), in an engine of the library's own, each phase
        /// from no render at all: the grid scrolled end to end in 8 s as they render (its main thread, and
        /// the renders made); 12 s with Develop showing an unedited photo and idle; then 15 s of Develop
        /// busy, a frame asked for at 60 Hz for 1 s in every 3 s, with renders paused and then running:
        /// the renders made, their waits, Develop's frames asked for while a render's step ran, and
        /// Develop's own render times either way.
        private static func renderEdits(
            _ model: EditorModel, memory: MemoryPhases,
        ) async -> (scrolling: MainThreadMonitor.Summary?, lines: [String]) {
            phase("rendering edits")
            let renders = model.editRenders
            renders.makeEngine = { try? RedlampEngine(decoder: DecodeServiceClient(), lensProfiles: .user) }
            defer {
                renders.isRunning = false
                renders.letEngineGo()
            }
            var lines = [
                "Edited photos rendered in the background: \(model.items.count(where: renders.renders)) of the "
                    + "\(model.items.count) photos are edited",
            ]

            await renders.renderAgain()
            renders.isRunning = true
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless],
                backing: .buffered, defer: false,
            )
            let grid = LibraryGridViews.make(model: model)
            window.contentView = grid
            window.orderBack(nil)
            try? await Task.sleep(for: .milliseconds(300))
            let monitor = MainThreadMonitor()
            monitor.start()
            let duration = 8.0
            let started = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - started < duration {
                LibraryGridViews.scroll(grid, to: (CFAbsoluteTimeGetCurrent() - started) / duration)
                try? await Task.sleep(for: .microseconds(8333))
            }
            monitor.stop()
            window.orderOut(nil)
            let scrolling = monitor.summary(seconds: duration)
            lines.append(rendered("Scrolling the grid end to end in 8 s", renders.statistics, seconds: duration))
            lines.append(monitor.report("Main thread scrolling the grid as edits render", seconds: duration))
            await memory.mark("edits, scrolling")
            renders.isRunning = false
            renders.letEngineGo()
            try? await Task.sleep(for: .seconds(1))
            await memory.mark("edits, engine let go")
            renders.isRunning = true

            let develop = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false,
            )
            develop.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
            develop.orderBack(nil)
            defer { develop.orderOut(nil) }
            model.showModule(.develop)
            if let photo = model.items.first(where: { !$0.hasEdits && SupportedFormats.isRaw($0.url) })
                ?? model.items.first(where: { !$0.hasEdits }) {
                model.select(photo.url)
            }
            let opening = ContinuousClock.now
            while !model.hasFrame || model.isLoading, ContinuousClock.now - opening < .seconds(30) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await renders.renderAgain()
            try? await Task.sleep(for: .seconds(12))
            lines.append(rendered("With Develop idle", renders.statistics, seconds: 12))
            await memory.mark("edits, Develop idle")

            renders.isRunning = false
            renders.letEngineGo()
            try? await Task.sleep(for: .milliseconds(500))
            let paused = await askForFrames(model, seconds: 15)
            await renders.renderAgain()
            renders.isRunning = true
            let running = await askForFrames(model, seconds: 15)
            let busy = renders.statistics
            lines.append(rendered("With Develop busy (frames at 60 Hz for 1 s in every 3 s)", busy, seconds: 15))
            lines.append(String(
                format: "Develop's render time with renders paused: p50 %.1f ms, p95 %.1f ms, max %.1f ms (%d frames); "
                    + "running: p50 %.1f ms, p95 %.1f ms, max %.1f ms (%d frames, %d of them asked for while a "
                    + "render's step ran)",
                percentile(paused, 0.5), percentile(paused, 0.95), paused.max() ?? 0, paused.count,
                percentile(running, 0.5), percentile(running, 0.95), running.max() ?? 0, running.count, busy.overlaps,
            ))
            await memory.mark("edits, Develop busy")
            return (scrolling, lines)
        }

        /// Culling every photo at once (LIB-15), in the editor window's own views with the grid shown: every
        /// photo selected, then a rating, a flag, a label and the mark, each taken back by Undo, each change
        /// made in full (every sidecar written) before the next. For each change and Undo, its main-thread work
        /// from the key until the grid has drawn and committed it; the main thread over the phase; how long each
        /// batch took to reach every sidecar; and, after the last Undo, the photos whose sidecars don't read as
        /// they did before the phase.
        private static func cull(_ model: EditorModel) async -> (
            summary: MainThreadMonitor.Summary?, onScreen: [Double], writes: [Double], left: Int, count: Int,
            report: String,
        ) {
            phase("culling every photo")
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false,
            )
            window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
            window.orderBack(nil)
            defer {
                model.showModule(.develop)
                window.orderOut(nil)
                window.contentViewController = nil
            }
            model.showLibrary(.grid)
            // Develop lets go of its photo, so every photo goes through the library's batches.
            if let first = model.items.first {
                model.select(first.url)
            }
            try? await Task.sleep(for: .milliseconds(500))
            // The URLs alone: holding the photos would have the first change copy them all.
            let urls = model.items.map(\.url)
            let sidecars = model.library.sidecars
            phase("culling, reading the sidecars")
            let before = await Task.detached(priority: .userInitiated) {
                urls.map { sidecars.store(for: $0).summary(for: $0) }
            }.value
            phase("culling, selecting every photo")
            model.selectAllPhotos()
            window.displayIfNeeded()
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(300))
            let count = model.selectedPhotos.count
            var onScreen: [Double] = []
            var writes: [Double] = []
            var parts: [String] = []
            let monitor = MainThreadMonitor()
            monitor.start()
            let began = CFAbsoluteTimeGetCurrent()
            for action in [ShortcutAction.rating3, .flagPick, .labelRed, .toggleMark] {
                for (title, step) in [(action.title, action), ("Undo", ShortcutAction.undo)] {
                    let name = "culling, \(step == .undo ? "Undo " : "")\(action.title)"
                    phase(name, sampling: .milliseconds(16))
                    let watch = StepWatch(model.library)
                    let started = CFAbsoluteTimeGetCurrent()
                    model.perform(step)
                    window.displayIfNeeded()
                    CATransaction.flush()
                    let shown = (CFAbsoluteTimeGetCurrent() - started) * 1000
                    while model.isWritingCulling, CFAbsoluteTimeGetCurrent() - started < 900 {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    let written = CFAbsoluteTimeGetCurrent() - started
                    notes.append("\(name): \(watch.summary)")
                    onScreen.append(shown)
                    writes.append(written)
                    parts.append(String(
                        format: "%@ on screen in %.2f ms, in every sidecar in %.1f s",
                        title,
                        shown,
                        written,
                    ))
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - began
            monitor.stop()
            phase("culling, reading the sidecars again")
            let after = await Task.detached(priority: .userInitiated) {
                urls.map { sidecars.store(for: $0).summary(for: $0) }
            }.value
            let left = zip(before, after).count { $0.0 != $0.1 }
            model.deselectOtherPhotos()
            let report = "Culling \(count) photos at once: " + parts.joined(separator: "; ")
                + "; \(left) sidecars not as they were after Undo"
            return (
                monitor.summary(seconds: elapsed), onScreen, writes, left, count,
                report + "\n" + monitor.report("Main thread culling \(count) photos", seconds: elapsed),
            )
        }

        /// "`label`: N rendered, N a second", with the renders' waits, the engines made, and the p50 of the
        /// steps of photos of 12 MP or more (the fixture's raws; its JPEGs and HEICs are 64 by 48) and of
        /// the others.
        private static func rendered(_ label: String, _ statistics: EditRenders.Statistics, seconds: Double) -> String {
            let large = statistics.steps.filter { $0.pixels >= 12_000_000 }
            let small = statistics.steps.filter { $0.pixels < 12_000_000 }
            func steps(_ steps: [EditRenders.Statistics.Step]) -> String {
                String(
                    format: "%d, opened in p50 %.0f ms (max %.0f), rendered in %.0f ms, stored in %.0f ms", steps.count,
                    percentile(steps.map(\.opening), 0.5) * 1000, (steps.map(\.opening).max() ?? 0) * 1000,
                    percentile(steps.map(\.rendering), 0.5) * 1000, percentile(steps.map(\.storing), 0.5) * 1000,
                )
            }
            return String(
                format: "%@: %d edits rendered, %.2f a second (%d failed, %d engines made); %d waits for Develop or "
                    + "the screen, %.1f s in all; photos of 12 MP or more: %@; smaller: %@",
                label, statistics.rendered, Double(statistics.rendered) / seconds, statistics.failed,
                statistics.engines, statistics.waits, Self.seconds(statistics.waited), steps(large), steps(small),
            )
        }

        /// Asks Develop for a frame at 60 Hz for 1 s in every 3 s, for `seconds`, as a slider dragged and let
        /// go does: Develop's render time of each frame that came, in milliseconds.
        private static func askForFrames(_ model: EditorModel, seconds: Double) async -> [Double] {
            let frames = model.debugFrameCount
            let started = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - started < seconds {
                let burst = CFAbsoluteTimeGetCurrent()
                while CFAbsoluteTimeGetCurrent() - burst < 1 {
                    model.requestRender()
                    try? await Task.sleep(for: .microseconds(16667))
                }
                try? await Task.sleep(for: .seconds(2))
            }
            let count = model.debugFrameCount - frames
            return model.debugRenderDurations.suffix(count).map { Self.seconds($0) * 1000 }
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
            let browsing: Set = ["launched", "opened", "visible", "scrolled", "grid scrolled", "grid phases"]
            return memory.phases.filter { browsing.contains($0.label) }.map { mb($0.peak) - base }.max() ?? .infinity
        }

        private static func budgets(
            _ measured: Measured, arrows: Double, blank: Int, browsing footprint: Double,
        ) -> [Budget] {
            let grid = measured.gridPhases.map { phase -> Budget in
                .below(
                    "Main thread p99 scrolling the grid, \(phase.label)",
                    phase.summary?.p99 ?? .infinity,
                    8.3,
                    unit: "ms",
                )
            }
            let browsing: [Budget] = [
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
            ]
            let rest: [Budget] = [
                .below("Main thread p99 typing in the filter bar", measured.typing?.p99 ?? .infinity, 8.3, unit: "ms"),
                .below("The photos a key finds on screen, p95", percentile(measured.typed, 0.95), 16, unit: "ms"),
                .below("Main thread p99 holding the arrow keys", arrows, 8.3, unit: "ms"),
                .below("Blank frames holding the arrow keys", Double(blank), 1, unit: ""),
                .below("Main thread p99 switching modules", percentile(measured.switches, 0.99), 8, unit: "ms"),
                .below("Disk reads switching modules", Double(measured.switchReads), 1, unit: "bytes"),
                .below("Peak footprint over launch, browsing", footprint, 250, unit: "MB"),
                .below(
                    "Main thread p99 scrolling the grid as edits render", measured.editScrolling?.p99 ?? .infinity, 8.3,
                    unit: "ms",
                ),
                .below(
                    "Culling \(measured.cullCount) photos at once on screen, the slowest of 8",
                    measured.culled.max() ?? .infinity, 8.3, unit: "ms",
                ),
                .below(
                    "Main thread p99 culling \(measured.cullCount) photos", measured.culling?.p99 ?? .infinity, 8.3,
                    unit: "ms",
                ),
                .below("Sidecars not as they were after Undo", Double(measured.cullLeft), 1, unit: ""),
            ]
            return browsing + grid + rest
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

    /// What changed while a culling step ran: the library's diffs and their rows.
    @MainActor
    private final class StepWatch {
        private var diffs = 0
        private var resets = 0
        private var rows = 0
        private var observation: LibraryObservation?

        init(_ library: FolderLibrary) {
            observation = library.observe { [weak self] diff in
                guard let self else { return }
                diffs += 1
                resets += diff.reset ? 1 : 0
                rows += diff.removed.count + diff.inserted.count + diff.updated.count
            }
        }

        var summary: String {
            "\(diffs) diffs (\(resets) resets), \(rows) rows"
        }
    }

    /// Samples the main thread through the turns of its run loop (from waking to waiting again, as
    /// `MainThreadMonitor` counts them) that run longer than half a second, in any phase, and in the phases
    /// given a lower threshold (`sample(over:)`), every turn over it: for the turns no phase's numbers
    /// explain, each one's length, the phase it ran in and where the main thread spent it, and for each
    /// phase, where its long turns went. Nothing may allocate while the main thread is suspended, so samples
    /// go into a preallocated buffer, as `MainThreadSampler`'s do.
    @MainActor
    final class StallSampler {
        /// A turn this long is reported on its own, in any phase.
        nonisolated static let stall: UInt64 = 500_000_000
        /// The samples a phase may take of its turns shorter than a stall.
        static let phaseSamples = 8000
        private let samples = Samples()
        private let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        private var observer: CFRunLoopObserver?
        private var turn = 0
        private var began: UInt64 = 0
        private var phases: [Phase] = [Phase(name: "starting", threshold: stall)]
        private var stalls: [(turn: Int, start: Double, length: Double, phase: Int)] = []

        private struct Phase {
            let name: String
            let threshold: UInt64
            /// Its turns over its threshold, and their time, in milliseconds.
            var turns = 0
            var time = 0.0
        }

        /// What the sampling thread shares with the main thread.
        private final class Samples: @unchecked Sendable {
            static let maxDepth = 96
            static let maxSamples = 60000
            static let interval: useconds_t = 4000
            /// Strips pointer-authentication bits from return addresses signed by arm64e system code.
            static let addressMask: UInt = 0x0000_0FFF_FFFF_FFFF
            let mainThread = mach_thread_self()
            let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: maxDepth * maxSamples)
            let depths = UnsafeMutablePointer<Int>.allocate(capacity: maxSamples)
            let turns = UnsafeMutablePointer<Int>.allocate(capacity: maxSamples)
            let phases = UnsafeMutablePointer<Int>.allocate(capacity: maxSamples)
            let count = Atomic<Int>(0)
            let running = Atomic<Bool>(true)
            /// The main thread's turn and phase, when the turn began in nanoseconds of uptime (0 while the
            /// main thread waits), and how long a turn runs before it's sampled.
            let turn = Atomic<Int>(0)
            let phase = Atomic<Int>(0)
            let began = Atomic<UInt64>(0)
            let threshold = Atomic<UInt64>(StallSampler.stall)
            /// The samples the phase may still take of turns shorter than a stall, which always are.
            let budget = Atomic<Int>(0)

            /// Runs the calling thread under a real-time policy: on a loaded Mac a sampler preempted while the
            /// main thread is suspended would freeze it, lengthening the turns it measures.
            static func runInRealTime() {
                var timebase = mach_timebase_info_data_t()
                mach_timebase_info(&timebase)
                func ticks(_ nanoseconds: Double) -> UInt32 {
                    UInt32(nanoseconds * Double(timebase.denom) / Double(timebase.numer))
                }
                var policy = thread_time_constraint_policy_data_t(
                    period: ticks(Double(interval) * 1000), computation: ticks(150_000), constraint: ticks(400_000),
                    preemptible: 0,
                )
                let count = mach_msg_type_number_t(
                    MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size,
                )
                _ = withUnsafeMutablePointer(to: &policy) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        thread_policy_set(
                            pthread_mach_thread_np(pthread_self()),
                            thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                            $0, count,
                        )
                    }
                }
            }

            func sample(stalled: Bool) {
                let index = count.load(ordering: .relaxed)
                guard index < Self.maxSamples else { return }
                if !stalled {
                    guard budget.load(ordering: .relaxed) > 0 else { return }
                    budget.subtract(1, ordering: .relaxed)
                }
                let (turn, phase) = (turn.load(ordering: .relaxed), phase.load(ordering: .relaxed))
                var state = arm_thread_state64_t()
                var stateCount = mach_msg_type_number_t(
                    MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size,
                )
                guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
                defer { thread_resume(mainThread) }
                let result = withUnsafeMutablePointer(to: &state) {
                    $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                        thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &stateCount)
                    }
                }
                guard result == KERN_SUCCESS else { return }
                let frames = buffer + index * Self.maxDepth
                frames[0] = UInt(state.__pc) & Self.addressMask
                frames[1] = UInt(state.__lr) & Self.addressMask
                var depth = 2
                var fp = UInt(state.__fp)
                while fp != 0, fp & 7 == 0, depth < Self.maxDepth,
                      let frame = UnsafePointer<UInt>(bitPattern: fp) {
                    let next = frame[0]
                    let returnAddress = frame[1] & Self.addressMask
                    guard returnAddress != 0 else { break }
                    frames[depth] = returnAddress
                    depth += 1
                    guard next > fp else { break }
                    fp = next
                }
                depths[index] = depth
                turns[index] = turn
                phases[index] = phase
                count.store(index + 1, ordering: .releasing)
            }
        }

        /// From now on, turns are reported under `name`, and sampled once they run longer than `threshold`.
        func enter(_ name: String, sampling threshold: Duration? = nil) {
            let nanoseconds = threshold.map {
                UInt64($0.components.seconds) * 1_000_000_000 + UInt64($0.components.attoseconds / 1_000_000_000)
            } ?? Self.stall
            phases.append(Phase(name: name, threshold: min(nanoseconds, Self.stall)))
            samples.phase.store(phases.count - 1, ordering: .relaxed)
            samples.threshold.store(min(nanoseconds, Self.stall), ordering: .relaxed)
            samples.budget.store(Self.phaseSamples, ordering: .relaxed)
        }

        func start() {
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0,
            ) { [weak self] _, activity in
                MainActor.assumeIsolated { self?.observe(activity) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
            let samples = samples
            let thread = Thread {
                Samples.runInRealTime()
                while samples.running.load(ordering: .relaxed) {
                    let began = samples.began.load(ordering: .acquiring)
                    let running = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- began
                    if began != 0, running > samples.threshold.load(ordering: .relaxed) {
                        samples.sample(stalled: running > StallSampler.stall)
                    }
                    usleep(Samples.interval)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() {
            samples.running.store(false, ordering: .relaxed)
            if let observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
            observer = nil
        }

        private func observe(_ activity: CFRunLoopActivity) {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if activity == .afterWaiting {
                turn += 1
                began = now
                samples.turn.store(turn, ordering: .relaxed)
                samples.began.store(now, ordering: .releasing)
            } else if began != 0 {
                samples.began.store(0, ordering: .releasing)
                let length = now - began
                let phase = phases.count - 1
                if length > phases[phase].threshold {
                    phases[phase].turns += 1
                    phases[phase].time += Double(length) / 1e6
                }
                if length > Self.stall {
                    stalls.append((turn, Double(began - started) / 1e9, Double(length) / 1e6, phase))
                }
                began = 0
            }
        }

        /// One line for the report, "N turns over 500 ms, the longest L ms in P", or nil for none.
        var summary: String? {
            guard let longest = stalls.max(by: { $0.length < $1.length }) else { return nil }
            return String(
                format: "Main-thread turns over %.0f ms: %d, the longest %.1f ms in %@, %.1f s after the start",
                Double(Self.stall) / 1e6, stalls.count, longest.length, phases[longest.phase].name, longest.start,
            )
        }

        /// Every turn over half a second, longest first: its phase, when it began and how long it took, and
        /// for the `detailed` longest, the functions its samples were in (Redlamp's, then all of them) and
        /// their commonest stack; then each phase sampled below half a second, its turns over its threshold
        /// and the functions their samples were in. Symbols are mangled.
        func report(detailed: Int = 6) -> String {
            let count = samples.count.load(ordering: .acquiring)
            var byTurn: [Int: [Int]] = [:]
            var byPhase: [String: [Int]] = [:]
            for index in 0 ..< count {
                byTurn[samples.turns[index], default: []].append(index)
                byPhase[phases[samples.phases[index]].name, default: []].append(index)
            }
            var names: [UInt: String] = [:]
            func name(_ address: UInt) -> String {
                if let cached = names[address] {
                    return cached
                }
                var info = Dl_info()
                var resolved = String(format: "0x%lx", address)
                if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                    let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent }
                    let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
                    resolved = "\(symbol)  [\(image ?? "?")]"
                }
                names[address] = resolved
                return resolved
            }
            func profile(_ indices: [Int], stack: Bool) -> [String] {
                var total: [String: Int] = [:]
                var leaf: [String: Int] = [:]
                var stacks: [String: Int] = [:]
                for index in indices {
                    let frames = samples.buffer + index * Samples.maxDepth
                    var seen = Set<String>()
                    var symbols: [String] = []
                    for level in 0 ..< samples.depths[index] where frames[level] > 1 {
                        // Return addresses point after the call; step back into the calling instruction.
                        let symbol = name(level == 0 ? frames[level] : frames[level] - 1)
                        if seen.insert(symbol).inserted {
                            total[symbol, default: 0] += 1
                        }
                        if level == 0 {
                            leaf[symbol, default: 0] += 1
                        }
                        if stack, symbols.count < 48 {
                            symbols.append(symbol)
                        }
                    }
                    if stack {
                        stacks[symbols.joined(separator: "\n      "), default: 0] += 1
                    }
                }
                func table(_ counts: [String: Int], top: Int) -> [String] {
                    counts.sorted { $0.value > $1.value }.prefix(top).map {
                        String(
                            format: "    %5.1f%%  %@",
                            Double($0.value) / Double(max(indices.count, 1)) * 100,
                            $0.key,
                        )
                    }
                }
                var lines = ["  Redlamp's code, inclusive:"] + table(
                    total.filter { $0.key.contains("[Redlamp") },
                    top: 30,
                )
                lines += ["  Everything, inclusive:"] + table(total, top: 40)
                lines += ["  On top of the stack:"] + table(leaf, top: 15)
                if stack, let (common, times) = stacks.max(by: { $0.value < $1.value }) {
                    lines.append("  The commonest stack (\(times) of \(indices.count) samples):\n      " + common)
                }
                return lines
            }
            var lines = [summary ?? "No main-thread turn over \(Double(Self.stall) / 1e6) ms"]
            for (place, stall) in stalls.sorted(by: { $0.length > $1.length }).enumerated() {
                let indices = byTurn[stall.turn] ?? []
                lines.append(String(
                    format: "- %.1f ms in %@, %.1f s after the start: %d samples",
                    stall.length, phases[stall.phase].name, stall.start, indices.count,
                ))
                if place < detailed, !indices.isEmpty {
                    lines += profile(indices, stack: true)
                }
            }
            var sampled: [String: (threshold: UInt64, turns: Int, time: Double)] = [:]
            for phase in phases where phase.threshold < Self.stall {
                let before = sampled[phase.name] ?? (phase.threshold, 0, 0)
                sampled[phase.name] = (phase.threshold, before.turns + phase.turns, before.time + phase.time)
            }
            for (name, phase) in sampled.sorted(by: { $0.value.time > $1.value.time }) {
                let indices = byPhase[name] ?? []
                lines.append(String(
                    format: "Phase %@: %d turns over %.1f ms, %.1f ms in all; %d samples",
                    name, phase.turns, Double(phase.threshold) / 1e6, phase.time, indices.count,
                ))
                if !indices.isEmpty {
                    lines += profile(indices, stack: false)
                }
            }
            if count == Samples.maxSamples {
                lines.append("(the sample buffer filled up: later turns have no samples)")
            }
            return lines.joined(separator: "\n")
        }
    }
#endif
