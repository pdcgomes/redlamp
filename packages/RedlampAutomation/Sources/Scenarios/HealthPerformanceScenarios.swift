#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampDesign
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Library Health at the grid's budgets (LIB-40), on photos of the scenario's own in the external disk's scratch
    /// folder: 10,000 small JPEGs (`REDLAMP_HEALTH_GROUPS`), each its own, and a clone of each, so Exact Duplicates
    /// lists 20,000 photos in 10,000 groups, a copy of each proposed for the Trash. The grid scrolled with every cell's
    /// proposal drawn, compact at the standard, smallest and largest sizes, expanded and thumbnails only, the main
    /// thread watched against 8.3 ms at p99; then the sheet for the 10,000 proposals, timed to its plan, the batch
    /// moving them to the Trash and its Undo bringing them back, each watched too. What's left in the Trash, and the
    /// folder, are removed afterwards.
    enum HealthPerformanceScenarios {
        static let all: [Scenario] = [health]

        static let groups = Int(ProcessInfo.processInfo.environment["REDLAMP_HEALTH_GROUPS"] ?? "") ?? 10000

        static let health = Scenario(
            "performance.library-health",
            "Exact Duplicates' proposals drawn as 20,000 photos scroll, and the sheet, batch and Undo for 10,000 of "
                + "them",
            tiers: [.performance], claims: [],
        ) { app in
            let scratch = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
            guard FileManager.default.fileExists(atPath: scratch.path) else {
                throw ScenarioSkip("\(scratch.path) isn't on this Mac")
            }
            let base = scratch.appending(
                path: "health-perf-\(UUID().uuidString.prefix(8))",
                directoryHint: .isDirectory,
            )
            let service = try app.main { $0.library.service }
            guard let service else { throw ScenarioSkip("the library is off") }
            let folders = app.photos
            defer {
                try? app.run("emptying what's left in the Trash", timeout: 600) { model in
                    for place in await service.trashedPlaces() {
                        try? FileManager.default.removeItem(atPath: place)
                    }
                    if let root = model.library.root(containing: base) {
                        model.library.remove(root)
                    }
                    model.showFolder(folders)
                    model.showModule(.develop)
                }
                try? FileManager.default.removeItem(at: base)
            }
            let total = 2 * groups
            var lines = ["\(groups) groups of two copies, load average \(DragBudgetScratch.load())"]
            func note(_ name: String, _ phase: (summary: MainThreadMonitor.Summary?, seconds: Double)) {
                if let summary = phase.summary {
                    app.record("e2e-health-\(name)-p99", summary.p99)
                    app.record("e2e-health-\(name)-max", summary.max)
                }
                lines.append(String(
                    format: "%@: %.2f s, main thread p50 %.2f ms, p99 %.2f ms, max %.1f ms, %d of %d turns over 8.3 ms",
                    name, phase.seconds, phase.summary?.p50 ?? -1, phase.summary?.p99 ?? -1,
                    phase.summary?.max ?? -1, phase.summary?.overFrame ?? -1, phase.summary?.iterations ?? -1,
                ))
            }
            defer {
                try? (lines.joined(separator: "\n") + "\n").write(
                    to: app.runDirectory.appending(path: "health-performance.txt"), atomically: true, encoding: .utf8,
                )
            }

            app.recorder.write("note", ["step": "writing \(total) photos"])
            try makePhotos(in: base, groups: groups)
            try app.main { model in
                model.open([base])
                if !model.library.includesSubfolders {
                    model.setIncludesSubfolders(true)
                }
                model.showLibrary(.grid)
                model.leftPanelVisible = true
            }
            let indexed = Flag()
            try app.run("the library to index the photos", timeout: 3000) { _ in
                for _ in 0 ..< 30000 where await !service.canShow(base, includingSubfolders: true) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if await service.canShow(base, includingSubfolders: true) {
                    indexed.set()
                }
            }
            try app.expect(indexed.isSet, "the library didn't index \(base.path)")

            // The counts find the candidates unconfirmed, which are read whole in the background.
            let confirming = ContinuousClock.now
            try app.run("the duplicates confirmed", timeout: 1800) { model in
                for _ in 0 ..< 1800 {
                    await model.library.service?.settled()
                    model.librarySources.recount()
                    await model.librarySources.counted()
                    await model.healthProposals.confirmed()
                    if model.librarySources.count(of: .health(.duplicates)) ?? 0 >= total {
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            let found = try app.main { $0.librarySources.count(of: .health(.duplicates)) ?? 0 }
            try app.expect(found >= total, "Exact Duplicates lists \(found) photos, not \(total)")
            lines.append("duplicates confirmed in the background: \(Self.seconds(.now - confirming)) s")

            // Exact Duplicates shown, every photo's proposal in.
            try app.main { model in
                model.setGroupKey(.ungrouped)
                model.setCellStyle(.compact)
                model.setThumbnailSize(GridSize.standard)
                _ = model.librarySources.show(.health(.duplicates))
            }
            try app.wait("Exact Duplicates with every photo's proposal", timeout: 300) { model in
                !model.librarySources.isListing && model.items.count >= total
                    && model.healthProposals.marked >= total && !model.healthProposals.isReading
            }
            let took = try app.main { $0.healthProposals.readsTook.last.map(Self.milliseconds) ?? -1 }
            app.record("e2e-health-proposals-read", took)
            lines.append(String(format: "the proposals read, the last time: %.1f ms", took))

            // The grid scrolled from top to bottom and back, each cell drawing its proposal.
            for (name, style, size) in [
                ("scroll", GridCellStyle.compact, GridSize.standard), (
                    "scroll-smallest",
                    .compact,
                    GridSize.range.lowerBound,
                ),
                ("scroll-largest", .compact, GridSize.range.upperBound), (
                    "scroll-expanded",
                    .expanded,
                    GridSize.standard,
                ),
                ("scroll-thumbnails-only", GridCellStyle.none, GridSize.standard),
            ] {
                try app.main { model in
                    model.setCellStyle(style)
                    model.setThumbnailSize(size)
                }
                app.pause(1)
                let phase = try app.watchingMainThread(name) {
                    for step in 0 ... 240 {
                        let fraction = Double(step <= 120 ? step : 240 - step) / 120
                        try app.main { _ in
                            if let window = Views.editorWindow, let grid = LibraryGridViews.grid(in: window) {
                                LibraryGridViews.scroll(grid, to: fraction)
                            }
                        }
                        app.pause(1.0 / 120)
                    }
                }
                let drawn = try app.main { _ -> Int in
                    guard let window = Views.editorWindow,
                          let grid = LibraryGridViews.grid(in: window) else { return 0 }
                    return LibraryGridViews.proposals(in: grid).count
                }
                try app.expect(drawn > 0, "No cell drew its proposal while scrolling \(name)")
                note(name, phase)
            }
            try app.main { model in
                model.setCellStyle(.compact)
                model.setThumbnailSize(GridSize.standard)
            }

            // The sheet for the 10,000 proposals, timed to its plan.
            let sheet = try app.watchingMainThread("sheet") {
                try app.main { model in
                    model.select(model.items[0].url)
                    _ = model.perform(.acceptHealthProposals)
                }
                try app.wait("the sheet with its plan", timeout: 1200) { $0.healthSheet?.canAccept == true }
            }
            note("sheet", sheet)
            let state = try app.main { $0.healthSheet }
            let shown = state?.shownAfter.map(Self.milliseconds) ?? -1
            let planned = state?.plannedAfter.map(Self.milliseconds) ?? -1
            app.record("e2e-health-sheet-shown", shown)
            app.record("e2e-health-sheet-planned", planned)
            lines.append(String(
                format: "the sheet on screen after %.1f ms, its plan after %.0f ms: %@ (%@)", shown, planned,
                state?.heading ?? "", state?.count ?? "",
            ))
            try app.expect(
                state?.heading == "Move \(groups.formatted(.number.locale(Locale(identifier: "en_US")))) copies to the "
                    + "Trash?",
                "the sheet asks \(state?.heading ?? "nothing")",
            )

            // The batch, then its Undo.
            let batch = try app.watchingMainThread("batch") {
                try app.clickInSheet("health.accept")
                try app.waitForNoSheet("the sheet", timeout: 3600)
            }
            note("batch", batch)
            app.record("e2e-health-batch-seconds", batch.seconds)
            let left = Self.files(in: base)
            try app.expect(left == total - groups, "\(left) photos left after the batch, not \(total - groups)")
            try app.wait("the list without the copies moved", timeout: 300) { model in
                !model.librarySources.isListing && model.items.count <= total - groups
            }
            let undo = try app.watchingMainThread("undo") {
                try app.wait("the batch on Library's Undo", timeout: 30) { $0.healthUndoCount > 0 }
                try app.press(.undo)
                try app.run("the Undo", timeout: 3600) { await $0.healthChangesMade() }
            }
            note("undo", undo)
            app.record("e2e-health-undo-seconds", undo.seconds)
            try app.expect(Self.files(in: base) == total, "\(Self.files(in: base)) photos back, not \(total)")
        }

        /// `groups` small JPEGs, each its own by a comment holding its number, in folders of a thousand, and a clone
        /// of each in a folder of copies.
        static func makePhotos(in base: URL, groups: Int) throws {
            let template = try SourcesScratch.jpeg(number: 1)
            let originals = base.appending(path: "Originals", directoryHint: .isDirectory)
            let copies = base.appending(path: "Copies", directoryHint: .isDirectory)
            for part in 0 ..< (groups + 999) / 1000 {
                let (from, to) = (
                    originals.appending(path: "\(part)", directoryHint: .isDirectory),
                    copies.appending(path: "\(part)", directoryHint: .isDirectory),
                )
                try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
                for number in part * 1000 ..< min(groups, (part + 1) * 1000) {
                    let name = String(format: "IMG_%05d.jpg", number)
                    let photo = from.appending(path: name, directoryHint: .notDirectory)
                    try HealthScenarios.commented(template, "Redlamp health \(number)").write(to: photo)
                    try FileManager.default.copyItem(
                        at: photo,
                        to: to.appending(path: name, directoryHint: .notDirectory),
                    )
                }
            }
        }

        /// The photos under `base`.
        static func files(in base: URL) -> Int {
            let found = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            return (found?.allObjects as? [URL] ?? []).count { $0.pathExtension == "jpg" }
        }

        static func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }

        static func seconds(_ duration: Duration) -> String {
            String(format: "%.1f", milliseconds(duration) / 1000)
        }
    }
#endif
