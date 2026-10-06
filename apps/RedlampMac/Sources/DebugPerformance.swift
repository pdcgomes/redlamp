#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import CoreFoundation
    import Foundation
    import RedlampDesign
    import RedlampEngineAPI
    import RedlampUI
    import Synchronization

    /// Samples the main thread's call stack every millisecond from a background thread (suspend,
    /// walk the frame-pointer chain, resume) — a Time Profiler that needs neither developer mode
    /// nor a debugger. Nothing may allocate while the main thread is suspended (it could hold the
    /// malloc lock), so samples go into a preallocated buffer.
    final class MainThreadSampler: @unchecked Sendable {
        private static let maxDepth = 128
        private static let maxSamples = 20000
        private let mainThread = mach_thread_self()
        private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: maxDepth * maxSamples)
        private let depths = UnsafeMutablePointer<Int>.allocate(capacity: maxSamples)
        private var count = 0
        private let running = Mutex(false)

        func start() {
            running.withLock { $0 = true }
            let thread = Thread { [self] in
                while running.withLock({ $0 }), count < Self.maxSamples {
                    sample()
                    usleep(1000)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() {
            running.withLock { $0 = false }
        }

        private func sample() {
            var state = arm_thread_state64_t()
            var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
            guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
            defer { thread_resume(mainThread) }
            let result = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                    thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &stateCount)
                }
            }
            guard result == KERN_SUCCESS else { return }
            let frames = buffer + count * Self.maxDepth
            var depth = 0
            frames[depth] = UInt(state.__pc) & Self.addressMask
            depth += 1
            frames[depth] = UInt(state.__lr) & Self.addressMask
            depth += 1
            var fp = UInt(state.__fp)
            while fp != 0, fp & 7 == 0, depth < Self.maxDepth {
                guard let frame = UnsafePointer<UInt>(bitPattern: fp) else { break }
                let next = frame[0]
                let returnAddress = frame[1] & Self.addressMask
                if returnAddress == 0 {
                    break
                }
                frames[depth] = returnAddress
                depth += 1
                if next <= fp {
                    break
                }
                fp = next
            }
            depths[count] = depth
            count += 1
        }

        /// Strips pointer-authentication bits from return addresses signed by arm64e system code.
        private static let addressMask: UInt = 0x0000_0FFF_FFFF_FFFF

        /// Top functions by self time (the frame on top of the stack) and by total time (anywhere
        /// on the stack), as mangled symbols; `scripts/perf-sweep.sh` demangles them.
        func report(top: Int = 150, focus: String? = nil) -> String {
            var selfCounts: [String: Int] = [:]
            var totalCounts: [String: Int] = [:]
            var focusCounts: [String: Int] = [:]
            var names: [UInt: String] = [:]
            func name(_ address: UInt) -> String {
                if let cached = names[address] {
                    return cached
                }
                var info = Dl_info()
                var resolved = String(format: "0x%lx", address)
                if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                    let image = info.dli_fname.map { URL(
                        fileURLWithPath: String(cString: $0),
                    ).lastPathComponent } ?? "?"
                    let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
                    resolved = "\(symbol)  [\(image)]"
                }
                names[address] = resolved
                return resolved
            }
            for index in 0 ..< count {
                let frames = buffer + index * Self.maxDepth
                let depth = depths[index]
                guard depth > 0 else { continue }
                selfCounts[name(frames[0]), default: 0] += 1
                var seen = Set<String>()
                var focusedCallee: String?
                for level in 0 ..< depth where frames[level] > 1 {
                    // Return addresses point after the call; step back into the calling instruction.
                    let symbol = name(level == 0 ? frames[level] : frames[level] - 1)
                    if seen.insert(symbol).inserted {
                        totalCounts[symbol, default: 0] += 1
                    }
                    if let focus, focusedCallee == nil, symbol.contains(focus), level > 0, frames[level - 1] > 1 {
                        focusedCallee = name(level == 1 ? frames[0] : frames[level - 1] - 1)
                    }
                }
                if let focusedCallee {
                    focusCounts[focusedCallee, default: 0] += 1
                }
            }
            func table(_ counts: [String: Int]) -> String {
                counts.sorted { $0.value > $1.value }.prefix(top)
                    .map { String(format: "%6.1f%%  %@", Double($0.value) / Double(max(count, 1)) * 100, $0.key) }
                    .joined(separator: "\n")
            }
            let ours = totalCounts.filter { $0.key.contains("[Redlamp") && !$0.key.hasPrefix("main ") }
            return """
            \(count) main-thread samples

            -- total (inclusive)
            \(table(totalCounts))

            -- total, Redlamp code only
            \(table(ours))

            -- self
            \(table(selfCounts))

            -- direct callees of \(focus ?? "(no --sweep-profile-focus)")
            \(table(focusCounts))
            """
        }
    }

    /// Where a performance run writes its reports. `--perf-report <directory>` gives the run a
    /// directory of its own (perf.txt, perf.json, memory.txt, profile.txt and debug.log), so runs
    /// launched at the same time from other checkouts can neither delete nor take its report;
    /// the launch arguments split on whitespace, so the path can't contain any. Without it, the
    /// shared files in /tmp (/tmp/redlamp-perf.txt and its siblings).
    enum PerformanceReport {
        static let directory: String? = {
            let arguments = LaunchArguments.all
            return arguments.firstIndex(of: "--perf-report").flatMap {
                $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
            }
        }()

        static let text = path("perf.txt", shared: "/tmp/redlamp-perf.txt")
        static let metrics = path("perf.json", shared: "/tmp/redlamp-perf.json")
        static let memory = path("memory.txt", shared: "/tmp/redlamp-memory.txt")
        static let profile = path("profile.txt", shared: "/tmp/redlamp-profile.txt")
        static let log = path("debug.log", shared: "/tmp/redlamp-debug.log")

        private static func path(_ name: String, shared: String) -> String {
            guard let directory else { return shared }
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            return (directory as NSString).appendingPathComponent(name)
        }
    }

    /// `--sweep <parameter> [--sweep-seconds 3]`: drags a slider at 120 Hz (like a trackpad),
    /// then writes main-thread and frame statistics to `PerformanceReport.text`.
    @MainActor
    enum DebugPerformance {
        static func scheduleIfRequested(model: EditorModel) {
            let arguments = LaunchArguments.all
            trace("launched with \(arguments.dropFirst().joined(separator: " "))")
            if let index = arguments.firstIndex(of: "--folders-perf"), index + 1 < arguments.count {
                let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    await DebugFoldersPerformance.run(root: root, engine: model.engine)
                }
                return
            }
            if arguments.contains("--browse") {
                let dwell = arguments.firstIndex(of: "--browse-dwell").flatMap { Double(arguments[$0 + 1]) } ?? 0.5
                Task { @MainActor in
                    while model.info == nil || model.isLoading {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                    await browse(dwell: dwell, model: model)
                }
                return
            }
            guard let index = arguments.firstIndex(of: "--sweep"), index + 1 < arguments.count else { return }
            let target = arguments[index + 1]
            let parameter = ParameterID.allCases.first { target == "\($0)" }
            guard parameter != nil || target == "maskDrag" else { return }
            let seconds = arguments.firstIndex(of: "--sweep-seconds").flatMap { Double(arguments[$0 + 1]) } ?? 3

            Task { @MainActor in
                trace("sweep scheduled")
                while model.info == nil || model.isLoading {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                trace("image ready")
                try? await Task.sleep(for: .seconds(1.5))
                if let parameter {
                    await sweep(parameter, seconds: seconds, model: model)
                } else {
                    await maskDrag(seconds: seconds, model: model)
                }
            }
        }

        /// The run's numbers by metric ID (docs/performance/metrics.json), for scripts/perf-record.sh.
        static func writeMetrics(_ metrics: [String: Double]) {
            let finite = metrics.filter(\.value.isFinite)
            if let data = try? JSONSerialization.data(withJSONObject: finite, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: PerformanceReport.metrics), options: .atomic)
            }
        }

        static func trace(_ message: String) {
            let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
            if let handle = FileHandle(forWritingAtPath: PerformanceReport.log) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: PerformanceReport.log, atomically: true, encoding: .utf8)
            }
        }

        private static func sweep(_ parameter: ParameterID, seconds: Double, model: EditorModel) async {
            let spec = parameter.spec
            await drag(
                "\(spec.label) sweep", seconds: seconds, model: model,
                begin: { model.beginEdit(parameter) },
                step: { t in model.setSliderValue(parameter, spec.value(atPosition: 0.5 + 0.35 * sin(t * .pi * 4))) },
            )
        }

        /// `--sweep maskDrag`: draws a radial mask, then moves it the way its center handle does.
        private static func maskDrag(seconds: Double, model: EditorModel) async {
            var radial = RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.15)
            model.startDrawing(.radial)
            model.beginDrawing(.radial(radial))
            model.finishDrawing()
            guard let mask = model.selectedMask, let component = mask.components.first else { return }
            await drag(
                "radial mask drag", seconds: seconds, model: model,
                begin: { model.beginEdit() },
                step: { t in
                    radial.center = ImagePoint(x: 0.5 + 0.2 * sin(t * .pi * 4), y: 0.5 + 0.15 * cos(t * .pi * 4))
                    model.updateComponent(component.id, in: mask.id, shape: .radial(radial))
                },
            )
        }

        /// Runs `step` with progress 0…1 at 120 Hz (like a trackpad drag), then writes main-thread
        /// and frame statistics to /tmp/redlamp-perf.txt.
        private static func drag(
            _ label: String,
            seconds: Double,
            model: EditorModel,
            begin: () -> Void,
            step: (Double) -> Void,
        ) async {
            trace("sweep start")
            defer { trace("sweep end") }
            let monitor = MainThreadMonitor()
            let framesBefore = model.debugFrameCount
            let sampler = LaunchArguments.all.contains("--sweep-profile") ? MainThreadSampler() : nil
            sampler?.start()
            monitor.start()
            begin()
            let started = CFAbsoluteTimeGetCurrent()
            var events = 0
            while CFAbsoluteTimeGetCurrent() - started < seconds {
                step((CFAbsoluteTimeGetCurrent() - started) / seconds)
                events += 1
                try? await Task.sleep(for: .microseconds(8333))
            }
            model.endEdit()
            try? await Task.sleep(for: .milliseconds(300))
            monitor.stop()
            sampler?.stop()
            trace("drag finished")
            if let sampler {
                try? await Task.sleep(for: .milliseconds(20))
                defer { trace("profile written") }
                let arguments = LaunchArguments.all
                let focus = arguments.firstIndex(of: "--sweep-profile-focus").flatMap {
                    $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
                }
                try? sampler.report(focus: focus).write(
                    toFile: PerformanceReport.profile,
                    atomically: true,
                    encoding: .utf8,
                )
            }

            let frames = model.debugFrameCount - framesBefore
            func milliseconds(_ durations: some Collection<Duration>) -> [Double] {
                durations.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }
                    .sorted()
            }
            func percentile(_ sorted: [Double], _ percent: Int) -> Double {
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * percent / 100)]
            }
            let renders = milliseconds(model.debugRenderDurations.suffix(frames))
            let latencies = milliseconds(model.debugFrameLatencies.suffix(frames))
            let report = [
                monitor.report("main thread during \(label)", seconds: seconds),
                String(
                    format: "drag events: %d (%.0f/s), frames received: %d (%.0f/s)",
                    events,
                    Double(events) / seconds,
                    frames,
                    Double(frames) / seconds,
                ),
                String(
                    format: "engine render: p50 %.1f ms, p95 %.1f ms",
                    percentile(renders, 50), percentile(renders, 95),
                ),
                String(
                    format: "request to frame received: p50 %.1f ms, p95 %.1f ms, p99 %.1f ms, max %.1f ms",
                    percentile(latencies, 50), percentile(latencies, 95), percentile(latencies, 99),
                    latencies.last ?? 0,
                ),
            ].joined(separator: "\n")
            print(report)
            try? (report + "\n").write(toFile: PerformanceReport.text, atomically: true, encoding: .utf8)
            if let summary = monitor.summary(seconds: seconds) {
                writeMetrics([
                    "drag-busy": summary.busy * 100,
                    "drag-median": summary.p50,
                    "drag-p95": summary.p95,
                    "drag-p99": summary.p99,
                ])
            }
            if LaunchArguments.all.contains("--sweep-quit") {
                NSApp.terminate(nil)
            }
        }

        /// The next frame shown and when it landed, or nil once `timeout` passes without one.
        private static func nextFrame(
            of model: EditorModel, within timeout: Duration,
        ) async -> (frame: RenderedFrame, arrived: CFAbsoluteTime)? {
            @MainActor final class Once {
                var done = false
            }
            let once = Once()
            return await withCheckedContinuation { continuation in
                Task { @MainActor in
                    let frame = await model.frames.nextFrame()
                    let arrived = CFAbsoluteTimeGetCurrent()
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(returning: (frame, arrived))
                }
                Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(returning: nil)
                }
            }
        }

        /// `--browse [--browse-dwell 0.5]`: from the first photo, steps forward through every
        /// photo, then back, pausing `dwell` seconds on each like someone pressing the arrow keys.
        /// For each step, records the time from selection to the new photo's first frame and
        /// whether the placeholder (thumbnail and spinner) was shown; a step with no frame within
        /// two seconds is reported as such.
        private static func browse(dwell: Double, model: EditorModel) async {
            var lines: [String] = []
            let count = model.items.count
            if let first = model.items.first?.url, model.info?.url != first {
                model.select(first)
                for _ in 0 ..< 200 where model.info?.url != first || model.isLoading || !model.hasFrame {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .seconds(dwell))
            }
            for (label, offset) in [("forward, first visit", 1), ("back, revisit", -1)] {
                var latencies: [Double] = []
                var placeholders = 0
                var timeouts = 0
                for _ in 1 ..< count {
                    let framesBefore = model.debugFrameCount
                    let started = CFAbsoluteTimeGetCurrent()
                    if offset > 0 {
                        model.selectNext()
                    } else {
                        model.selectPrevious()
                    }
                    let showedPlaceholder = !model.hasFrame || model.isLoading
                    // Timestamped as the frame lands; sleeping to poll is too coarse.
                    var arrived = started
                    var frame = model.frames.current
                    var timedOut = false
                    while model.debugFrameCount == framesBefore {
                        guard let next = await nextFrame(of: model, within: .seconds(2)) else {
                            timedOut = true
                            break
                        }
                        frame = next.frame
                        arrived = next.arrived
                    }
                    if timedOut {
                        timeouts += 1
                        lines.append("  \(model.info?.fileName ?? "?"): no frame within 2 s")
                        try? await Task.sleep(for: .seconds(dwell))
                        continue
                    }
                    let latency = (arrived - started) * 1000
                    latencies.append(latency)
                    placeholders += showedPlaceholder ? 1 : 0
                    let render = frame.map { Double($0.renderDuration.components.attoseconds) / 1e15 } ?? 0
                    lines.append(String(
                        format: "  %@: %.1f ms (%d×%d frame, %.1f ms render)%@", model.info?.fileName ?? "?", latency,
                        frame?.size.width ?? 0, frame?.size.height ?? 0, render,
                        showedPlaceholder ? " (placeholder shown)" : "",
                    ))
                    try? await Task.sleep(for: .seconds(dwell))
                }
                let sorted = latencies.sorted()
                lines.append(String(
                    format: "%@: %d switches, median %.1f ms, max %.1f ms, placeholder shown %d times, no frame %d times",
                    label, sorted.count, sorted.isEmpty ? 0 : sorted[sorted.count / 2], sorted.last ?? 0, placeholders,
                    timeouts,
                ))
            }
            let report = lines.joined(separator: "\n")
            print(report)
            try? (report + "\n").write(toFile: PerformanceReport.text, atomically: true, encoding: .utf8)
            if LaunchArguments.all.contains("--browse-quit") {
                NSApp.terminate(nil)
            }
        }
    }
#endif
