#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The left panel's Library and Collections sections on a copy of lib-1m's index (LIB-23): their counts while
    /// they change, which the budget wants under 8.3 ms at p99 on the main thread, and a collection of 10,000 photos
    /// and Rejected shown within the budgets of a source opened (`--library-perf`'s): every photo in the filmstrip
    /// within 300 ms, and the main thread's p99 under 8.3 ms meanwhile. Then the collection as a library view, timed
    /// as folders are: the panels following its selection within 16 ms, Group By and the Tighter–Looser setting
    /// changed with the main thread's p99 under 8.3 ms, and typing in the filter bar, noted. The collection, its sets
    /// and a smart collection are written into the copy's index and definitions; no photo or sidecar of the fixture
    /// is touched. Skipped where the fixture or its index isn't.
    enum LibrarySourcesPerformanceScenarios {
        static let all: [Scenario] = [sources]

        static let sources = Scenario(
            "performance.library-sources",
            "The Library and Collections panels counting lib-1m while counts change, a collection and Rejected shown, "
                + "and the panels, Group By and the filter bar on the collection",
            tiers: [.performance], claims: [],
        ) { app in
            let fixture = URL(
                fileURLWithPath: "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-1m.noindex", isDirectory: true,
            )
            let master = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/indexfix/lib-1m-master/Index.sqlite")
            guard FileManager.default.fileExists(atPath: fixture.path),
                  FileManager.default.fileExists(atPath: master.path)
            else { throw ScenarioSkip("lib-1m and its index aren't on this Mac") }
            // A clone beside the master, on its volume, removed afterwards.
            let work = master.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "library-sources-\(UUID().uuidString)", directoryHint: .isDirectory)
            let paths = LibraryPaths(root: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.copyItem(at: master, to: paths.index)
            guard let selects = CollectionPath("Clients/Acme/Selects"), let portfolio = CollectionPath("Portfolio"),
                  let picked = CollectionPath("Picked, not yet edited")
            else { throw ScenarioFailure("No collection paths") }
            let made = SourcesBenchBox()
            try app.run("a collection of 10,000 photos written into the copy", timeout: 120) { _ in
                await made.prepare(paths, selects: selects, portfolio: portfolio, picked: picked)
            }
            try app.expect(made.changing.count == 1000, "\(made.changing.count) photos to change")

            try app.main { model in
                let library = FolderLibrary()
                library.add([fixture])
                let service = LibraryService(paths: paths, sidecars: library.sidecars) { _, _ in nil }
                library.attach(service)
                let editor = EditorModel(engine: model.makeWorkerEngine?() ?? model.engine, library: library)
                editor.showModule(.library)
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 280, height: 900), styleMask: [.titled],
                    backing: .buffered, defer: false,
                )
                window.contentView = LibrarySourcesViews.make(model: editor)
                window.contentView?.layoutSubtreeIfNeeded()
                made.open(library: library, service: service, editor: editor, window: window)
            }
            defer { try? app.main { _ in made.close() } }
            try app.wait("lib-1m counted from its index", timeout: 300) { _ in
                guard let sources = made.editor?.librarySources else { return false }
                return sources.count(of: .allPhotographs) ?? 0 > 900_000 && sources
                    .count(of: .collection(selects)) == 10000
            }

            // The counts changing: a thousand photos marked and put in Portfolio, then taken out again, every half
            // second.
            let counting = try MainThread.run { () -> MainThreadMonitorBox in
                let monitor = MainThreadMonitor()
                monitor.start()
                return MainThreadMonitorBox(monitor)
            }
            let started = Date()
            let tookBefore = try app.main { _ in made.editor?.librarySources.countsTook.count ?? 0 }
            for step in 0 ..< 24 {
                try app.run("changing a thousand photos' counts", timeout: 60) { _ in
                    await made.change(marking: step.isMultiple(of: 2), portfolio: portfolio)
                }
                app.pause(0.5)
            }
            try app.wait("the last counts", timeout: 60) { _ in
                made.editor?.librarySources.count(of: .marked) == nil
                    && made.editor?.librarySources.count(of: .collection(portfolio)) == 0
            }
            let seconds = Date().timeIntervalSince(started)
            let summary = try MainThread.run { () -> MainThreadMonitor.Summary? in
                counting.monitor.stop()
                return counting.monitor.summary(seconds: seconds)
            }
            guard let summary else { throw ScenarioFailure("No main-thread turns while the counts changed") }
            let took = try app.main { _ in Array((made.editor?.librarySources.countsTook ?? []).dropFirst(tookBefore)) }
            let slowest = took.map { $0 / .milliseconds(1) }.max() ?? 0
            app.record("e2e-library-counts-p99", summary.p99)
            app.record("e2e-library-counts-max", summary.max)
            app.record("e2e-library-counts-slowest", slowest)
            let changes = "24 changes in \(String(format: "%.1f", seconds)) s, \(took.count) counts (slowest "
                + "\(String(format: "%.0f", slowest)) ms off the main thread)"
            let turns = "main thread p50 \(summary.p50) ms, p95 \(summary.p95) ms, p99 \(summary.p99) ms, "
                + "max \(summary.max) ms, \(summary.overFrame) turns over 8.3 ms"
            app.recorder.write("note", ["library-counts": "\(changes): \(turns)"])

            // A collection and a Library entry shown.
            var shown: [(String, Double, MainThreadMonitor.Summary?)] = []
            let rejects = try app.main { _ in made.editor?.librarySources.count(of: .rejected) ?? 0 }
            for (name, source, count) in [
                ("collection", LibrarySource.collection(selects), 10000), ("rejected", .rejected, rejects),
            ] {
                let opening = try MainThread.run { () -> MainThreadMonitorBox in
                    let monitor = MainThreadMonitor()
                    monitor.start()
                    return MainThreadMonitorBox(monitor)
                }
                let start = Date()
                try app.main { _ in _ = made.editor?.librarySources.show(source) }
                try app.wait("\(name) shown", timeout: 60) { _ in
                    guard let editor = made.editor else { return false }
                    return !editor.librarySources.isListing && editor.items.count == count
                }
                let milliseconds = Date().timeIntervalSince(start) * 1000
                let summary = try MainThread.run { () -> MainThreadMonitor.Summary? in
                    opening.monitor.stop()
                    return opening.monitor.summary(seconds: milliseconds / 1000)
                }
                app.record("e2e-library-source-\(name)", milliseconds)
                if let summary {
                    app.record("e2e-library-source-\(name)-p99", summary.p99)
                }
                shown.append((name, milliseconds, summary))
            }
            app.recorder.write("note", [
                "library-sources": shown.map { name, milliseconds, summary in
                    "\(name): every photo in \(String(format: "%.0f", milliseconds)) ms, main thread p99 "
                        + "\(summary.map { String(format: "%.2f", $0.p99) } ?? "-") ms"
                }.joined(separator: "; "),
            ])

            try views(app, made, selects)

            try app.expect(summary.p99 < 8.3, "The main thread's p99 was \(summary.p99) ms while the counts changed")
            for (name, milliseconds, summary) in shown {
                try app.expect(milliseconds < 300, "\(name)'s photos took \(milliseconds) ms")
                try app.expect((summary?.p99 ?? 0) < 8.3, "\(name)'s main thread p99 was \(summary?.p99 ?? 0) ms")
            }
            let panels = try app.main { _ in (made.measured["panels"] ?? []).dropFirst().max() ?? .infinity }
            try app.expect(panels < 16, "The collection's selection reached the panels in up to \(panels) ms")
            let grouping = try app.main { _ in made.turns["grouping"]?.p99 ?? .infinity }
            try app.expect(grouping < 8.3, "Group By on the collection: the main thread's p99 was \(grouping) ms")
        }

        /// The collection as a library view: the panels following its selection, Group By and the filter bar on it,
        /// timed as they're timed on folders, and noted.
        private static func views(_ app: RunningApp, _ made: SourcesBenchBox, _ selects: CollectionPath) throws {
            try app.main { _ in _ = made.editor?.librarySources.show(.collection(selects)) }
            try app.wait("the collection again", timeout: 60) { _ in
                guard let editor = made.editor else { return false }
                return !editor.librarySources.isListing && editor.items.count == 10000
                    && editor.library.isShownFromLibrary
            }
            try app.run("the panels following the collection's selection", timeout: 300) { _ in
                await made.measurePanels()
            }
            try app.main { _ in made.openModules() }
            try app.run("Group By on the collection", timeout: 300) { _ in await made.measureGrouping() }
            try app.run("typing in the filter bar on the collection", timeout: 900) { _ in await made.measureTyping() }
            let (measured, turns, suggested) = try app.main { _ in (made.measured, made.turns, made.suggested) }
            func sorted(_ name: String) -> [Double] {
                (measured[name] ?? []).sorted()
            }
            func percentile(_ name: String, _ share: Double) -> Double {
                let times = sorted(name)
                return times.isEmpty ? .infinity : times[min(times.count - 1, Int(Double(times.count) * share))]
            }
            func described(_ name: String) -> String {
                let times = sorted(name)
                return String(
                    format: "%d, p50 %.1f ms, p95 %.1f ms, max %.1f ms", times.count, percentile(name, 0.5),
                    percentile(name, 0.95), times.last ?? 0,
                )
            }
            func mainThread(_ name: String) -> String {
                turns[name].map { String(format: "main thread p99 %.2f ms, max %.1f ms", $0.p99, $0.max) } ?? "-"
            }
            let panels: [Double] = Array((measured["panels"] ?? []).dropFirst())
            app.record("e2e-collection-panels-max", panels.max() ?? .infinity)
            app.record("e2e-collection-grouping-p95", percentile("grouping", 0.95))
            app.record("e2e-collection-grouping-p99", turns["grouping"]?.p99 ?? .infinity)
            app.record("e2e-collection-typing-p95", percentile("typing", 0.95))
            app.record("e2e-collection-typing-p99", turns["typing"]?.p99 ?? .infinity)
            app.record("e2e-collection-suggestion-max", sorted("suggestion").last ?? .infinity)
            var note = "10,000 photos: the panels following the selection \(described("panels")), the first "
            note += String(format: "%.1f ms", measured["panels"]?.first ?? 0)
            note += "; Group By and the setting on screen \(described("grouping")), \(mainThread("grouping")), "
            note += String(format: "the first grouping %.0f ms", measured["grouping-first"]?.first ?? 0)
            note += "; typing, a key's photos on screen \(described("typing")), \(mainThread("typing"))"
            note += "; the suggestion on screen \(described("suggestion")) (\(suggested.joined(separator: ", ")))"
            note += "; load \(ProcessInfo.processInfo.loadAverage)"
            app.recorder.write("note", ["collection-views": note])
        }
    }

    /// The performance scenario's own library, panels and window, kept on the main thread, and the photos it changes.
    @MainActor
    private final class SourcesBenchBox: @unchecked Sendable {
        private(set) var library: FolderLibrary?
        private(set) var service: LibraryService?
        private(set) var editor: EditorModel?
        private var window: NSWindow?
        /// The thousand photos the counts' changes mark and put in Portfolio.
        private(set) nonisolated(unsafe) var changing: [Int64] = []

        /// Puts 10,000 of the copy's photos in a collection inside two sets, and keeps a smart collection and an
        /// empty one in its definitions, the collection the target.
        nonisolated func prepare(
            _ paths: LibraryPaths, selects: CollectionPath, portfolio: CollectionPath, picked: CollectionPath,
        ) async {
            guard let index = try? await LibraryIndex.open(at: paths.index, readers: 2) else { return }
            let ids = await (try? index.write { writer -> [Int64] in
                let ids = try writer.database.cached("SELECT id FROM photos ORDER BY id LIMIT 11000")
                    .map { $0.int64(at: 0) }
                for id in ids.prefix(10000) {
                    try writer.setCollections([selects.text], forPhoto: id)
                }
                return ids
            }) ?? []
            changing = Array(ids.suffix(1000))
            let definitions = CollectionDefinitions(collections: [
                selects: CollectionOptions(), portfolio: CollectionOptions(), picked: .smart("flag:pick edited:no"),
            ], target: selects)
            try? definitions.save(to: CollectionDefinitions.url(in: paths))
        }

        func open(library: FolderLibrary, service: LibraryService, editor: EditorModel, window: NSWindow) {
            self.library = library
            self.service = service
            self.editor = editor
            self.window = window
        }

        /// Marks the thousand photos and puts them in Portfolio, or takes both away, in the index, and tells the lists.
        func change(marking: Bool, portfolio: CollectionPath) async {
            guard let library, let service, let index = library.libraryIndex else { return }
            let ids = changing
            _ = try? await index.write { writer in
                for id in ids {
                    guard var row = try writer.photo(id: id) else { continue }
                    row.marked = marking
                    try writer.upsertPhotos([row])
                    try writer.setCollections(marking ? [portfolio.text] : [], forPhoto: id)
                }
            }
            service.rowsChanged(ids)
        }

        func close() {
            window?.contentView = nil
            modules?.orderOut(nil)
            modules?.contentViewController = nil
            service?.close()
            window = nil
            modules = nil
            editor = nil
            library = nil
            service = nil
        }

        // MARK: - The collection as a library view

        private var modules: NSWindow?
        /// What's measured on the collection, in milliseconds, by part, and the main thread over each part.
        private(set) var measured: [String: [Double]] = [:]
        private(set) var turns: [String: MainThreadMonitor.Summary] = [:]
        /// The suggestions shown, each after the text typed.
        private(set) var suggested: [String] = []

        /// The editor's own module views in a window of their own, behind the others, for what's timed on screen.
        func openModules() {
            guard let editor else { return }
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false,
            )
            window.contentViewController = ModuleViews.make(model: editor, theme: ThemeSettings())
            window.setContentSize(NSSize(width: 1600, height: 1000))
            window.orderBack(nil)
            modules = window
            editor.showModule(.library)
            editor.showLibrary(.grid)
        }

        /// Each selection change's time to reach the panels, every photo of the collection selected and then one by
        /// turns, the panels in no window, as `performance.library-panels` times them on folders.
        func measurePanels() async {
            guard let editor else { return }
            let panels = editor.libraryPanels
            panels.follow()
            var times: [Double] = []
            for step in 0 ..< 12 {
                await panels.refreshed()
                let before = panels.followed.count
                if step.isMultiple(of: 2) {
                    editor.selectAllPhotos()
                } else {
                    editor.select(editor.items[step % 7 + 1].url)
                }
                let selected = editor.photoSelection.isEmpty ? 1 : editor.photoSelection.count
                let started = ContinuousClock.now
                while panels.followed.count <= before || panels.selection.count != selected,
                      ContinuousClock.now - started < .seconds(20) {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                times.append(panels.followed.last.map(Self.milliseconds) ?? .infinity)
            }
            measured["panels"] = times
        }

        /// Group By and the Tighter–Looser setting changed on the collection, twice through: each change's time
        /// until its groups are drawn and committed, and the main thread meanwhile, as `--library-perf` times them
        /// on folders. The first grouping, which reads the photos' IDs, is timed apart.
        func measureGrouping() async {
            guard let editor, let window = modules else { return }
            editor.select(editor.items[0].url)
            try? await Task.sleep(for: .milliseconds(500))
            let groups = editor.gridGroups
            func grouped(by key: GroupKey, looseness: Int, since started: ContinuousClock.Instant) async -> Bool {
                let setting = MomentSetting(looseness: looseness)
                while groups.list.map({ $0.groups.key != key || $0.groups.setting != setting }) ?? true,
                      ContinuousClock.now - started < .seconds(5) {
                    try? await Task.sleep(for: .microseconds(250))
                }
                guard groups.list.map({ $0.groups.key == key && $0.groups.setting == setting }) == true else {
                    return false
                }
                window.displayIfNeeded()
                CATransaction.flush()
                return true
            }
            var started = ContinuousClock.now
            editor.setGroupKey(.moment)
            if await grouped(by: .moment, looseness: 0, since: started) {
                measured["grouping-first"] = [Self.milliseconds(ContinuousClock.now - started)]
            }
            try? await Task.sleep(for: .milliseconds(300))
            let monitor = MainThreadMonitor()
            monitor.start()
            let began = ContinuousClock.now
            var onScreen: [Double] = []
            for _ in 0 ..< 2 {
                for key in [GroupKey.day, .camera, .folder, .lens, .orientation, .momentCamera, .moment] {
                    started = .now
                    editor.setGroupKey(key)
                    if await grouped(by: key, looseness: 0, since: started) {
                        onScreen.append(Self.milliseconds(ContinuousClock.now - started))
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                for looseness in [-1, -2, -1, 0, 1, 2, 1, 0] {
                    started = .now
                    editor.setLooseness(looseness)
                    if await grouped(by: .moment, looseness: looseness, since: started) {
                        onScreen.append(Self.milliseconds(ContinuousClock.now - started))
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            monitor.stop()
            if let summary = monitor.summary(seconds: Self.seconds(ContinuousClock.now - began)) {
                turns["grouping"] = summary
            }
            measured["grouping"] = onScreen
            editor.setLooseness(0)
            editor.setGroupKey(.ungrouped)
        }

        /// The fixture's queries typed in the filter bar a character at a time, a key every 60 ms, the metadata
        /// columns shown: for each key that changes what the filter finds, its time until the photos it finds are
        /// drawn and committed, and the main thread meanwhile, as `--library-perf` times them on folders. Then
        /// misspelt names, each one's last key timed until the suggestion is drawn.
        func measureTyping() async {
            guard let editor, let window = modules, let filters = editor.libraryFilters else { return }
            filters.setFilter(LibraryFilter(sections: [.text, .metadata]))
            filters.setBarShown(true)
            try? await Task.sleep(for: .milliseconds(500))
            /// Until the library has listed what `text` reads as, or a second.
            func listed(_ text: String, since started: ContinuousClock.Instant) async -> Bool {
                let query = (try? LibraryQuery(parsing: text, asYouType: true)).map { $0 == .all ? nil : $0 }
                guard let query else { return false }
                while filters.lastListed?.query != query, ContinuousClock.now - started < .seconds(1) {
                    try? await Task.sleep(for: .microseconds(250))
                }
                return filters.lastListed?.query == query
            }
            let monitor = MainThreadMonitor()
            monitor.start()
            let began = ContinuousClock.now
            var onScreen: [Double] = []
            for query in FixtureQuery.corpus {
                LibraryFilterBars.clear(in: window)
                _ = await listed("", since: .now)
                var typed = ""
                for character in query.text {
                    let before = (try? LibraryQuery(parsing: typed, asYouType: true)) ?? .all
                    typed.append(character)
                    let started = ContinuousClock.now
                    guard LibraryFilterBars.type(String(character), in: window) else { break }
                    if let after = try? LibraryQuery(parsing: typed, asYouType: true), after != before,
                       await listed(typed, since: started) {
                        window.displayIfNeeded()
                        CATransaction.flush()
                        onScreen.append(Self.milliseconds(ContinuousClock.now - started))
                    }
                    let wait = started + .milliseconds(60) - ContinuousClock.now
                    if wait > .zero {
                        try? await Task.sleep(for: wait)
                    }
                }
            }
            monitor.stop()
            if let summary = monitor.summary(seconds: Self.seconds(ContinuousClock.now - began)) {
                turns["typing"] = summary
            }
            measured["typing"] = onScreen

            var suggestions: [Double] = []
            for text in ["kw:birdz", "sunzet", "camera:canom"] {
                LibraryFilterBars.clear(in: window)
                _ = await listed("", since: .now)
                LibraryFilterBars.type(String(text.dropLast()), in: window)
                _ = await listed(String(text.dropLast()), since: .now)
                try? await Task.sleep(for: .milliseconds(300))
                let started = ContinuousClock.now
                guard LibraryFilterBars.type(String(text.suffix(1)), in: window),
                      await listed(text, since: started), filters.listed?.shown == 0
                else { continue }
                while filters.suggestion == nil, ContinuousClock.now - started < .seconds(1) {
                    try? await Task.sleep(for: .microseconds(250))
                }
                guard let suggestion = filters.suggestion else { continue }
                window.displayIfNeeded()
                CATransaction.flush()
                suggestions.append(Self.milliseconds(ContinuousClock.now - started))
                suggested.append("\(text) → \(suggestion.term)")
            }
            measured["suggestion"] = suggestions
            filters.setFilter(LibraryFilter())
            filters.setBarShown(false)
        }

        private nonisolated static func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }

        private nonisolated static func seconds(_ duration: Duration) -> Double {
            milliseconds(duration) / 1000
        }
    }
#endif
