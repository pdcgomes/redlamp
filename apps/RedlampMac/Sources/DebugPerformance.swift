#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import CoreFoundation
    import Foundation
    import RedlampEngineAPI
    import RedlampUI
    import Synchronization

    /// Measures how long each main run-loop iteration keeps the main thread busy. A slider
    /// drag feels smooth only if iterations stay well under one display frame (8.3 ms at 120 Hz).
    @MainActor
    final class MainThreadMonitor {
        private var observer: CFRunLoopObserver?
        private var iterationStart: CFAbsoluteTime = 0
        private(set) var durations: [Double] = []

        func start() {
            durations.removeAll()
            let observer = CFRunLoopObserverCreateWithHandler(
                nil,
                CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                true,
                0,
            ) { [weak self] _, activity in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    if activity == .afterWaiting {
                        self.iterationStart = now
                    } else if self.iterationStart > 0 {
                        self.durations.append((now - self.iterationStart) * 1000)
                        self.iterationStart = 0
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        func stop() {
            if let observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
            observer = nil
        }

        func report(_ label: String, seconds: Double) -> String {
            let sorted = durations.sorted()
            guard !sorted.isEmpty else { return "\(label): no samples" }
            func percentile(_ p: Double) -> Double {
                sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
            }
            let busy = sorted.reduce(0, +)
            return String(
                format: "%@: %d iterations, busy %.0f%% of %.1fs, p50 %.2f ms, p95 %.2f ms, p99 %.2f ms, max %.1f ms, >8.3 ms: %d, >16.7 ms: %d",
                label, sorted.count, busy / (seconds * 1000) * 100, seconds,
                percentile(0.5), percentile(0.95), percentile(0.99), sorted.last ?? 0,
                sorted.count(where: { $0 > 8.3 }), sorted.count(where: { $0 > 16.7 }),
            )
        }
    }

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
                for level in 0 ..< depth {
                    // Return addresses point after the call; step back into the calling instruction.
                    let symbol = name(level == 0 ? frames[level] : frames[level] - 1)
                    if seen.insert(symbol).inserted {
                        totalCounts[symbol, default: 0] += 1
                    }
                    if let focus, focusedCallee == nil, symbol.contains(focus), level > 0 {
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

    /// `--sweep <parameter> [--sweep-seconds 3]`: drags a slider at 120 Hz (like a trackpad),
    /// then writes main-thread and frame statistics to /tmp/redlamp-perf.txt.
    @MainActor
    enum DebugPerformance {
        static func scheduleIfRequested(model: EditorModel) {
            let arguments = LaunchArguments.all
            trace("launched with \(arguments.dropFirst().joined(separator: " "))")
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
            guard let index = arguments.firstIndex(of: "--sweep"), index + 1 < arguments.count,
                  let parameter = ParameterID.allCases.first(where: { arguments[index + 1] == "\($0)" })
            else { return }
            let seconds = arguments.firstIndex(of: "--sweep-seconds").flatMap { Double(arguments[$0 + 1]) } ?? 3

            Task { @MainActor in
                trace("sweep scheduled")
                while model.info == nil || model.isLoading {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                trace("image ready")
                try? await Task.sleep(for: .seconds(1.5))
                await sweep(parameter, seconds: seconds, model: model)
            }
        }

        static func trace(_ message: String) {
            let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
            if let handle = FileHandle(forWritingAtPath: "/tmp/redlamp-debug.log") {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: "/tmp/redlamp-debug.log", atomically: true, encoding: .utf8)
            }
        }

        private static func sweep(_ parameter: ParameterID, seconds: Double, model: EditorModel) async {
            trace("sweep start")
            defer { trace("sweep end") }
            let monitor = MainThreadMonitor()
            let spec = parameter.spec
            let framesBefore = model.debugFrameCount
            let sampler = LaunchArguments.all.contains("--sweep-profile") ? MainThreadSampler() : nil
            sampler?.start()
            monitor.start()
            model.beginEdit(parameter)
            let started = CFAbsoluteTimeGetCurrent()
            var events = 0
            while CFAbsoluteTimeGetCurrent() - started < seconds {
                let t = (CFAbsoluteTimeGetCurrent() - started) / seconds
                let position = 0.5 + 0.35 * sin(t * .pi * 4)
                model.setSliderValue(parameter, spec.value(atPosition: position))
                events += 1
                try? await Task.sleep(for: .microseconds(8333))
            }
            model.endEdit()
            try? await Task.sleep(for: .milliseconds(300))
            monitor.stop()
            sampler?.stop()
            if let sampler {
                try? await Task.sleep(for: .milliseconds(20))
                let arguments = LaunchArguments.all
                let focus = arguments.firstIndex(of: "--sweep-profile-focus").flatMap {
                    $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
                }
                try? sampler.report(focus: focus).write(
                    toFile: "/tmp/redlamp-profile.txt",
                    atomically: true,
                    encoding: .utf8,
                )
            }

            let frames = model.debugFrameCount - framesBefore
            let report = [
                monitor.report("main thread during \(spec.label) sweep", seconds: seconds),
                String(
                    format: "slider events: %d (%.0f/s), frames received: %d (%.0f/s)",
                    events,
                    Double(events) / seconds,
                    frames,
                    Double(frames) / seconds,
                ),
            ].joined(separator: "\n")
            print(report)
            try? (report + "\n").write(toFile: "/tmp/redlamp-perf.txt", atomically: true, encoding: .utf8)
            if LaunchArguments.all.contains("--sweep-quit") {
                NSApp.terminate(nil)
            }
        }

        /// `--browse [--browse-dwell 0.5]`: steps forward through every photo, then back, pausing
        /// `dwell` seconds on each like someone pressing the arrow keys. For each step, records
        /// the time from selection to the new photo's first frame and whether the placeholder
        /// (thumbnail and spinner) was shown.
        private static func browse(dwell: Double, model: EditorModel) async {
            var lines: [String] = []
            let count = model.items.count
            for (label, offset) in [("forward, first visit", 1), ("back, revisit", -1)] {
                var latencies: [Double] = []
                var placeholders = 0
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
                    while model.debugFrameCount == framesBefore {
                        frame = await model.frames.nextFrame()
                        arrived = CFAbsoluteTimeGetCurrent()
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
                    format: "%@: %d switches, median %.1f ms, max %.1f ms, placeholder shown %d times",
                    label, sorted.count, sorted.isEmpty ? 0 : sorted[sorted.count / 2], sorted.last ?? 0, placeholders,
                ))
            }
            let report = lines.joined(separator: "\n")
            print(report)
            try? (report + "\n").write(toFile: "/tmp/redlamp-perf.txt", atomically: true, encoding: .utf8)
            if LaunchArguments.all.contains("--browse-quit") {
                NSApp.terminate(nil)
            }
        }
    }
#endif
