#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Darwin
    import Foundation
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// `--folders-perf <folder> [--folders-perf-warm 3000] [--folders-perf-quit]`: opens a tree of
    /// photos (see `scripts/make-folder-fixture.sh`) with Show Photos in Subfolders in an editor of
    /// its own (nothing joins the working set), and measures the performance contract in
    /// docs/plans/2026-10-02-folders-design.md: time to first photos and to the whole tree,
    /// visible thumbnails, warming from the files and from the pack, the main thread while the
    /// filmstrip scrolls end to end, how busy the cores were, and the peak footprint. Writes
    /// /tmp/redlamp-perf.txt.
    @MainActor
    enum DebugFoldersPerformance {
        static func run(root: URL, engine: any EditingEngine) async {
            var lines = [
                "Folders performance on \(root.path)",
                "Cores: \(CoreCounts.performance) performance, \(CoreCounts.efficiency) efficiency; lanes \(WorkScheduler.shared.widths)",
            ]
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
            let model = EditorModel(engine: engine, library: library, thumbnailLoader: loader)
            let monitor = MainThreadMonitor()
            let footprint = FootprintSampler()
            let sampler = LaunchArguments.all.contains("--folders-perf-profile") ? MainThreadSampler() : nil
            sampler?.start()
            lines.append(String(format: "Footprint before opening: %.0f MB", FootprintSampler.footprint() / 1_048_576))
            let cores = CoreLoad()
            monitor.start()
            footprint.start()

            lines.append("Background work allowed (not in Low Power Mode, not hot): \(WorkScheduler.isRelaxed())")
            DebugPerformance.trace("folders-perf: opening")
            let started = ContinuousClock.now
            library.setIncludesSubfolders(true)
            library.open(root)
            while model.library.count == 0, model.library.isListing {
                try? await Task.sleep(for: .milliseconds(1))
            }
            let firstItems = ContinuousClock.now - started
            while model.library.isListing {
                try? await Task.sleep(for: .milliseconds(2))
            }
            let listed = ContinuousClock.now - started
            lines
                .append(
                    "Listing: first photos in \(ms(firstItems)), all \(model.library.count) photos in \(ms(listed))",
                )
            DebugPerformance.trace("folders-perf: listed \(model.library.count)")

            let visible = Array(model.items.prefix(15))
            let thumbnailsStarted = ContinuousClock.now
            await load(visible, lane: .onScreen, with: loader)
            lines.append("Visible thumbnails (15, from the files): \(ms(ContinuousClock.now - thumbnailsStarted))")

            let warmCount = LaunchArguments.all.firstIndex(of: "--folders-perf-warm")
                .flatMap { Int(LaunchArguments.all[$0 + 1]) } ?? 3000
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
            lines.append(String(
                format: "Warming from the files: %d thumbnails in %@, %.0f a second", warmed, ms(warmTime),
                Double(warmed) / seconds(warmTime),
            ))
            loader.stopWarming()
            DebugPerformance.trace("folders-perf: reading the pack")
            lines.append("  cores while warming: \(cores.report())")

            loader.removeAll()
            let fromPack = Array(warming.prefix(2000))
            cores.start()
            let packStarted = ContinuousClock.now
            await load(fromPack, lane: .lookAhead, with: loader)
            let packTime = ContinuousClock.now - packStarted
            lines.append(String(
                format: "From the pack: %d thumbnails in %@, %.0f a second", fromPack.count, ms(packTime),
                Double(fromPack.count) / seconds(packTime),
            ))
            lines.append("  cores reading the pack: \(cores.report())")
            monitor.stop()
            lines.append(monitor.report(
                "Main thread while listing, decoding and warming",
                seconds: seconds(ContinuousClock.now - started),
            ))

            DebugPerformance.trace("folders-perf: scrolling")
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1200, height: FilmstripViews.height), styleMask: [.borderless],
                backing: .buffered, defer: false,
            )
            let strip = FilmstripViews.make(model: model)
            window.contentView = strip
            window.orderBack(nil)
            try? await Task.sleep(for: .milliseconds(300))
            let scrolling = MainThreadMonitor()
            scrolling.start()
            let scrollSeconds = 4.0
            let scrollStarted = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - scrollStarted < scrollSeconds {
                FilmstripViews.scroll(strip, to: (CFAbsoluteTimeGetCurrent() - scrollStarted) / scrollSeconds)
                try? await Task.sleep(for: .microseconds(8333))
            }
            scrolling.stop()
            window.orderOut(nil)
            lines.append(scrolling.report("Main thread scrolling the filmstrip end to end", seconds: scrollSeconds))
            footprint.stop()
            sampler?.stop()
            if let sampler {
                try? await Task.sleep(for: .milliseconds(20))
                try? sampler.report().write(toFile: "/tmp/redlamp-profile.txt", atomically: true, encoding: .utf8)
            }
            lines.append(String(
                format: "Peak footprint: %.0f MB; thumbnails in memory %d MB",
                footprint.peak / 1_048_576,
                loader.memoryUsed >> 20,
            ))

            let report = lines.joined(separator: "\n")
            print(report)
            try? (report + "\n").write(toFile: "/tmp/redlamp-perf.txt", atomically: true, encoding: .utf8)
            if LaunchArguments.all.contains("--folders-perf-quit") {
                NSApp.terminate(nil)
            }
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

        private static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        private static func ms(_ duration: Duration) -> String {
            String(format: "%.1f ms", seconds(duration) * 1000)
        }
    }

    /// The process's physical footprint, sampled every 20 ms.
    @MainActor
    final class FootprintSampler {
        private(set) var peak: Double = 0
        private var timer: Timer?

        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let sampler = self else { return }
                    sampler.peak = max(sampler.peak, FootprintSampler.footprint())
                }
            }
        }

        func stop() {
            timer?.invalidate()
            peak = max(peak, Self.footprint())
        }

        static func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) : 0
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
