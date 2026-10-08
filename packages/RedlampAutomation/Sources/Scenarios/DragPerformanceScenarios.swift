#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampDocument
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import Synchronization

    /// Library's drags and the painter at the grid's budgets (LIB-21, LIB-23, LIB-26), on a copy of lib-20k's 2007
    /// folder, or of the folder `REDLAMP_DRAG_FIXTURE` names, such as all of lib-20k: every photo shown selected and
    /// dragged until a folder of Folders is outlined under it, then let go over the grid; 1,000 of them dropped on that
    /// folder, the move's progress in the grid's toolbar, and taken back; and a stroke of the painter across 50 of
    /// them, and its Undo. The main thread is watched through each, against 8.3 ms at p99. The copy is the scenario's
    /// own, a clone beside the fixture on its volume, removed afterwards; nothing of the fixture's is touched.
    enum DragPerformanceScenarios {
        static let all: [Scenario] = [drags]

        static let fixture = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["REDLAMP_DRAG_FIXTURE"]
                ?? "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-20k/2007",
            isDirectory: true,
        )

        static let drags = Scenario(
            "performance.library-drags",
            "Every photo of a copy of lib-20k's 2007 folder (or of REDLAMP_DRAG_FIXTURE) dragged until a folder is "
                + "outlined, 1,000 of them dropped on it with the move's progress, and the painter across 50 of them",
            tiers: [.performance], claims: [],
        ) { app in
            guard FileManager.default.fileExists(atPath: fixture.path) else {
                throw ScenarioSkip("\(fixture.path) isn't on this Mac")
            }
            var started = Date()
            let scratch = try DragBudgetScratch(cloning: fixture)
            defer { scratch.remove(app) }
            app.record("e2e-drag-clone-seconds", Date().timeIntervalSince(started))
            started = Date()
            let count = try scratch.show(app)
            app.record("e2e-drag-indexed-seconds", Date().timeIntervalSince(started))
            try app.simulateLibraryDrags(true)
            defer { try? app.simulateLibraryDrags(false) }
            var lines =
                ["\(fixture.lastPathComponent): \(count) photos shown, load average \(DragBudgetScratch.load())"]
            func note(_ name: String, _ phase: (summary: MainThreadMonitor.Summary?, seconds: Double)) {
                if let summary = phase.summary {
                    app.record("e2e-drag-\(name)-p99", summary.p99)
                    app.record("e2e-drag-\(name)-max", summary.max)
                }
                app.record("e2e-drag-\(name)-seconds", phase.seconds)
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
                defer { profile?.write(to: app.runDirectory.appending(path: "drag-profile-\(name).txt")) }
                return try app.watchingMainThread(name, body)
            }

            // REDLAMP_DRAG_PHASES picks some of them: start, drop, paint.
            let phases = Set(
                (ProcessInfo.processInfo.environment["REDLAMP_DRAG_PHASES"] ?? "start,drop,paint").split(separator: ",")
                    .map(String.init),
            )
            let names = try app.main { model in model.items.prefix(200).map(\.name) }
            let first = try app.frame(of: .identifier("grid.\(names[0])"))
            let moved = try app.frame(of: .identifier("folders." + scratch.moved.path))
            let moves = try app.main { $0.fileUndoCount }
            let start = NSPoint(x: first.midX, y: first.midY)
            let over = NSPoint(x: moved.midX, y: moved.midY)

            // Every photo dragged until Moved is outlined under the drag, then let go over the grid.
            if phases.contains("start") {
                try app.main { $0.selectAllPhotos() }
                try app.wait("every photo selected", timeout: 30) { $0.photoSelection.count == count }
                try app.wait("the panels following the selection", timeout: 60) { model in
                    model.libraryPanels.selection.count == count
                }
                app.pause(1)
                let outlined = try app.main { _ in LibraryDrags.outlined }
                let dragging = try watched("start") {
                    try app.libraryDragPress(along: DragBudgetScratch.path([start, over, start], step: 24))
                }
                try app.expect(
                    try app.main { _ in LibraryDrags.outlined } > outlined,
                    "Moved wasn't outlined under the drag",
                )
                try app.expect(try app.main { $0.fileUndoCount } == moves, "Letting go over the grid moved photos")
                note("start", dragging)
            }

            // 1,000 photos dropped on Moved, the move's progress in the toolbar, and the move taken back.
            if phases.contains("drop") {
                try app.main { model in
                    model.select(model.items[0].url)
                    model.click(model.items[999].url, extending: true)
                }
                try app.wait("1,000 photos selected") { $0.photoSelection.count == 1000 }
                app.pause(1)
                let progress = Flag()
                let dropping = try watched("drop") {
                    try app.libraryDragPress(along: DragBudgetScratch.path([start, over], step: 24))
                    // The model's, not the toolbar's view: looking for a view goes through the grid's cells.
                    try app.wait("the move", timeout: 1200) { model in
                        if model.moveProgress.title != nil {
                            progress.set()
                        }
                        return model.fileUndoCount > moves && !model.isModalDialogOpen
                    }
                }
                try app.expect(progress.isSet, "The move's progress didn't show")
                try app.expect(scratch.photos(in: scratch.moved) >= 1000, "Not every photo moved")
                note("drop", dropping)
                let undoing = try watched("drop-undo") {
                    try app.press(.undo)
                    try app.run("the move's Undo", timeout: 1200) { await $0.filesMade() }
                }
                try app.expect(scratch.photos(in: scratch.moved) == 0, "Not every photo moved back")
                note("drop-undo", undoing)
            }

            // A stroke of the painter across 50 photos, and its Undo.
            if phases.contains("paint") {
                let keyword = "Budget-\(UUID().uuidString.prefix(6))"
                guard let path = KeywordPath(keyword) else { throw ScenarioFailure("No keyword path") }
                try app.main { model in
                    model.select(model.items[0].url)
                    model.setThumbnailSize(GridSize.range.lowerBound)
                    model.keywordPainter.text = keyword
                    model.keywordPainter.setOn(true)
                }
                defer {
                    try? app.run("the painter put away and its keyword deleted", timeout: 300) { model in
                        model.keywordPainter.setOn(false)
                        model.keywordPainter.text = ""
                        model.setThumbnailSize(GridSize.standard)
                        model.libraryPanels.delete(path)
                        await model.libraryPanels.written()
                    }
                }
                app.pause(1)
                // The cells on screen wherever the grid is scrolled to: an Undo brings back the photos it moved
                // selected.
                let cells = try app.main { _ -> [NSRect] in
                    guard let window = Views.editorWindow, let root = window.contentView?.superview,
                          let grid = Views.all(NSView.self, in: root).first(where: {
                              $0.accessibilityIdentifier() == "library.grid" && !$0.isHiddenOrHasHiddenAncestor
                          })
                    else { return [] }
                    let visible = grid.convert(grid.visibleRect, to: nil)
                    return (grid.accessibilityChildren() ?? []).compactMap { child -> NSRect? in
                        guard let element = child as? NSAccessibilityElement, element.accessibilityRole() == .button
                        else { return nil }
                        let frame = window.convertFromScreen(element.accessibilityFrame())
                        return visible.contains(frame) ? frame : nil
                    }
                }
                let corners = DragBudgetScratch.snake(cells, reaching: 50)
                let changes = try app.main { $0.libraryPanels.undoCount }
                let painting = try watched("paint") {
                    try app.libraryDragPress(along: DragBudgetScratch.path(corners, step: 16))
                    do {
                        try app.wait("the stroke's change", timeout: 120) { $0.libraryPanels.undoCount > changes }
                    } catch {
                        let state = try app.main { model in
                            "painter out \(model.keywordPainter.isOn), its last stroke \(model.keywordPainter.lastStroke) "
                                + "photos, \(cells.count) cells, \(corners.count) corners, keywords "
                                + "\(model.keywordPainter.keywords.map(\.text)), dialog \(model.isModalDialogOpen)"
                        }
                        throw ScenarioFailure("\(error) (\(state))")
                    }
                    try app.run("the stroke's batch", timeout: 300) { await $0.libraryPanels.written() }
                }
                try app.run("the keyword list", timeout: 120) { await $0.libraryPanels.keywordsRead() }
                let painted = try app.main { model in model.libraryPanels.keywordList?[path]?.count ?? 0 }
                try app.expect(painted >= 50, "The stroke painted \(painted) photos")
                note("paint", painting)
                lines.append("the stroke painted \(painted) photos")
                let unpainting = try watched("paint-undo") {
                    try app.press(.undo)
                    try app.run("the stroke's Undo", timeout: 300) { await $0.libraryPanels.written() }
                }
                note("paint-undo", unpainting)
            }
            try? (lines.joined(separator: "\n") + "\n").write(
                to: app.runDirectory.appending(path: "drag-performance.txt"), atomically: true, encoding: .utf8,
            )
        }
    }

    /// A clone of the fixture in the scratch folder on its volume, never in the fixtures' own folder, and Moved, an
    /// empty folder beside the clone, both added to
    /// Folders; taken out of Folders and removed afterwards.
    struct DragBudgetScratch: Sendable {
        let base: URL
        let copy: URL
        let moved: URL

        init(cloning fixture: URL) throws {
            base = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
                .appending(path: "drag-budgets-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            copy = base.appending(path: fixture.lastPathComponent, directoryHint: .isDirectory)
            moved = base.appending(path: "Moved", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
            guard clonefile(fixture.path, copy.path, 0) == 0 else {
                throw ScenarioFailure("\(fixture.path) wasn't cloned: \(String(cString: strerror(errno)))")
            }
        }

        /// Adds both folders to Folders and shows the copy's photos, its subfolders' included, from the library, once
        /// it has indexed them; how many there are.
        func show(_ app: RunningApp) throws -> Int {
            let service = try app.main { $0.library.service }
            guard let service else { throw ScenarioSkip("the library is off") }
            let (copy, moved) = (copy, moved)
            try app.main { model in
                model.open([copy, moved])
                if !model.library.includesSubfolders {
                    model.setIncludesSubfolders(true)
                }
                model.showLibrary(.grid)
                model.rightPanelVisible = true
            }
            let indexed = Flag()
            try app.run("the library to index the copy", timeout: 3000) { _ in
                for _ in 0 ..< 30000 where await !service.canShow(copy, includingSubfolders: true) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if await service.canShow(copy, includingSubfolders: true) {
                    indexed.set()
                }
            }
            try app.expect(indexed.isSet, "the library didn't index \(copy.path)")
            try app.main { $0.showFolder(copy) }
            var count = -1
            for _ in 0 ..< 600 {
                let now = try app.main { model in
                    model.folder == copy && model.library.isShownFromLibrary && !model.library.isListing
                        ? model.items.count : -1
                }
                if now > 0, now == count {
                    break
                }
                count = now
                app.pause(2)
            }
            try app.expect(count > 0, "The copy's photos weren't shown")
            try app.settleLibrary()
            return count
        }

        /// The photos in `folder`, without their sidecars.
        func photos(in folder: URL) -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count { name in
                !["redlamp", "xmp", ""].contains((name as NSString).pathExtension.lowercased())
            }
        }

        func remove(_ app: RunningApp) {
            let (copy, moved) = (copy, moved)
            try? app.main { model in
                for url in [copy, moved] {
                    if let root = model.library.root(containing: url) {
                        model.library.remove(root)
                    }
                }
            }
            try? FileManager.default.removeItem(at: base)
            try? app.openWorking()
        }

        /// Points `step` apart along the lines through `corners`, the corners included.
        static func path(_ corners: [NSPoint], step: CGFloat) -> [NSPoint] {
            guard var last = corners.first else { return [] }
            var points = [last]
            for corner in corners.dropFirst() {
                let steps = max(Int(hypot(corner.x - last.x, corner.y - last.y) / step), 1)
                for index in 1 ... steps {
                    let t = CGFloat(index) / CGFloat(steps)
                    points.append(NSPoint(x: last.x + (corner.x - last.x) * t, y: last.y + (corner.y - last.y) * t))
                }
                last = corner
            }
            return points
        }

        /// The middles of `cells`' rows' first and last cells, row by row, each row the other way from the one above,
        /// as many rows as reach `count` cells.
        static func snake(_ cells: [NSRect], reaching count: Int) -> [NSPoint] {
            let rows = Dictionary(grouping: cells) { ($0.midY * 2).rounded() }.sorted { $0.key > $1.key }.map(\.value)
            var corners: [NSPoint] = []
            var reached = 0
            for (index, row) in rows.enumerated() where reached < count {
                let sorted = row.sorted { $0.midX < $1.midX }
                guard let left = sorted.first, let right = sorted.last else { continue }
                let ends = [NSPoint(x: left.midX, y: left.midY), NSPoint(x: right.midX, y: right.midY)]
                corners += index.isMultiple(of: 2) ? ends : ends.reversed()
                reached += row.count
            }
            return corners
        }

        /// The one-minute load average.
        static func load() -> String {
            var loads = [Double](repeating: 0, count: 3)
            return getloadavg(&loads, 3) > 0 ? String(format: "%.0f", loads[0]) : "unknown"
        }
    }

    /// The view a press went to straight, for its drags and release; only touched on main.
    private final class DragPressBox: @unchecked Sendable {
        var view: NSView?
    }

    /// With `REDLAMP_DRAG_PROFILE` set, the main thread's stacks sampled every millisecond while a phase runs, and the
    /// functions it was busy in, by the samples they're on, written beside the run's report: `sample` and Instruments
    /// can't attach from where the suite runs.
    final class DragPhaseProfile: @unchecked Sendable {
        private let thread: thread_act_t
        private let running = Mutex(true)
        private let samples = Mutex<[[UInt]]>([])

        static var isOn: Bool {
            ProcessInfo.processInfo.environment["REDLAMP_DRAG_PROFILE"] != nil
        }

        init(thread: thread_act_t) {
            self.thread = thread
            Thread { [self] in
                while running.withLock({ $0 }) {
                    let stack = sample()
                    if !stack.isEmpty {
                        samples.withLock { $0.append(stack) }
                    }
                    usleep(1000)
                }
            }.start()
        }

        /// Stops sampling and writes the busy samples' functions, the most often on a stack first, to `url`.
        func write(to url: URL) {
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
            var inclusive: [String: Int] = [:]
            var busy = 0
            for stack in samples.withLock({ $0 }) {
                let symbols = stack.map(name)
                // Waiting in the run loop for the next event isn't work.
                if symbols.prefix(4).contains(where: { $0.contains("mach_msg") }) {
                    continue
                }
                busy += 1
                for symbol in Set(symbols) {
                    inclusive[symbol, default: 0] += 1
                }
            }
            let lines = ["\(busy) busy samples of \(samples.withLock { $0.count })"] + inclusive
                .sorted { $0.value > $1.value }.prefix(80).map { "\($0.value)\t\($0.key)" }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        private func sample() -> [UInt] {
            var state = arm_thread_state64_t()
            var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
            var addresses: [UInt] = []
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
                while fp != 0, fp & 7 == 0, addresses.count < 96, let frame = UnsafePointer<UInt>(bitPattern: fp) {
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

    extension RunningApp {
        /// Presses at the first of `points`, drags through the others and lets go at the last, through the window as
        /// the mouse does, a drag event every 16 ms; in a window that isn't key, the events go to the view pressed, as
        /// the click after activation would.
        func libraryDragPress(along points: [NSPoint], modifiers: NSEvent.ModifierFlags = []) throws {
            guard let first = points.first, let last = points.last else { return }
            let pressed = DragPressBox()
            let events = [(NSEvent.EventType.leftMouseDown, first)] + points.dropFirst().map { (.leftMouseDragged, $0) }
                + [(.leftMouseUp, last)]
            for (type, location) in events {
                post { _ in
                    guard let window = Views.editorWindow, let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    ) else { return }
                    if type == .leftMouseDown {
                        let hit = window.contentView?.superview?.hitTest(location)
                        pressed.view = window.isKeyWindow || hit?.acceptsFirstMouse(for: event) == true ? nil : hit
                    }
                    guard let view = pressed.view else {
                        window.sendEvent(event)
                        return
                    }
                    switch type {
                    case .leftMouseDown: view.mouseDown(with: event)
                    case .leftMouseDragged: view.mouseDragged(with: event)
                    default: view.mouseUp(with: event)
                    }
                }
                pause(type == .leftMouseDragged ? 0.016 : 0.03)
            }
            pause(0.05)
        }

        /// Waits for the library to settle after a change: its lists hold every change, and its counts are in.
        func settleLibrary() throws {
            try run("the library to settle", timeout: 120) { model in
                await model.library.service?.settled()
                model.librarySources.recount()
                await model.librarySources.counted()
            }
            pause(1)
        }
    }
#endif
