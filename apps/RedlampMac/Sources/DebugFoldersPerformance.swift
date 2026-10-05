#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Darwin
    import Foundation
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// `--folders-perf <folder> [--folders-perf-warm 3000] [--folders-perf-memory]
    /// [--folders-perf-profile] [--folders-perf-quit]`: opens a tree of photos (see
    /// `scripts/make-folder-fixture.sh`) with Show Photos in Subfolders in an editor of its own
    /// (nothing joins the working set), and checks the performance contract and memory budgets in
    /// docs/plans/2026-10-02-folders-design.md: time to first photos and to the whole tree, visible
    /// thumbnails, warming from the files and from the pack, the main thread while the filmstrip
    /// scrolls end to end, how busy the cores were, and the footprint through every phase, then
    /// after a memory-pressure trim and a few idle seconds. Writes `PerformanceReport.text`, ending
    /// with each budget's PASS or FAIL; with `--folders-perf-quit` it then quits, with status 1 if a
    /// budget failed. `--folders-perf-memory` also breaks the footprint down at each phase (and near
    /// the peaks) into `PerformanceReport.memory`; the region walks take a core, so measure
    /// performance without it. `--folders-perf-decoder` starts the decode service at launch and
    /// adds its resident memory at launch, after the thumbnails and after `--folders-perf-decoder-idle`
    /// seconds idle (60), and the visible thumbnails' time with it running (DATA-17).
    /// `scripts/folders-perf.sh` runs it all as a gate.
    @MainActor
    enum DebugFoldersPerformance {
        /// What the budgets are checked against.
        private struct Measured {
            var firstItems: Duration = .zero
            var listed: Duration = .zero
            var count = 0
            var visible: Duration = .zero
            var warmRate = 0.0
            var packRate = 0.0
            var busy: MainThreadMonitor.Summary?
            var scrolling: MainThreadMonitor.Summary?
        }

        static func run(root: URL, engine: any EditingEngine) async {
            let arguments = LaunchArguments.all
            var lines = [
                "Folders performance on \(root.path)",
                "Cores: \(CoreCounts.performance) performance, \(CoreCounts.efficiency) efficiency; lanes \(WorkScheduler.shared.widths)",
                "Load average at the start: \(loadAverage())",
            ]
            var measured = Measured()
            let packs = ThumbnailPacks(directory: FileManager.default.temporaryDirectory
                .appending(path: "folders-perf-packs-\(UUID().uuidString)"))
            defer { try? FileManager.default.removeItem(at: packs.directory) }
            let loader = ThumbnailLoader(packs: packs) { url, size in engine.decodeThumbnail(
                for: url,
                maxPixelSize: size,
            ) }
            // The folder opens without a photo being selected, so the editor's decoded photos
            // don't count against the folders' memory.
            let library = FolderLibrary()
            // The library is on as in the app, unless it's turned off, but in a folder of its own:
            // it hasn't indexed the fixture, so Folders lists it.
            let libraryPaths = LibraryPaths(root: FileManager.default.temporaryDirectory
                .appending(path: "folders-perf-library-\(UUID().uuidString)", directoryHint: .isDirectory))
            defer { try? FileManager.default.removeItem(at: libraryPaths.root) }
            if LibraryService.isEnabled(.standard) {
                library.attach(LibraryService(paths: libraryPaths, sidecars: library.sidecars) { url, size in
                    engine.decodeThumbnail(for: url, maxPixelSize: size)
                })
            }
            lines.append("The library: \(library.service == nil ? "off" : "on, without the fixture")")
            let model = EditorModel(engine: engine, library: library, thumbnailLoader: loader)
            let memory = MemoryPhases(breakdowns: arguments.contains("--folders-perf-memory")) {
                let running = WorkScheduler.shared.load().running
                return [
                    .count("photos listed", library.count),
                    .bytes("thumbnails in memory", loader.memoryUsed),
                    .count("thumbnails in memory", loader.cachedCount),
                    .count("packs open", packs.openCount),
                    .count("jobs running on screen", running[.onScreen] ?? 0),
                    .count("jobs running look-ahead", running[.lookAhead] ?? 0),
                    .count("jobs running in the background", running[.background] ?? 0),
                ]
            }
            let monitor = MainThreadMonitor()
            let sampler = arguments.contains("--folders-perf-profile") ? MainThreadSampler() : nil
            let decoder = arguments.contains("--folders-perf-decoder") ? DecoderProbe() : nil
            var decoderMemory: [(phase: String, bytes: UInt64?)] = []
            if let decoder {
                await decoder.start()
                decoderMemory.append(("launch", decoder.resident()))
            }
            sampler?.start()
            memory.start()
            await memory.mark("launch")
            lines.append(String(format: "Footprint before opening: %.0f MB", mb(memory.baseline)))
            let cores = CoreLoad()
            monitor.start()

            lines.append("Background work allowed (not in Low Power Mode, not hot): \(WorkScheduler.isRelaxed())")
            DebugPerformance.trace("folders-perf: opening")
            let started = ContinuousClock.now
            library.setIncludesSubfolders(true)
            library.open(root)
            while model.library.count == 0, model.library.isListing {
                try? await Task.sleep(for: .milliseconds(1))
            }
            measured.firstItems = ContinuousClock.now - started
            while model.library.isListing {
                try? await Task.sleep(for: .milliseconds(2))
            }
            measured.listed = ContinuousClock.now - started
            measured.count = model.library.count
            lines.append(
                "Listing: first photos in \(ms(measured.firstItems)), all \(measured.count) photos in \(ms(measured.listed))",
            )
            DebugPerformance.trace("folders-perf: listed \(model.library.count)")
            await memory.mark("listed")

            let visible = Array(model.items.prefix(15))
            let thumbnailsStarted = ContinuousClock.now
            await load(visible, lane: .onScreen, with: loader)
            measured.visible = ContinuousClock.now - thumbnailsStarted
            lines.append("Visible thumbnails (15, from the files): \(ms(measured.visible))")
            await memory.mark("visible")
            if let decoder {
                decoderMemory.append(("visible thumbnails", decoder.resident()))
            }

            let warmCount = arguments.firstIndex(of: "--folders-perf-warm")
                .flatMap { Int(arguments[$0 + 1]) } ?? 3000
            let warming = Array(model.items.dropFirst(15).prefix(warmCount))
            cores.start()
            let warmStarted = ContinuousClock.now
            DebugPerformance.trace("folders-perf: warming")
            loader.warm(warming)
            while loader.isWarming, ContinuousClock.now - warmStarted < .seconds(60) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let warmTime = ContinuousClock.now - warmStarted
            let warmed = warming.count - loader.warmingRemaining
            measured.warmRate = Double(warmed) / seconds(warmTime)
            lines.append(String(
                format: "Warming from the files: %d thumbnails in %@, %.0f a second", warmed, ms(warmTime),
                measured.warmRate,
            ))
            loader.stopWarming()
            lines.append("  cores while warming: \(cores.report())")
            await memory.mark("warmed")
            if let decoder {
                decoderMemory.append(("thumbnails warmed", decoder.resident()))
            }

            DebugPerformance.trace("folders-perf: reading the pack")
            loader.removeAll()
            let fromPack = Array(warming.prefix(2000))
            cores.start()
            let packStarted = ContinuousClock.now
            await load(fromPack, lane: .lookAhead, with: loader)
            let packTime = ContinuousClock.now - packStarted
            measured.packRate = Double(fromPack.count) / seconds(packTime)
            lines.append(String(
                format: "From the pack: %d thumbnails in %@, %.0f a second", fromPack.count, ms(packTime),
                measured.packRate,
            ))
            lines.append("  cores reading the pack: \(cores.report())")
            await memory.mark("pack read")
            monitor.stop()
            measured.busy = monitor.summary(seconds: seconds(ContinuousClock.now - started))
            lines.append(monitor.report(
                "Main thread while listing, decoding and warming",
                seconds: seconds(ContinuousClock.now - started),
            ))

            let (scrolling, scrollReport) = await scroll(model)
            measured.scrolling = scrolling
            lines.append(scrollReport)
            sampler?.stop()
            if let sampler {
                try? await Task.sleep(for: .milliseconds(20))
                try? sampler.report().write(toFile: PerformanceReport.profile, atomically: true, encoding: .utf8)
            }
            await memory.mark("scrolled")
            // Browsing paused: what the app holds without memory pressure.
            try? await Task.sleep(for: .seconds(3))
            await memory.mark("settled")
            let thumbnailsHeld = loader.memoryUsed

            // What a memory-pressure warning does: the loader keeps only what's on screen, and malloc
            // is asked to give back what it can.
            DebugPerformance.trace("folders-perf: trimming")
            loader.trim(to: 0)
            let relieved = malloc_zone_pressure_relief(nil, 0)
            await memory.mark("trimmed")
            try? await Task.sleep(for: .seconds(5))
            await memory.mark("idle")
            memory.stop()
            lines.append(memory.summary())
            lines.append(String(
                format: "Peak footprint: %.0f MB; thumbnails in memory %d MB once settled",
                mb(memory.peak), thumbnailsHeld >> 20,
            ))
            var metrics = [
                "folders-first": seconds(measured.firstItems) * 1000,
                "folders-list": seconds(measured.listed) * 1000,
                "folders-thumbs": seconds(measured.visible) * 1000,
                "folders-warm": measured.warmRate,
                "folders-cache": measured.packRate,
                "folders-main-listing": measured.busy?.p99 ?? .infinity,
                "folders-main-scroll": measured.scrolling?.p99 ?? .infinity,
                "folders-peak-memory": mb(memory.peak),
            ]
            if let decoder {
                let idle = arguments.firstIndex(of: "--folders-perf-decoder-idle")
                    .flatMap { Int(arguments[$0 + 1]) } ?? 60
                DebugPerformance.trace("folders-perf: decode service idle \(idle) s")
                try? await Task.sleep(for: .seconds(idle))
                decoderMemory.append(("after \(idle) s idle", decoder.resident()))
                lines.append("Decode service resident memory, started at launch: " + decoderMemory.map { phase, bytes in
                    "\(phase) \(bytes.map { String(format: "%.1f MB", mb($0)) } ?? "not running")"
                }.joined(separator: ", "))
                metrics["folders-thumbs-decoder-running"] = metrics["folders-thumbs"]
                for (key, index) in [
                    ("decoder-memory-launch", 0),
                    ("decoder-memory-thumbs", 2),
                    ("decoder-memory-idle", 3),
                ] {
                    if let bytes = decoderMemory[index].bytes {
                        metrics[key] = mb(bytes)
                    }
                }
            }
            DebugPerformance.writeMetrics(metrics)
            let budgets = budgets(measured, memory: memory, thumbnailBudget: loader.budget)
            finish(
                lines,
                budgets: budgets,
                memory: memory,
                title: "Memory on \(root.path), \(measured.count) photos",
                notes: [
                    "",
                    String(format: "malloc_zone_pressure_relief at the trim gave back %.1f MB.", mb(UInt64(relieved))),
                ],
            )
        }

        /// Scrolls an offscreen filmstrip end to end in 4 s, at 120 Hz, watching the main thread.
        static func scroll(_ model: EditorModel) async -> (MainThreadMonitor.Summary?, String) {
            DebugPerformance.trace("folders-perf: scrolling")
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1200, height: FilmstripViews.height), styleMask: [.borderless],
                backing: .buffered, defer: false,
            )
            let strip = FilmstripViews.make(model: model)
            window.contentView = strip
            window.orderBack(nil)
            try? await Task.sleep(for: .milliseconds(300))
            let monitor = MainThreadMonitor()
            monitor.start()
            let duration = 4.0
            let started = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - started < duration {
                FilmstripViews.scroll(strip, to: (CFAbsoluteTimeGetCurrent() - started) / duration)
                try? await Task.sleep(for: .microseconds(8333))
            }
            monitor.stop()
            window.orderOut(nil)
            return (
                monitor.summary(seconds: duration),
                monitor.report("Main thread scrolling the filmstrip end to end", seconds: duration),
            )
        }

        /// Asks for every thumbnail at once and waits until they're all in.
        private static func load(
            _ items: [RedlampUI.LibraryItem],
            lane: WorkScheduler.Lane,
            with loader: ThumbnailLoader,
        ) async {
            var remaining = items.count
            for item in items {
                loader.request(item, lane: lane) { _ in remaining -= 1 }
            }
            while remaining > 0 {
                try? await Task.sleep(for: .milliseconds(1))
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

    extension DebugFoldersPerformance {
        /// Writes the reports, the budgets last, and quits if asked (with status 1 if a budget failed).
        private static func finish(
            _ lines: [String], budgets: [Budget], memory: MemoryPhases, title: String, notes: [String],
        ) {
            let failed = budgets.filter { !$0.passed }
            let report = (lines + ["Budgets (load average \(loadAverage())):"] + budgets.map(\.line) + [
                failed.isEmpty
                    ? "Budgets: all \(budgets.count) met"
                    :
                    "Budgets: \(failed.count) of \(budgets.count) over: \(failed.map(\.name).joined(separator: "; "))",
            ]).joined(separator: "\n")
            print(report)
            if memory.breakdowns {
                let table = memory.report(title: title, notes: notes + [
                    String(
                        format: "Of 16 MB freed in 1 MB blocks after idling, the footprint still held %.0f%%.",
                        MemorySnapshot.mallocKeepsFreedBlocks() * 100,
                    ),
                    "Load average at the end: \(loadAverage())",
                ])
                try? (table + "\n").write(toFile: PerformanceReport.memory, atomically: true, encoding: .utf8)
            }
            try? (report + "\n").write(toFile: PerformanceReport.text, atomically: true, encoding: .utf8)
            if LaunchArguments.all.contains("--folders-perf-quit") {
                if failed.isEmpty {
                    NSApp.terminate(nil)
                } else {
                    exit(1)
                }
            }
        }

        /// The performance contract and the memory budgets (docs/plans/2026-10-02-folders-design.md).
        private static func budgets(_ measured: Measured, memory: MemoryPhases, thumbnailBudget: Int) -> [Budget] {
            let phases = Dictionary(memory.phases.map { ($0.label, $0) }) { first, _ in first }
            let base = mb(memory.baseline)
            func over(_ label: String) -> Double {
                phases[label].map { mb($0.after.footprint) - base } ?? .infinity
            }
            let thumbnails = memory.phases.map { phase in
                phase.after.counters.first { $0.label == "thumbnails in memory" && $0.isBytes }?.value ?? 0
            }.max() ?? 0
            func milliseconds(_ duration: Duration) -> Double {
                seconds(duration) * 1000
            }
            return [
                .below("First photos", milliseconds(measured.firstItems), 50, unit: "ms"),
                .below("All \(measured.count) photos listed", milliseconds(measured.listed), 300, unit: "ms"),
                .below("Visible thumbnails from the files", milliseconds(measured.visible), 400, unit: "ms"),
                .atLeast("Warming from the files", measured.warmRate, 300, unit: "a second"),
                .atLeast("Thumbnails from the pack", measured.packRate, 2000, unit: "a second"),
                .below(
                    "Main thread p99 while listing, decoding, warming", measured.busy?.p99 ?? .infinity, 8.3,
                    unit: "ms",
                ),
                .below("Main thread p99 while scrolling", measured.scrolling?.p99 ?? .infinity, 8.3, unit: "ms"),
                .below(
                    "Thumbnails in memory (pixels)",
                    thumbnails / 1_048_576,
                    Double(thumbnailBudget >> 20),
                    unit: "MB",
                ),
                .below("Peak footprint over launch", mb(memory.peak) - base, MemoryBudget.peak, unit: "MB"),
                .below("Over launch once listed", over("listed"), MemoryBudget.listed(measured.count), unit: "MB"),
                .below("Over launch with browsing paused", over("settled"), MemoryBudget.settled, unit: "MB"),
                .below("Over launch after a memory-pressure trim", over("trimmed"), MemoryBudget.trimmed, unit: "MB"),
                .below("Over launch, idle after the trim", over("idle"), MemoryBudget.idle, unit: "MB"),
            ]
        }
    }

    /// How busy each CPU was between `start` and `report`. On Apple silicon the efficiency cores
    /// come first in the CPU numbering.
    final class CoreLoad {
        private var before: [(busy: UInt64, total: UInt64)] = []

        func start() {
            before = Self.ticks()
        }

        func report() -> String {
            let after = Self.ticks()
            let loads = zip(before, after).map { start, end -> Double in
                let total = Double(end.total - start.total)
                return total > 0 ? Double(end.busy - start.busy) / total : 0
            }
            let efficiency = CoreCounts.efficiency
            func average(_ values: ArraySlice<Double>) -> String {
                values.isEmpty ? "—" : String(format: "%.0f%%", values.reduce(0, +) / Double(values.count) * 100)
            }
            return "efficiency \(average(loads.prefix(efficiency))), performance \(average(loads.dropFirst(efficiency)))"
        }

        private static func ticks() -> [(busy: UInt64, total: UInt64)] {
            var count: natural_t = 0
            var info: processor_info_array_t?
            var infoCount: mach_msg_type_number_t = 0
            guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
                == KERN_SUCCESS, let info else { return [] }
            defer {
                vm_deallocate(
                    mach_task_self_, vm_address_t(bitPattern: info),
                    vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride),
                )
            }
            return (0 ..< Int(count)).map { cpu in
                let base = cpu * Int(CPU_STATE_MAX)
                let user = UInt64(info[base + Int(CPU_STATE_USER)])
                let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
                let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
                let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
                return (user + system + nice, user + system + nice + idle)
            }
        }
    }
#endif
