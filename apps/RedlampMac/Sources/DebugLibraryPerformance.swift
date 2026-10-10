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
    /// [--library-perf-profile] [--library-perf-only <parts>] [--library-perf-quit]`:
    /// the library in the app (docs/plans/2026-10-05-library-design.md, The stress harness), on a fixture made by
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
    /// culling every photo at once (LIB-15): a rating, a flag, a label and the mark, each undone, each
    /// on screen and in every sidecar, the sidecars checked to read as they did after the last Undo, and
    /// Group By in the grid (LIB-41): each key and moments' setting, every group closed and opened, and
    /// the arrow keys held through the groups, and relaunches with every edit rendered (LIB-17): when the grid's
    /// first screen shows the stored renders. `--library-perf-groups-only` measures Group By alone once the
    /// fixture is open.
    /// The footprint is followed through every phase, then after a memory-pressure trim and a few idle
    /// seconds.
    /// Nothing joins the working set, and the temporary library is removed at the end;
    /// `--library-perf-library <folder>` keeps it in `<folder>` instead, where the next run finds it
    /// indexed.
    ///
    /// Writes its report to `PerformanceReport.text` (/tmp/redlamp-perf.txt, or perf.txt in the directory
    /// `--perf-report` names), ending with each budget's PASS or FAIL, and the metrics to perf.json beside
    /// it, as `--folders-perf` does; with `--library-perf-quit` it then quits,
    /// with status 1 if a budget failed. `--library-perf-memory` also breaks the footprint down at
    /// each phase into memory.txt beside it, and `--library-perf-profile` samples the main thread
    /// while the grid scrolls into /tmp/redlamp-profile.txt. Every turn of the main thread's run loop
    /// longer than half a second is sampled (with `--library-perf-turns`, while typing and culling every turn
    /// longer than 16 ms, and while grouping and holding the arrow keys every turn longer than 8 ms; with
    /// `--library-perf-profile-turns`, every turn of those phases from its start), and where they went written to
    /// /tmp/redlamp-stalls.txt, with what changed in each culling step.
    @MainActor
    enum DebugLibraryPerformance {
        static var stalls: StallSampler?

        /// Names the phase in the debug log and in the stall report, its turns sampled once they run longer
        /// than `sampling` (half a second when nil).
        static func phase(_ name: String, sampling: Duration? = nil) {
            trace(name)
            let arguments = LaunchArguments.all
            let sampled = arguments.contains("--library-perf-turns") || arguments
                .contains("--library-perf-profile-turns")
            stalls?.enter(name, sampling: sampled ? sampling : nil)
        }

        /// `text` in the debug log, written off the main thread.
        static func trace(_ text: String) {
            let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) library-perf: \(text)\n"
            log.async {
                guard let handle = FileHandle(forWritingAtPath: "/tmp/redlamp-debug.log") else {
                    try? line.write(toFile: "/tmp/redlamp-debug.log", atomically: true, encoding: .utf8)
                    return
                }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }

        /// Phases are logged off the main thread: opening the log can take a frame or more on a busy Mac,
        /// within the phases measured.
        static let log = DispatchQueue(label: "app.redlamp.library-perf.log", qos: .utility)

        /// Where the stall report goes: beside the run's report, or /tmp/redlamp-stalls.txt.
        static var stallsPath: String {
            PerformanceReport.directory.map { ($0 as NSString).appendingPathComponent("stalls.txt") }
                ?? "/tmp/redlamp-stalls.txt"
        }

        /// Writes the stall report, and with `--library-perf-profile-turns` the stacks sampled beside it
        /// (stalls-folded.txt, or /tmp/redlamp-stalls-folded.txt).
        static func write(_ stalls: StallSampler) {
            try? ((notes + [stalls.report()]).joined(separator: "\n") + "\n")
                .write(toFile: stallsPath, atomically: true, encoding: .utf8)
            if let folded = stalls.folded() {
                let path = (stallsPath as NSString).deletingPathExtension + "-folded.txt"
                try? folded.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }

        /// What the stall report adds about each phase: what changed in it.
        static var notes: [String] = []

        /// The temporary library and thumbnail packs a run makes, removed as it ends, and by `finish` before
        /// `--library-perf-quit` quits, which runs no `defer`.
        static var leftovers: [URL] = []

        static func removeLeftovers() {
            for url in leftovers {
                try? FileManager.default.removeItem(at: url)
            }
            leftovers = []
        }

        struct Measured {
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
            var arrows: [(label: String, held: HeldArrows)] = []
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
            /// Group By (LIB-41): the main thread changing the key and moments' setting, and each change's
            /// photos on screen; opening and closing every group, the main thread and each one on screen; and
            /// the arrow keys held through the groups.
            var grouping: MainThreadMonitor.Summary?
            var regrouped: [Double] = []
            var toggling: MainThreadMonitor.Summary?
            var toggled: [Double] = []
            var groupArrows: MainThreadMonitor.Summary?
            var grouped = false
            /// After each relaunch (LIB-17), the milliseconds until every photo on the grid's first screen whose render
            /// is stored shows it.
            var relaunchRenders: [Double] = []
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

        /// What the phases after the launch share: the fixture, the editor and its library, what a relaunch opens
        /// them again with, and what they've measured and reported so far.
        struct Session {
            let fixture: URL
            var model: EditorModel
            var library: FolderLibrary
            var loader: ThumbnailLoader
            let memory: MemoryPhases
            var service: LibraryService
            let paths: LibraryPaths
            let packs: ThumbnailPacks
            let engine: any EditingEngine
            let thumbnail: @Sendable (URL, Int) -> CGImage?
            var lines: [String]
            var measured: Measured
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
            appWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            // With nobody at the Mac, its windows out of sight, App Nap would otherwise lower every thread to
            // the background band within minutes and stop the run.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Measuring the library",
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let stalls = StallSampler()
            self.stalls = stalls
            stalls.start()
            let kept = arguments.firstIndex(of: "--library-perf-library").flatMap {
                $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true) : nil
            }
            let paths = LibraryPaths(root: kept ?? FileManager.default.temporaryDirectory
                .appending(path: "library-perf-\(UUID().uuidString)", directoryHint: .isDirectory))
            if kept == nil {
                leftovers.append(paths.root)
            }
            defer { removeLeftovers() }
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
            leftovers.append(packs.directory)
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
            var session = Session(
                fixture: fixture, model: model, library: library, loader: loader, memory: memory, service: service,
                paths: paths, packs: packs, engine: engine, thumbnail: thumbnail, lines: lines, measured: measured,
            )
            await launch(&session)
            await open(&session)

            if arguments.contains("--library-perf-groups-only") {
                letGoOfHiddenWindows()
                await measureGroups(&session)
                memory.stop()
                service.close()
                stalls.stop()
                self.stalls = nil
                write(stalls)
                return finish(
                    session.lines, budgets: groupBudgets(session.measured), memory: memory, title: fixture.path,
                )
            }
            await measureBrowsing(&session)
            await measureEditing(&session)
            if part("relaunch") {
                await relaunch(&session)
            }
            await settle(&session, stalls: stalls)
            report(session)
        }
    }

    @MainActor
    extension DebugLibraryPerformance {
        /// The library open from the index it was indexed into, searchable, and caught up with the disk.
        private static func launch(_ session: inout Session) async {
            let (library, service, memory) = (session.library, session.service, session.memory)
            let launched = ContinuousClock.now
            library.attach(service)
            while !service.isReady, service.state == .opening {
                try? await Task.sleep(for: .milliseconds(1))
            }
            session.measured.ready = ContinuousClock.now - launched
            if let engine = service.engine, let query = try? LibraryQuery(parsing: "rating>=1") {
                _ = try? await engine.search(query).first { @Sendable result in result.count != nil }
            }
            session.measured.searchable = ContinuousClock.now - launched
            while await !service.canShow(session.fixture, includingSubfolders: true),
                  ContinuousClock.now - launched < .seconds(30) {
                try? await Task.sleep(for: .milliseconds(2))
            }
            session.measured.launch = ContinuousClock.now - launched
            let measured = session.measured
            session.lines.append(
                "Warm launch: open in \(ms(measured.ready)), searchable in \(ms(measured.searchable)), caught up with the disk in \(ms(measured.launch))",
            )
            await memory.mark("launched")
        }

        /// The fixture opened in the filmstrip with its subfolders, its visible thumbnails, and the filmstrip
        /// scrolled.
        private static func open(_ session: inout Session) async {
            let (library, model, memory) = (session.library, session.model, session.memory)
            phase("opening")
            let monitor = MainThreadMonitor()
            monitor.start()
            let openStarted = ContinuousClock.now
            library.setIncludesSubfolders(true)
            library.open(session.fixture)
            while library.isListing || library.count == 0, ContinuousClock.now - openStarted < .seconds(30) {
                try? await Task.sleep(for: .milliseconds(1))
            }
            session.measured.opened = ContinuousClock.now - openStarted
            session.measured.fromLibrary = library.isShownFromLibrary
            session.measured.count = library.count
            try? await Task.sleep(for: .milliseconds(200))
            monitor.stop()
            session.measured.opening = monitor.summary(seconds: seconds(ContinuousClock.now - openStarted))
            let measured = session.measured
            session.lines.append(
                "Opening it in the filmstrip: \(measured.count) photos in \(ms(measured.opened)), \(measured.fromLibrary ? "from the library" : "listed from the disk")",
            )
            session.lines.append(monitor.report(
                "Main thread opening it", seconds: seconds(ContinuousClock.now - openStarted),
            ))
            await memory.mark("opened")

            phase("the visible thumbnails")
            let visible = Array(model.items.prefix(15))
            let thumbnailsStarted = ContinuousClock.now
            await load(visible, with: session.loader)
            session.measured.visible = ContinuousClock.now - thumbnailsStarted
            session.lines.append("Visible thumbnails (15, from the store): \(ms(session.measured.visible))")
            await memory.mark("visible")

            phase("scrolling the filmstrip")
            let (scrolling, scrollReport) = await DebugFoldersPerformance.scroll(model)
            session.measured.scrolling = scrolling
            session.lines.append(scrollReport)
            await memory.mark("scrolled")
        }

        /// The parts that browse: the grid scrolled, the filter bar typed in, and the arrow keys held.
        private static func measureBrowsing(_ session: inout Session) async {
            let (model, memory) = (session.model, session.memory)
            if part("grid") {
                let (gridScrolling, gridReport) = await scrollGrid(model)
                session.measured.gridScrolling = gridScrolling
                session.lines.append(gridReport)
                await memory.mark("grid scrolled")
                for (label, size, style) in [
                    ("expanded cells", GridSize.standard, GridCellStyle.expanded),
                    ("the largest thumbnails, from the preview tier", GridSize.range.upperBound, .compact),
                ] {
                    let (summary, report) = await scrollGrid(model, size: size, style: style, label: label)
                    session.measured.gridPhases.append((label, summary))
                    session.lines.append(report)
                }
                await memory.mark("grid phases")
            }

            if part("typing") {
                let (typing, typed, typingReport) = await typeInFilterBar(model)
                session.measured.typing = typing
                session.measured.typed = typed
                session.lines.append(typingReport)
                await memory.mark("typed")
            }

            if part("arrows") {
                for (label, interval) in [("at the key-repeat rate (30 ms)", 0.030), ("at 120 Hz", 1.0 / 120)] {
                    phase("holding the arrow keys \(label)", sampling: .milliseconds(8))
                    let held = await holdArrow(model, loader: session.loader, interval: interval, steps: 300)
                    session.measured.arrows.append((label, held))
                    session.lines.append(String(
                        format: "Held arrow keys %@: %d steps, %d blank frames", label, held.steps, held.blank,
                    ))
                    session.lines.append(held.report)
                }
                await memory.mark("held arrows")
            }
        }

        /// The parts that change the library: switching modules, rendering edits, culling and grouping.
        private static func measureEditing(_ session: inout Session) async {
            let (model, memory) = (session.model, session.memory)
            if part("switching") {
                let switched = await switchModules(model, count: 200)
                session.measured.switches = switched.durations
                session.measured.switchReads = switched.reads
                session.lines.append(switched.report)
                await memory.mark("switched")
            }

            if part("edits") {
                let edits = await renderEdits(model, memory: memory)
                session.measured.editScrolling = edits.scrolling
                session.lines += edits.lines
            }

            if part("culling") {
                let culled = await cull(model)
                (session.measured.culling, session.measured.culled, session.measured.cullWrites) = (
                    culled.summary,
                    culled.onScreen,
                    culled.writes,
                )
                (session.measured.cullLeft, session.measured.cullCount) = (culled.left, culled.count)
                session.lines.append(culled.report)
                await memory.mark("culled")
            }

            if part("grouping") {
                await measureGroups(&session)
                await memory.mark("grouped")
            }
        }

        private static func measureGroups(_ session: inout Session) async {
            let groups = await group(session.model)
            session.lines.append(groups.report)
            session.measured.grouped = groups.grouped
            (session.measured.grouping, session.measured.regrouped) = (groups.changing, groups.onScreen)
            (session.measured.toggling, session.measured.toggled, session.measured.groupArrows) = (
                groups.toggling,
                groups.toggled,
                groups.arrows,
            )
        }

        /// A few idle seconds, a memory-pressure trim and a few more; the library closed and the stalls reported.
        private static func settle(_ session: inout Session, stalls: StallSampler) async {
            let memory = session.memory
            phase("settling")
            try? await Task.sleep(for: .seconds(3))
            await memory.mark("settled")
            session.loader.trim(to: 0)
            _ = malloc_zone_pressure_relief(nil, 0)
            await memory.mark("trimmed")
            try? await Task.sleep(for: .seconds(5))
            await memory.mark("idle")
            memory.stop()
            session.service.close()
            session.lines.append(memory.summary())
            stalls.stop()
            self.stalls = nil
            session.lines.append((stalls.summary ?? "No main-thread turn over 500 ms") + " (\(Self.stallsPath))")
            write(stalls)
        }

        /// The metrics written to perf.json, and the report with its budgets.
        private static func report(_ session: Session) {
            let measured = session.measured
            let arrows = measured.arrows.compactMap(\.held.summary?.p99).max() ?? .infinity
            let blank = measured.arrows.reduce(0) { $0 + $1.held.blank }
            let browsing = browsingPeak(session.memory)
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
                "library-main-grouping": measured.grouping?.p99 ?? .infinity,
                "library-group-on-screen": measured.regrouped.max() ?? .infinity,
                "library-main-group-toggles": measured.toggling?.p99 ?? .infinity,
                "library-group-toggle-on-screen": measured.toggled.max() ?? .infinity,
                "library-main-group-arrows": measured.groupArrows?.p99 ?? .infinity,
                "library-relaunch-renders": percentile(measured.relaunchRenders, 0.5),
            ])
            let budgets: [Budget] = budgets(measured, arrows: arrows, blank: blank, browsing: browsing)
                + groupBudgets(measured)
            finish(
                session.lines,
                budgets: budgets,
                memory: session.memory,
                title: "Memory on \(session.fixture.path), \(measured.count) photos",
            )
        }

        /// Whether the part `name` (grid, typing, arrows, switching, edits, culling, grouping or relaunch) runs: every
        /// part, unless `--library-perf-only` names those that do, comma-separated, for profiling one.
        static func part(_ name: String) -> Bool {
            letGoOfHiddenWindows()
            let arguments = LaunchArguments.all
            if let index = arguments.firstIndex(of: "--library-perf-only"), index + 1 < arguments.count,
               !arguments[index + 1].split(separator: ",").contains(Substring(name)) {
                return false
            }
            let windows = NSApp.windows
            trace("\(name): \(windows.count) windows, \(windows.count { $0.contentView?.subviews.isEmpty == false }) "
                + "with views")
            return true
        }

        /// The app's own windows when the run began.
        static var appWindows: Set<ObjectIdentifier> = []

        /// Lets go of the views of the windows the phases before made and ordered out: AppKit keeps an
        /// ordered-out window, and its views would go on following the model, doing each later phase's work
        /// again, where the app has one window.
        static func letGoOfHiddenWindows() {
            for window in NSApp.windows where !window.isVisible && !appWindows.contains(ObjectIdentifier(window)) {
                window.contentViewController = nil
                window.contentView = nil
            }
        }

        /// Indexes `fixture` into a new library at `paths` until it's caught up and its thumbnails
        /// are made, then closes it as quitting does; returns how many photos it holds.
        static func index(
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
                    trace("\(count) photos indexed")
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

        static func budgets(
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

        static func finish(_ lines: [String], budgets: [Budget], memory: MemoryPhases, title: String) {
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
                try? (table + "\n").write(toFile: PerformanceReport.memory, atomically: true, encoding: .utf8)
            }
            try? (report + "\n").write(toFile: PerformanceReport.text, atomically: true, encoding: .utf8)
            if LaunchArguments.all.contains("--library-perf-quit") {
                removeLeftovers()
                if failed.isEmpty {
                    NSApp.terminate(nil)
                } else {
                    exit(1)
                }
            }
        }

        static func loadAverage() -> String {
            var loads = [Double](repeating: 0, count: 3)
            guard getloadavg(&loads, 3) == 3 else { return "unknown" }
            return loads.map { String(format: "%.1f", $0) }.joined(separator: " ")
        }

        static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        static func ms(_ duration: Duration) -> String {
            String(format: "%.1f ms", seconds(duration) * 1000)
        }
    }
#endif
