#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampDocument
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    enum PanelPerformanceScenarios {
        static let all: [Scenario] = [panels]

        /// The Library panels' budgets (LIB-21, LIB-22) on a clone of lib-20k of the scenario's own: following a
        /// selection change on its 2007 folder and with 10,000 photos selected, within 16 ms; and the main
        /// thread's turns while a keyword and a preset reach 1,000 photos, under 8.3 ms at p99. Skipped where the
        /// fixture isn't.
        static let panels = Scenario(
            "performance.library-panels",
            "The Library panels following the selection on lib-20k's 2007 folder and with 10,000 photos selected, and "
                + "the main thread while a keyword and a preset reach 1,000 photos",
            tiers: [.performance], claims: [],
        ) { app in
            let fixture = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-20k", isDirectory: true)
            guard FileManager.default.fileExists(atPath: fixture.appending(path: "2007").path) else {
                throw ScenarioSkip("lib-20k isn't on this Mac")
            }
            // A clone of the scenario's own, beside the fixture on its volume, kept between runs (cloning 24,000
            // files takes a minute and a half): the batches write its sidecars, and their Undos put them back.
            let root = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/panels-perf/lib-20k", isDirectory: true)
            if !FileManager.default.fileExists(atPath: root.appending(path: "2007").path) {
                app.recorder.write("note", ["step": "cloning lib-20k"])
                try FileManager.default.createDirectory(
                    at: root.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                let clone = Process()
                clone.executableURL = URL(fileURLWithPath: "/bin/cp")
                clone.arguments = ["-cR", fixture.path, root.path]
                try clone.run()
                while clone.isRunning {
                    app.pause(10)
                    app.recorder.write("note", ["step": "cloning lib-20k"])
                }
                try app.expect(clone.terminationStatus == 0, "lib-20k cloned")
            }
            let folder2007 = root.appending(path: "2007", directoryHint: .isDirectory)
            // The scenario's own library, its index kept beside the clone between runs, and an editor of its own on
            // the app's main thread, as the folder-counts measurement has.
            let paths = LibraryPaths(root: root.deletingLastPathComponent().appending(
                path: "Library",
                directoryHint: .isDirectory,
            ))
            let box = PanelsBox()
            defer { try? app.main { _ in box.close() } }
            try app.main { model in
                let library = FolderLibrary()
                library.add([root])
                let service = LibraryService(paths: paths, sidecars: library.sidecars) { _, _ in nil }
                library.attach(service)
                let editor = EditorModel(engine: model.makeWorkerEngine?() ?? model.engine, library: library)
                box.open(library: library, service: service, editor: editor)
            }
            /// Until `condition`, noting how long it's taken every 10 s, as indexing 20,000 photos does.
            func waitNoting(
                _ what: String,
                timeout: Double,
                _ condition: @escaping @MainActor () async -> Bool,
            ) throws {
                let started = Date()
                var noted = started
                while true {
                    let met = Flag()
                    try app.run(what, timeout: 30) { _ in
                        if await condition() {
                            met.set()
                        }
                    }
                    if met.isSet {
                        return
                    }
                    app.pause(0.2)
                    let seconds = Date().timeIntervalSince(started)
                    if seconds > timeout {
                        throw ScenarioFailure("Timed out after \(Int(timeout)) s waiting for \(what)")
                    }
                    if Date().timeIntervalSince(noted) > 10 {
                        noted = Date()
                        app.recorder.write("note", ["step": "\(what), \(Int(seconds)) s"])
                    }
                }
            }
            try waitNoting("lib-20k indexed", timeout: 1200) {
                await box.service?.canShow(root, includingSubfolders: true) == true
            }
            try app.main { _ in
                box.editor?.showModule(.library)
                box.editor?.showFolder(folder2007)
            }
            try waitNoting("its 2007 folder shown from the library", timeout: 120) {
                guard let editor = box.editor else { return false }
                return editor.folder == folder2007 && editor.library.isShownFromLibrary && editor.items.count > 1000
            }
            try app.main { _ in
                guard let editor = box.editor else { return }
                editor.libraryPanels.follow()
                editor.select(editor.items[0].url)
            }
            try app.wait("the keyword list", timeout: 60) { _ in box.editor?.libraryPanels.keywordList != nil }
            let count2007 = try app.main { _ in box.editor?.items.count ?? 0 }

            /// Each selection change's time to reach the panels, `changes` of them made by `change`.
            func following(
                _ what: String,
                _ changes: Int,
                change: @escaping @MainActor (EditorModel, Int) -> Void,
            ) throws
                -> [Double] {
                var times: [Double] = []
                for step in 0 ..< changes {
                    try app.run("the panels' changes") { _ in await box.editor?.libraryPanels.refreshed() }
                    let before = try app.main { _ in box.editor?.libraryPanels.followed.count ?? 0 }
                    try app.main { _ in
                        if let editor = box.editor {
                            change(editor, step)
                        }
                    }
                    try app.wait("\(what) \(step) in the panels", timeout: 60) { _ in
                        guard let editor = box.editor else { return false }
                        let selected = editor.photoSelection.isEmpty ? 1 : editor.photoSelection.count
                        return editor.libraryPanels.followed.count > before && editor.libraryPanels.selection
                            .count == selected
                    }
                    try times.append(app.main { _ in
                        box.editor?.libraryPanels.followed.last.map {
                            Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15
                        } ?? .infinity
                    })
                }
                return times
            }

            // The 2007 folder: every photo selected, then one.
            let all2007 = try following("selecting the 2007 folder", 12) { editor, step in
                if step.isMultiple(of: 2) {
                    editor.selectAllPhotos()
                } else {
                    editor.select(editor.items[step % 7 + 1].url)
                }
            }

            // 10,000 photos selected in the whole library, each change one more.
            try app.main { _ in
                guard let editor = box.editor else { return }
                if !editor.library.includesSubfolders {
                    _ = editor.perform(.showPhotosInSubfolders)
                }
                editor.showFolder(root)
            }
            try waitNoting("lib-20k shown from the library", timeout: 300) {
                guard let editor = box.editor else { return false }
                return editor.folder == root && editor.library.isShownFromLibrary && editor.items.count >= 10013
            }
            try app.main { _ in
                guard let editor = box.editor else { return }
                editor.select(editor.items[0].url)
                editor.click(editor.items[9999].url, extending: true)
            }
            try app.wait("10,000 selected, in the panels", timeout: 120) { _ in
                box.editor?.libraryPanels.selection.ids.count == 10000
            }
            let tenThousand = try following("10,000 photos selected", 12) { editor, step in
                editor.click(editor.items[10000 + step].url, extending: true)
            }

            // 1,000 photos given a keyword, then a preset, the main thread watched.
            try app.main { _ in
                guard let editor = box.editor else { return }
                editor.select(editor.items[0].url)
                editor.click(editor.items[999].url, extending: true)
            }
            try app.wait("1,000 selected, in the panels", timeout: 60) { _ in
                box.editor?.libraryPanels.selection.ids.count == 1000
            }
            func written() throws {
                try app.run("the panels' changes to be made", timeout: 120) { _ in
                    guard let editor = box.editor else { return }
                    await editor.libraryPanels.written()
                    await editor.library.service?.settled()
                    await editor.libraryPanels.refreshed()
                }
            }
            try written()
            func watched(_ what: String, _ change: @escaping @MainActor (LibraryPanels) -> Void) throws
                -> (summary: MainThreadMonitor.Summary?, seconds: Double, progressed: Bool) {
                let monitor = try MainThread.run { () -> MainThreadMonitorBox in
                    let monitor = MainThreadMonitor()
                    monitor.start()
                    return MainThreadMonitorBox(monitor)
                }
                let started = Date()
                try app.main { _ in
                    if let panels = box.editor?.libraryPanels {
                        change(panels)
                    }
                }
                var progressed = false
                while try app.main({ _ in box.editor?.libraryPanels.progress != nil })
                    || Date().timeIntervalSince(started) < 0.2 {
                    if try app.main({ _ in (box.editor?.libraryPanels.progress?.done ?? 0) > 0 }) {
                        progressed = true
                    }
                    app.pause(0.02)
                    if Date().timeIntervalSince(started) > 120 {
                        throw ScenarioFailure("\(what) took over 120 s")
                    }
                }
                try written()
                let seconds = Date().timeIntervalSince(started)
                let summary = try MainThread.run { () -> MainThreadMonitor.Summary? in
                    monitor.monitor.stop()
                    return monitor.monitor.summary(seconds: seconds)
                }
                return (summary, seconds, progressed)
            }
            let keyword = try watched("a keyword on 1,000 photos") { _ = $0.add([KeywordPath("E2E Perf/Keyword")!]) }
            try app.expect(try app.main { _ in
                box.editor?.libraryPanels.selection.hasEverywhere(KeywordPath("E2E Perf/Keyword")!) == true
            }, "the keyword on the 1,000")
            try app.run("the preset kept") { _ in
                _ = await box.editor?.libraryPanels.save(MetadataPreset(name: "E2E Perf", fields: [
                    .caption: MetadataPreset.Entry("E2E perf", mode: .append), .city: MetadataPreset.Entry("Lisbon"),
                ]))
            }
            try app
                .wait("the preset") { _ in
                    box.editor?.libraryPanels.presets.contains { $0.name == "E2E Perf" } == true
                }
            let preset = try watched("a preset on 1,000 photos") { panels in
                if let preset = panels.presets.first(where: { $0.name == "E2E Perf" }) {
                    _ = panels.apply(preset)
                }
            }
            try app.expect(
                try app.main { _ in box.editor?.libraryPanels.selection.fields[.city] } == .same("Lisbon"),
                "the preset applied",
            )
            try app.run("the preset removed") { _ in
                _ = await box.editor?.libraryPanels.deletePreset(named: "E2E Perf")
            }
            // The clone as it was, for the next run.
            for _ in 0 ..< 2 {
                try app.main { _ in _ = box.editor?.libraryPanels.undoInLibrary() }
                try written()
            }

            /// The first change, which reads the folders' IDs and the engine's keywords for the first time, then the
            /// others' median and slowest.
            func describe(_ times: [Double]) -> String {
                let sorted = times.dropFirst().sorted()
                return String(
                    format: "first %.1f ms, then median %.1f ms, max %.1f ms", times.first ?? .infinity,
                    sorted[sorted.count / 2], sorted.last ?? .infinity,
                )
            }
            func describe(_ watched: (summary: MainThreadMonitor.Summary?, seconds: Double, progressed: Bool))
                -> String {
                guard let summary = watched.summary else { return "no turns" }
                return String(
                    format: "%.1f s, main thread p50 %.2f ms, p99 %.2f ms, max %.1f ms%@",
                    watched.seconds,
                    summary.p50,
                    summary.p99,
                    summary.max,
                    watched.progressed ? ", with progress" : "",
                )
            }
            app.recorder.write("note", [
                "library-panels": "2007 folder (\(count2007) photos): \(describe(all2007)); 10,000 selected: "
                    + "\(describe(tenThousand)); a keyword on 1,000: \(describe(keyword)); a preset on 1,000: "
                    + "\(describe(preset)); load \(ProcessInfo.processInfo.loadAverage)",
            ])
            try app.expect(
                (all2007.dropFirst().max() ?? .infinity) < 16,
                "The 2007 folder's selection reached the panels in \(describe(all2007))",
            )
            try app.expect(
                (tenThousand.dropFirst().max() ?? .infinity) < 16,
                "10,000 photos' selection reached the panels in \(describe(tenThousand))",
            )
            try app.expect((keyword.summary?.p99 ?? .infinity) < 8.3, "A keyword on 1,000 photos: \(describe(keyword))")
            try app.expect((preset.summary?.p99 ?? .infinity) < 8.3, "A preset on 1,000 photos: \(describe(preset))")
            try app.expect(keyword.progressed && preset.progressed, "Both showed their progress")
        }
    }

    /// The performance scenario's own library and editor, kept on the main thread.
    @MainActor
    private final class PanelsBox: @unchecked Sendable {
        private(set) var library: FolderLibrary?
        private(set) var service: LibraryService?
        private(set) var editor: EditorModel?

        func open(library: FolderLibrary, service: LibraryService, editor: EditorModel) {
            self.library = library
            self.service = service
            self.editor = editor
        }

        func close() {
            service?.close()
            editor = nil
            library = nil
            service = nil
        }
    }

    extension ProcessInfo {
        /// The load average over the last minute.
        var loadAverage: String {
            var loads = [Double](repeating: 0, count: 3)
            return getloadavg(&loads, 3) > 0 ? String(format: "%.0f", loads[0]) : "?"
        }
    }
#endif
