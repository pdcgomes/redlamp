#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampDesign
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Stacks at the grid's budgets (LIB-28), on a copy of lib-20k's 2007 folder, or of the folder
    /// `REDLAMP_STACK_FIXTURE` (else `REDLAMP_DRAG_FIXTURE`) names, such as all of lib-20k: the stacks the library
    /// finds, and stacks of five made by hand where it finds fewer than `wanted`, each opened and closed by itself
    /// against 2 ms on the main thread, every one at once, and the grid scrolled and walked with held arrow keys
    /// while they're closed, the main thread watched through each against 8.3 ms at p99. The copy is the scenario's
    /// own, a clone beside the fixture on its volume, removed afterwards; nothing of the fixture's is touched.
    enum StackPerformanceScenarios {
        static let all: [Scenario] = [stacks]

        static let fixture = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["REDLAMP_STACK_FIXTURE"]
                ?? ProcessInfo.processInfo.environment["REDLAMP_DRAG_FIXTURE"]
                ?? "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-20k/2007",
            isDirectory: true,
        )

        /// The stacks the scenario opens and closes one at a time.
        static let wanted = 40

        static let stacks = Scenario(
            "performance.library-stacks",
            "Stacks in a copy of lib-20k's 2007 folder (or of REDLAMP_STACK_FIXTURE) opened and closed one at a time "
                + "and all at once, and the grid scrolled and walked with arrow keys while they're closed",
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
                model.setCellStyle(.compact)
                model.setThumbnailSize(GridSize.standard)
                model.gridStacks.closeAll()
            }
            var lines =
                ["\(fixture.lastPathComponent): \(count) photos shown, load average \(DragBudgetScratch.load())"]
            let found = try settledStacks(app)
            try lines
                .append(
                    "stacks found: \(found.closed) shown closed, made in \(app.main { $0.gridStacks.lastStacking })",
                )
            if found.closed < wanted {
                let made = try makeStacks(wanted - found.closed, in: app)
                lines.append("stacks of five made by hand: \(made)")
            }

            func note(_ name: String, _ phase: (summary: MainThreadMonitor.Summary?, seconds: Double)) {
                if let summary = phase.summary {
                    app.record("e2e-stacks-\(name)-p99", summary.p99)
                    app.record("e2e-stacks-\(name)-max", summary.max)
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
                app.record("e2e-stacks-\(name)-p95", p95)
                app.record("e2e-stacks-\(name)-max", sorted.last ?? 0)
                lines.append(String(
                    format: "%@, %d times: median %.3f ms, p95 %.3f ms, max %.3f ms", name, sorted.count,
                    sorted[sorted.count / 2], p95, sorted.last ?? 0,
                ))
            }

            // Each stack opened and closed by itself, as S and a click on its count do: the call and the views
            // following its diff, timed on the main thread.
            let tops = try app.main { model -> [Int64] in
                guard let list = model.gridStacks.list else { return [] }
                return Array(list.lazy.filter { list.badges(of: $0).stack?.isOpen == false }.prefix(wanted))
            }
            try app.expect(!tops.isEmpty, "No stack to open")
            var (opening, closing) = ([Double](), [Double]())
            let toggling = try app.watchingMainThread("toggle") {
                for top in tops {
                    let (opened, closed) = try app.main { model -> (Double, Double) in
                        let clock = ContinuousClock()
                        let start = clock.now
                        model.gridStacks.toggle(top)
                        let middle = clock.now
                        model.gridStacks.toggle(top)
                        let end = clock.now
                        return (Self.milliseconds(middle - start), Self.milliseconds(end - middle))
                    }
                    opening.append(opened)
                    closing.append(closed)
                    app.pause(0.02)
                }
            }
            describe("open-one", opening)
            describe("close-one", closing)
            note("toggle", toggling)

            // Every stack at once.
            var (openingAll, closingAll) = ([Double](), [Double]())
            let all = try app.watchingMainThread("all") {
                for _ in 0 ..< 5 {
                    try openingAll.append(app.main { model in
                        Self.timed { model.gridStacks.openAll() }
                    })
                    app.pause(0.1)
                    try closingAll.append(app.main { model in
                        Self.timed { model.gridStacks.closeAll() }
                    })
                    app.pause(0.1)
                }
            }
            describe("open-all", openingAll)
            describe("close-all", closingAll)
            note("all", all)

            // The grid scrolled from top to bottom and back with the stacks closed.
            let scrolling = try app.watchingMainThread("scroll") {
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
            note("scroll", scrolling)

            // → held in the grid, from cell to cell past the closed stacks' photos.
            try app.main { model in
                if let first = model.gridStacks.list?.first, let url = model.library.url(ofPhoto: first) {
                    model.select(url)
                }
            }
            try app.press(.gridView)
            try app.wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }
            let walking = try app.watchingMainThread("arrows") {
                let right = UnicodeScalar(NSRightArrowFunctionKey).map(String.init) ?? ""
                for _ in 0 ..< 200 {
                    try app.pressGridKey(kVK_RightArrow, characters: right)
                    app.pause(1.0 / 30)
                }
            }
            note("arrows", walking)
            try? (lines.joined(separator: "\n") + "\n").write(
                to: app.runDirectory.appending(path: "stack-performance.txt"), atomically: true, encoding: .utf8,
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

        /// The source's stacks once found, and the counts of them shown open and closed.
        private static func settledStacks(_ app: RunningApp) throws -> (open: Int, closed: Int) {
            var last = -1
            for _ in 0 ..< 120 {
                let (stackings, shown) = try app.main { model in
                    (model.gridStacks.stackingsMade, model.gridStacks.list?.stacksShown ?? (0, 0))
                }
                if stackings > 0, stackings == last {
                    return shown
                }
                last = stackings
                app.pause(1)
            }
            return try app.main { $0.gridStacks.list?.stacksShown ?? (0, 0) }
        }

        /// `count` stacks of five photos made by hand from the photos standing alone, spread through the list, each a
        /// change of the library's; how many were made.
        private static func makeStacks(_ count: Int, in app: RunningApp) throws -> Int {
            let groups = try app.main { model -> [[URL]] in
                let stacks = model.gridStacks.list?.stacks ?? Stacks()
                let alone = model.items.filter { item in
                    model.library.photoID(of: item.url).map {
                        stacks.stack(containing: $0) == nil && stacks.pair(containing: $0) == nil
                    } ?? false
                }.map(\.url)
                let stride = max(alone.count / max(count, 1), 5)
                return (0 ..< count).compactMap { index in
                    let start = index * stride
                    return start + 5 <= alone.count ? Array(alone[start ..< start + 5]) : nil
                }
            }
            for group in groups {
                try app.main { model in
                    model.select(group[0])
                    for url in group.dropFirst() {
                        model.click(url, toggling: true)
                    }
                    model.stackSelectedPhotos()
                }
            }
            try app.run("the stacks made", timeout: 600) { await $0.libraryPanels.written() }
            try app.wait("the stacks shown", timeout: 120) { model in
                (model.gridStacks.list?.stacks.count(of: .manual) ?? 0) >= groups.count
            }
            return groups.count
        }
    }
#endif
