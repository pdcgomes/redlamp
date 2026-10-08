#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The left panel's Library and Collections sections on a copy of lib-1m's index (LIB-23): their counts while
    /// they change, which the budget wants under 8.3 ms at p99 on the main thread, and a collection of 10,000 photos
    /// and Rejected shown within the budgets of a source opened (`--library-perf`'s): every photo in the filmstrip
    /// within 300 ms, and the main thread's p99 under 8.3 ms meanwhile. The collection, its sets and a smart
    /// collection are written into the copy's index and definitions; no photo or sidecar of the fixture is touched.
    /// Skipped where the fixture or its index isn't.
    enum LibrarySourcesPerformanceScenarios {
        static let all: [Scenario] = [sources]

        static let sources = Scenario(
            "performance.library-sources",
            "The Library and Collections panels counting lib-1m while counts change, and a collection and Rejected shown",
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
            try app.expect(summary.p99 < 8.3, "The main thread's p99 was \(summary.p99) ms while the counts changed")
            for (name, milliseconds, summary) in shown {
                try app.expect(milliseconds < 300, "\(name)'s photos took \(milliseconds) ms")
                try app.expect((summary?.p99 ?? 0) < 8.3, "\(name)'s main thread p99 was \(summary?.p99 ?? 0) ms")
            }
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
            service?.close()
            window = nil
            editor = nil
            library = nil
            service = nil
        }
    }
#endif
