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

    @MainActor
    extension DebugLibraryPerformance {
        /// The arrow keys held through the filmstrip: the main thread, the steps taken and the blank frames.
        struct HeldArrows {
            let summary: MainThreadMonitor.Summary?, report: String, steps: Int, blank: Int
        }

        /// Culling every photo at once: the main thread; each change's time until on screen and until in every
        /// sidecar; the sidecars not as they were after Undo, of `count`.
        struct Culled {
            let summary: MainThreadMonitor.Summary?, onScreen: [Double], writes: [Double], left: Int, count: Int
            let report: String
        }

        /// Group By: whether the source was grouped; the main thread and each change's time on screen, changing the
        /// key, and opening and closing every group; and the main thread holding → through the moments.
        struct Grouped {
            var grouped = false
            var changing: MainThreadMonitor.Summary?
            var onScreen: [Double] = []
            var toggling: MainThreadMonitor.Summary?
            var toggled: [Double] = []
            var arrows: MainThreadMonitor.Summary?
            var report: String
        }

        /// Selects the first photo, then the next every `interval` for `steps` steps, as a held arrow
        /// key does, with the filmstrip on screen; a frame after each step, the canvas has to show the
        /// photo (its render or its thumbnail) and the cells beside the active one their thumbnails.
        static func holdArrow(
            _ model: EditorModel, loader: ThumbnailLoader, interval: Double, steps: Int,
        ) async -> HeldArrows {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1200, height: FilmstripViews.height), styleMask: [.borderless],
                backing: .buffered, defer: false,
            )
            let strip = FilmstripViews.make(model: model)
            window.contentView = strip
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            let start = model.selection.flatMap(model.library.index(of:)).map { $0 + 1 } ?? 0
            guard model.items.indices.contains(start) else { return HeldArrows(
                summary: nil,
                report: "",
                steps: 0,
                blank: 0,
            ) }
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
            return HeldArrows(
                summary: monitor.summary(seconds: elapsed),
                report: monitor.report("Main thread holding the arrow key", seconds: elapsed),
                steps: taken, blank: blank,
            )
        }

        /// Asks for every thumbnail at once and waits until they're all in.
        static func load(_ items: [RedlampUI.LibraryItem], with loader: ThumbnailLoader) async {
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
        static func scrollGrid(
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
        static func typeInFilterBar(
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
            // Of those, until the library had listed what the key found, before the views followed; and of that,
            // the query engine finding the photos and the list made of them, off the main thread.
            var listing: [Double] = []
            var queried: [Double] = []
            var made: [Double] = []
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
                            listing.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                            if let took = filters.lastListing {
                                queried.append(seconds(took.query) * 1000)
                                made.append(seconds(took.list) * 1000)
                            }
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
                    + "on screen p50 %.2f ms, p95 %.2f ms, max %.2f ms (listed p50 %.2f ms, p95 %.2f ms; the query "
                    + "p50 %.2f ms, p95 %.2f ms, the list p50 %.2f ms, p95 %.2f ms); %d not listed within a second",
                FixtureQuery.corpus.count, keys, onScreen.count, percentile(onScreen, 0.5), percentile(onScreen, 0.95),
                onScreen.max() ?? 0, percentile(listing, 0.5), percentile(listing, 0.95), percentile(queried, 0.5),
                percentile(queried, 0.95), percentile(made, 0.5), percentile(made, 0.95), missed,
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
        static func switchModules(
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
        static func renderEdits(
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
        static func cull(_ model: EditorModel) async -> Culled {
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
            // With --library-perf-culling n, the first n of the changes and their Undos alone.
            let arguments = LaunchArguments.all
            let limit = arguments.firstIndex(of: "--library-perf-culling").flatMap {
                $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil
            } ?? 8
            let steps = [ShortcutAction.rating3, .flagPick, .labelRed, .toggleMark]
                .flatMap { action in [(action, action), (action, ShortcutAction.undo)] }
                .prefix(limit)
            let monitor = MainThreadMonitor()
            monitor.start()
            let began = CFAbsoluteTimeGetCurrent()
            for (action, step) in steps {
                let title = step == .undo ? "Undo" : action.title
                let name = "culling, \(step == .undo ? "Undo " : "")\(action.title)"
                phase(name, sampling: .milliseconds(16))
                let watch = StepWatch(model.library)
                let started = CFAbsoluteTimeGetCurrent()
                model.perform(step)
                window.displayIfNeeded()
                CATransaction.flush()
                let shown = (CFAbsoluteTimeGetCurrent() - started) * 1000
                phase("\(name), writing", sampling: .milliseconds(16))
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
            return Culled(
                summary: monitor.summary(seconds: elapsed), onScreen: onScreen, writes: writes, left: left,
                count: count,
                report: report + "\n" + monitor.report("Main thread culling \(count) photos", seconds: elapsed),
            )
        }

        /// Groups the grid (LIB-41) in the editor window's own views, the grid shown: → held through the photos
        /// ungrouped, for comparison; the photos grouped by moment once, as a source is first grouped, which reads
        /// its photos' IDs from the index; then by each key in turn and the moments' Tighter–Looser setting
        /// through its steps, twice, each change timed from the change until its groups are drawn and committed;
        /// every group closed and opened again, by Close All Groups, Open All Groups and an ⌥-click's toggle of
        /// every group, each timed from the action until drawn; and → held through the moments. The main thread
        /// is watched over each part.
        static func group(_ model: EditorModel) async -> Grouped {
            phase("grouping, the first time")
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false,
            )
            window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
            window.orderBack(nil)
            defer {
                model.setLooseness(0)
                model.setGroupKey(.ungrouped)
                model.showModule(.develop)
                window.orderOut(nil)
                window.contentViewController = nil
            }
            model.showLibrary(.grid)
            if let first = model.items.first {
                model.select(first.url)
            }
            try? await Task.sleep(for: .milliseconds(500))
            phase("grouping, holding the arrow keys ungrouped", sampling: .milliseconds(8))
            let ungrouped = await holdRight(model)
            if let first = model.items.first {
                model.select(first.url)
            }
            let groups = model.gridGroups
            func drawn() {
                window.displayIfNeeded()
                CATransaction.flush()
            }
            /// Until the groups are by `key` at `looseness`, or two seconds.
            func grouped(by key: GroupKey, looseness: Int, since started: Double) async -> Bool {
                let setting = MomentSetting(looseness: looseness)
                while groups.list.map({ $0.groups.key != key || $0.groups.setting != setting }) ?? true,
                      CFAbsoluteTimeGetCurrent() - started < 2 {
                    try? await Task.sleep(for: .microseconds(250))
                }
                return groups.list.map { $0.groups.key == key && $0.groups.setting == setting } ?? false
            }
            var started = CFAbsoluteTimeGetCurrent()
            model.setGroupKey(.moment)
            guard await grouped(by: .moment, looseness: 0, since: started) else {
                return Grouped(report: "Grouping: the source couldn't be grouped")
            }
            drawn()
            let first = (CFAbsoluteTimeGetCurrent() - started) * 1000
            let firstOffMain = seconds(groups.lastGrouping) * 1000
            let count = groups.list?.groups.count ?? 0
            try? await Task.sleep(for: .milliseconds(300))

            phase("grouping, changing Group By and the setting", sampling: .milliseconds(8))
            var onScreen: [Double] = []
            var offMain: [Double] = []
            var parts: [[Double]] = []
            var slowest = (label: "", onScreen: 0.0, offMain: 0.0)
            var missed = 0
            let keys: [GroupKey] = [.day, .camera, .folder, .lens, .orientation, .momentCamera, .moment]
            let steps = [-1, -2, -3, -4, -3, -2, -1, 0, 1, 2, 3, 4, 3, 2, 1, 0]
            let monitor = MainThreadMonitor()
            monitor.start()
            let began = CFAbsoluteTimeGetCurrent()
            for _ in 0 ..< 2 {
                for key in keys {
                    started = CFAbsoluteTimeGetCurrent()
                    model.setGroupKey(key)
                    if await grouped(by: key, looseness: 0, since: started) {
                        drawn()
                        onScreen.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                        offMain.append(seconds(groups.lastGrouping) * 1000)
                        parts.append(groups.lastGroupingParts.map { seconds($0) * 1000 })
                        if let last = onScreen.last, last > slowest.onScreen {
                            slowest = (key.title, last, offMain.last ?? 0)
                        }
                    } else {
                        missed += 1
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                for looseness in steps {
                    started = CFAbsoluteTimeGetCurrent()
                    model.setLooseness(looseness)
                    if await grouped(by: .moment, looseness: looseness, since: started) {
                        drawn()
                        onScreen.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                        offMain.append(seconds(groups.lastGrouping) * 1000)
                        parts.append(groups.lastGroupingParts.map { seconds($0) * 1000 })
                        if let last = onScreen.last, last > slowest.onScreen {
                            slowest = ("the setting at \(looseness)", last, offMain.last ?? 0)
                        }
                    } else {
                        missed += 1
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - began
            monitor.stop()
            let changing = monitor.summary(seconds: elapsed)
            var report = String(
                format: "Grouping %d photos: first by moment (%d moments) on screen in %.1f ms (%.1f ms off the main "
                    + "thread, reading the photos' IDs); %d changes of Group By and the setting on screen p50 %.2f ms, "
                    + "p95 %.2f ms, max %.2f ms (off the main thread p50 %.2f ms, max %.2f ms), %d not within 2 s; the "
                    + "slowest, %@, on screen in %.2f ms, %.2f ms of it off the main thread",
                model.items.count, count, first, firstOffMain, onScreen.count, percentile(onScreen, 0.5),
                percentile(onScreen, 0.95), onScreen.max() ?? 0, percentile(offMain, 0.5), offMain.max() ?? 0, missed,
                slowest.label, slowest.onScreen, slowest.offMain,
            )
            let names = ["the photos' IDs", "the engine's grouping", "the groups", "their list"]
            report += "; off the main thread, p50: " + names.indices.map { part in
                String(
                    format: "%@ %.2f ms",
                    names[part],
                    percentile(parts.compactMap { $0.indices.contains(part) ? $0[part] : nil }, 0.5),
                )
            }.joined(separator: ", ")
            report += "\n" + monitor.report("Main thread changing Group By and the setting", seconds: elapsed)

            let toggles = await toggleGroups(model, drawn: drawn)
            let (toggling, toggled) = (toggles.summary, toggles.times)
            report += "\n" + toggles.report

            phase("grouping, holding the arrow keys through the moments", sampling: .milliseconds(8))
            model.openAllGroups()
            if let first = groups.endPhoto(first: true), let url = model.library.url(ofPhoto: first) {
                model.select(url)
            }
            let held = await holdRight(model)
            report += "\n" + ungrouped.report.replacingOccurrences(of: "holding →", with: "holding → ungrouped")
            report += "\n" + held.report.replacingOccurrences(of: "holding →", with: "holding → through the moments")
            return Grouped(
                grouped: true, changing: changing, onScreen: onScreen, toggling: toggling, toggled: toggled,
                arrows: held.summary, report: report,
            )
        }

        /// Every group closed and opened again, 40 times, by Close All Groups and Open All Groups and by an ⌥-click's
        /// toggle of every group in turn: each time from the action until `drawn`, and the main thread meanwhile.
        static func toggleGroups(_ model: EditorModel, drawn: () -> Void) async -> GroupToggles {
            phase("grouping, opening and closing every group", sampling: .milliseconds(8))
            let groups = model.gridGroups
            var toggled: [Double] = []
            let monitor = MainThreadMonitor()
            monitor.start()
            let began = CFAbsoluteTimeGetCurrent()
            for round in 0 ..< 40 {
                for close in [true, false] {
                    let started = CFAbsoluteTimeGetCurrent()
                    if round % 2 == 0 {
                        model.perform(close ? .closeAllGroups : .openAllGroups)
                    } else if let list = groups.list, !list.groups.isEmpty {
                        model.toggleGroup(list.groups.count - 1, all: true)
                    }
                    drawn()
                    toggled.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - began
            monitor.stop()
            let toggling = monitor.summary(seconds: elapsed)
            let report = String(
                format: "Every one of %d moments closed and opened again, %d times: on screen p50 %.2f ms, p95 %.2f ms, "
                    + "max %.2f ms",
                groups.list?.groups.count ?? 0, toggled.count, percentile(toggled, 0.5), percentile(toggled, 0.95),
                toggled.max() ?? 0,
            )
            return GroupToggles(
                summary: toggling, times: toggled,
                report: report + "\n" + monitor.report("Main thread opening and closing every group", seconds: elapsed),
            )
        }

        struct GroupToggles {
            let summary: MainThreadMonitor.Summary?, times: [Double], report: String
        }

        /// → held for 300 steps, a step every 30 ms as key repeat sends them, through the photos on show from the
        /// active one: the main thread over them.
        static func holdRight(_ model: EditorModel) async
            -> (summary: MainThreadMonitor.Summary?, report: String) {
            try? await Task.sleep(for: .milliseconds(300))
            let monitor = MainThreadMonitor()
            monitor.start()
            let began = CFAbsoluteTimeGetCurrent()
            var taken = 0
            for step in 0 ..< 300 {
                guard model.canPerform(.nextPhoto) else { break }
                model.perform(.nextPhoto)
                taken += 1
                let wait = began + Double(step + 1) * 0.030 - CFAbsoluteTimeGetCurrent()
                if wait > 0 {
                    try? await Task.sleep(for: .microseconds(Int(wait * 1_000_000)))
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - began
            monitor.stop()
            return (
                monitor.summary(seconds: elapsed),
                monitor.report("Main thread holding →, \(taken) steps", seconds: elapsed),
            )
        }

        static func groupBudgets(_ measured: Measured) -> [Budget] {
            [
                .atLeast("Grouped (1 yes, 0 no)", measured.grouped ? 1 : 0, 1, unit: ""),
                .below(
                    "Main thread p99 changing Group By and the setting", measured.grouping?.p99 ?? .infinity, 8.3,
                    unit: "ms",
                ),
                .below(
                    "Group By or the setting changed, its groups on screen, the slowest",
                    measured.regrouped.max() ?? .infinity, 16, unit: "ms",
                ),
                .below(
                    "Main thread p99 opening and closing every group", measured.toggling?.p99 ?? .infinity, 8.3,
                    unit: "ms",
                ),
                .below(
                    "Every group opened or closed, on screen, the slowest", measured.toggled.max() ?? .infinity, 16,
                    unit: "ms",
                ),
                .below(
                    "Main thread p99 holding the arrow keys through the groups", measured.groupArrows?.p99 ?? .infinity,
                    8.3, unit: "ms",
                ),
            ]
        }

        /// "`label`: N rendered, N a second", with the renders' waits, the engines made, and the p50 of the
        /// steps of photos of 12 MP or more (the fixture's raws; its JPEGs and HEICs are 64 by 48) and of
        /// the others.
        static func rendered(_ label: String, _ statistics: EditRenders.Statistics, seconds: Double) -> String {
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
        static func askForFrames(_ model: EditorModel, seconds: Double) async -> [Double] {
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
        static func diskReads() -> UInt64 {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return result == 0 ? usage.ri_diskio_bytesread : 0
        }

        static func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return .infinity }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }

        /// The highest footprint over launch while the library opened and the filmstrip and grid were
        /// browsed, before photos were opened in the editor.
        static func browsingPeak(_ memory: MemoryPhases) -> Double {
            let base = mb(memory.baseline)
            let browsing: Set = ["launched", "opened", "visible", "scrolled", "grid scrolled", "grid phases"]
            return memory.phases.filter { browsing.contains($0.label) }.map { mb($0.peak) - base }.max() ?? .infinity
        }
    }
#endif
