#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampDesign
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import Synchronization

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
            let mainThread = try app.main { _ in mach_thread_self() }
            func watched(
                _ name: String, _ body: () throws -> Void,
            ) throws -> (summary: MainThreadMonitor.Summary?, seconds: Double) {
                let profile = DragPhaseProfile.isOn ? DragPhaseProfile(thread: mainThread) : nil
                defer { profile?.write(to: app.runDirectory.appending(path: "stack-profile-\(name).txt")) }
                return try app.watchingMainThread(name, body)
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

            // Each stack opened and closed by itself, each in a turn of its own, as S and a click on its count do: the
            // call and the views following its diff, timed on the main thread.
            let tops = try app.main { model -> [Int64] in
                guard let list = model.gridStacks.list else { return [] }
                return Array(list.lazy.filter { list.badges(of: $0).stack?.isOpen == false }.prefix(wanted))
            }
            try app.expect(!tops.isEmpty, "No stack to open")
            var (opening, closing) = ([Double](), [Double]())
            let within = ProcessInfo.processInfo.environment["REDLAMP_STACK_PROFILE"] != nil
                ? StackCallProfile(thread: mainThread) : nil
            let toggling = try watched("toggle") {
                for top in tops {
                    try opening.append(app.main { model in Self.timed { model.gridStacks.toggle(top) } })
                    app.pause(0.03)
                    try closing.append(app.main { model in Self.timed { model.gridStacks.toggle(top) } })
                    app.pause(0.03)
                }
            }
            within?.write(
                to: app.runDirectory.appending(path: "stack-profile-within-toggle.txt"),
                inside: "LibraryStacks",
            )
            describe("open-one", opening)
            describe("close-one", closing)
            note("toggle", toggling)

            // The same beside a stack held open.
            if tops.count > 1 {
                try app.main { $0.gridStacks.toggle(tops[0]) }
                app.pause(0.5)
                let besideProfile = within.map { _ in StackCallProfile(thread: mainThread) }
                let besideOpen = try watched("toggle-beside-open") {
                    for top in tops.dropFirst().prefix(20) {
                        try app.main { $0.gridStacks.toggle(top) }
                        app.pause(0.03)
                        try app.main { $0.gridStacks.toggle(top) }
                        app.pause(0.03)
                    }
                }
                besideProfile?.write(
                    to: app.runDirectory.appending(path: "stack-profile-within-toggle-beside-open.txt"),
                    inside: "LibraryStacks",
                )
                try app.main { $0.gridStacks.toggle(tops[0]) }
                app.pause(0.5)
                note("toggle-beside-open", besideOpen)
            }

            // The same with the filmstrip out of sight, for the grid's part.
            try app.main { $0.filmstripVisible = false }
            app.pause(1)
            var (gridOpening, gridClosing) = ([Double](), [Double]())
            for top in tops.prefix(20) {
                try gridOpening.append(app.main { model in Self.timed { model.gridStacks.toggle(top) } })
                app.pause(0.03)
                try gridClosing.append(app.main { model in Self.timed { model.gridStacks.toggle(top) } })
                app.pause(0.03)
            }
            try app.main { $0.filmstripVisible = true }
            app.pause(1)
            describe("open-one-grid-only", gridOpening)
            describe("close-one-grid-only", gridClosing)

            // Every stack at once.
            var (openingAll, closingAll) = ([Double](), [Double]())
            let all = try watched("all") {
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
            let scrolling = try watched("scroll") {
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

            // → held in the grid, from cell to cell past the closed stacks' photos, and with every stack open for
            // the cost of the stacks themselves.
            for (name, open) in [("arrows", false), ("arrows-open", true)] {
                try app.main { model in
                    open ? model.gridStacks.openAll() : model.gridStacks.closeAll()
                    if let first = model.gridStacks.list?.first, let url = model.library.url(ofPhoto: first) {
                        model.select(url)
                    }
                }
                try app.press(.gridView)
                try app.wait("the grid to take the keyboard") { _ in
                    Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
                }
                app.pause(1)
                let walking = try watched(name) {
                    let right = UnicodeScalar(NSRightArrowFunctionKey).map(String.init) ?? ""
                    for _ in 0 ..< 200 {
                        try app.pressGridKey(kVK_RightArrow, characters: right)
                        app.pause(1.0 / 30)
                    }
                }
                note(name, walking)
            }
            try app.main { $0.gridStacks.closeAll() }
            try? (lines.joined(separator: "\n") + "\n").write(
                to: app.runDirectory.appending(path: "stack-performance.txt"), atomically: true, encoding: .utf8,
            )
        }

        /// With `REDLAMP_STACK_PROFILE` set, the main thread's stacks sampled every half millisecond while stacks open
        /// and close, and what the calls named by a frame were busy in: the functions under it on the stack, by the
        /// samples they're on, and the innermost of them alone; then every busy sample's functions, as
        /// `DragPhaseProfile` counts them.
        final class StackCallProfile: @unchecked Sendable {
            private let thread: thread_act_t
            private let running = Mutex(true)
            private let samples = Mutex<[[UInt]]>([])

            init(thread: thread_act_t) {
                self.thread = thread
                Thread { [self] in
                    while running.withLock({ $0 }) {
                        let stack = sample()
                        if !stack.isEmpty {
                            samples.withLock { $0.append(stack) }
                        }
                        usleep(500)
                    }
                }.start()
            }

            /// Stops sampling and writes, for the samples with a frame whose name holds `marker`, the functions called
            /// under it, the most often on a stack first, and the innermost ones, to `url`.
            func write(to url: URL, inside marker: String) {
                running.withLock { $0 = false }
                var names: [UInt: String] = [:]
                func name(_ address: UInt) -> String {
                    if let known = names[address] {
                        return known
                    }
                    var info = Dl_info()
                    let found = dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 ? info.dli_sname
                        .map { String(cString: $0) } : nil
                    names[address] = found ?? String(format: "0x%lx", address)
                    return names[address] ?? ""
                }
                var (inclusive, innermost, everywhere) = ([String: Int](), [String: Int](), [String: Int]())
                var (inside, busy) = (0, 0)
                let all = samples.withLock { $0 }
                for stack in all {
                    let symbols = stack.map(name)
                    // Waiting in the run loop for the next event isn't work.
                    if !symbols.prefix(4).contains(where: { $0.contains("mach_msg") }) {
                        busy += 1
                        for symbol in Set(symbols) {
                            everywhere[symbol, default: 0] += 1
                        }
                    }
                    guard let at = symbols.firstIndex(where: { $0.contains(marker) }) else { continue }
                    inside += 1
                    for symbol in Set(symbols[..<at]) {
                        inclusive[symbol, default: 0] += 1
                    }
                    if let leaf = symbols.first {
                        innermost[leaf, default: 0] += 1
                    }
                }
                func ranked(_ counts: [String: Int], _ count: Int) -> [String] {
                    counts.sorted { $0.value > $1.value }.prefix(count).map { "\($0.value)\t\($0.key)" }
                }
                let lines = ["\(inside) samples inside \(marker)", "", "Under it, by samples:"] + ranked(inclusive, 150)
                    + ["", "Innermost:"] + ranked(innermost, 60)
                    + ["", "\(busy) busy samples of \(all.count), by the functions on them:"] + ranked(everywhere, 150)
                try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            }

            private func sample() -> [UInt] {
                var state = arm_thread_state64_t()
                var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
                var addresses: [UInt] = []
                // Nothing may allocate while the thread is suspended: it may hold the allocator's lock.
                addresses.reserveCapacity(130)
                guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
                let result = withUnsafeMutablePointer(to: &state) {
                    $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                        thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
                    }
                }
                if result == KERN_SUCCESS {
                    let mask: UInt = 0x0000_000F_FFFF_FFFF
                    addresses.append(UInt(state.__pc) & mask)
                    addresses.append(UInt(state.__lr) & mask)
                    var fp = UInt(state.__fp)
                    while fp != 0, fp & 7 == 0, addresses.count < 128, let frame = UnsafePointer<UInt>(bitPattern: fp) {
                        addresses.append(frame[1] & mask)
                        let next = frame[0]
                        guard next > fp else { break }
                        fp = next
                    }
                }
                thread_resume(thread)
                return addresses
            }
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
