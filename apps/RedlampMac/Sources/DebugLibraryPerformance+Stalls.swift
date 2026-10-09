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

    /// What changed while a culling step ran: the library's diffs and their rows.
    @MainActor
    final class StepWatch {
        private var diffs = 0
        private var resets = 0
        private var rows = 0
        private var observation: LibraryObservation?

        init(_ library: FolderLibrary) {
            observation = library.observe { [weak self] diff in
                guard let self else { return }
                diffs += 1
                resets += diff.reset ? 1 : 0
                rows += diff.removed.count + diff.inserted.count + diff.updated.count
            }
        }

        var summary: String {
            "\(diffs) diffs (\(resets) resets), \(rows) rows"
        }
    }

    /// Samples the main thread through the turns of its run loop (from waking to waiting again, as
    /// `MainThreadMonitor` counts them) that run longer than half a second, in any phase, and in the phases
    /// given a lower threshold (`sample(over:)`), every turn over it: for the turns no phase's numbers
    /// explain, each one's length, the phase it ran in and where the main thread spent it, and for each
    /// phase, where its long turns went. Nothing may allocate while the main thread is suspended, so samples
    /// go into a preallocated buffer, as `MainThreadSampler`'s do.
    @MainActor
    final class StallSampler {
        /// A turn this long is reported on its own, in any phase.
        nonisolated static let stall: UInt64 = 500_000_000
        /// The samples a phase may take of its turns shorter than a stall.
        static let phaseSamples = 8000
        /// With `--library-perf-profile-turns`, every turn of a phase given a threshold is sampled, every
        /// millisecond from its start, for a profile of the phase's main thread rather than of its long turns'
        /// ends; Instruments and `sample` can't attach to the app from Cursor's sandbox.
        private let profiling = LaunchArguments.all.contains("--library-perf-profile-turns")
        private let samples: Samples
        private let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        private var observer: CFRunLoopObserver?
        private var turn = 0
        private var began: UInt64 = 0
        private var phases: [Phase] = [Phase(name: "starting", threshold: stall)]
        private var stalls: [Stall] = []

        /// A turn longer than `stall`: when it started, in seconds from the start, and its length in milliseconds.
        private struct Stall {
            let turn: Int, start: Double, length: Double, phase: Int
        }

        private struct Phase {
            let name: String
            let threshold: UInt64
            /// Its turns over its threshold, and their time, in milliseconds.
            var turns = 0
            var time = 0.0
        }

        /// What the sampling thread shares with the main thread.
        private final class Samples: @unchecked Sendable {
            static let maxDepth = 96
            let maxSamples: Int
            let interval: useconds_t
            /// Strips pointer-authentication bits from return addresses signed by arm64e system code.
            static let addressMask: UInt = 0x0000_0FFF_FFFF_FFFF
            let mainThread = mach_thread_self()
            let buffer: UnsafeMutablePointer<UInt>
            let depths: UnsafeMutablePointer<Int>
            let turns: UnsafeMutablePointer<Int>
            let phases: UnsafeMutablePointer<Int>
            let count = Atomic<Int>(0)
            let running = Atomic<Bool>(true)
            /// The main thread's turn and phase, when the turn began in nanoseconds of uptime (0 while the
            /// main thread waits), and how long a turn runs before it's sampled.
            let turn = Atomic<Int>(0)
            let phase = Atomic<Int>(0)
            let began = Atomic<UInt64>(0)
            let threshold = Atomic<UInt64>(StallSampler.stall)
            /// The samples the phase may still take of turns shorter than a stall, which always are.
            let budget = Atomic<Int>(0)

            init(profiling: Bool) {
                maxSamples = profiling ? 200_000 : 60000
                interval = profiling ? 1000 : 4000
                buffer = .allocate(capacity: Self.maxDepth * maxSamples)
                depths = .allocate(capacity: maxSamples)
                turns = .allocate(capacity: maxSamples)
                phases = .allocate(capacity: maxSamples)
            }

            /// Runs the calling thread under a real-time policy: on a loaded Mac a sampler preempted while the
            /// main thread is suspended would freeze it, lengthening the turns it measures.
            func runInRealTime() {
                var timebase = mach_timebase_info_data_t()
                mach_timebase_info(&timebase)
                func ticks(_ nanoseconds: Double) -> UInt32 {
                    UInt32(nanoseconds * Double(timebase.denom) / Double(timebase.numer))
                }
                var policy = thread_time_constraint_policy_data_t(
                    period: ticks(Double(interval) * 1000), computation: ticks(150_000), constraint: ticks(400_000),
                    preemptible: 0,
                )
                let count = mach_msg_type_number_t(
                    MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size,
                )
                _ = withUnsafeMutablePointer(to: &policy) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        thread_policy_set(
                            pthread_mach_thread_np(pthread_self()),
                            thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                            $0, count,
                        )
                    }
                }
            }

            func sample(stalled: Bool) {
                let index = count.load(ordering: .relaxed)
                guard index < maxSamples else { return }
                if !stalled {
                    guard budget.load(ordering: .relaxed) > 0 else { return }
                    budget.subtract(1, ordering: .relaxed)
                }
                let (turn, phase) = (turn.load(ordering: .relaxed), phase.load(ordering: .relaxed))
                var state = arm_thread_state64_t()
                var stateCount = mach_msg_type_number_t(
                    MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size,
                )
                guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
                defer { thread_resume(mainThread) }
                let result = withUnsafeMutablePointer(to: &state) {
                    $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                        thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &stateCount)
                    }
                }
                guard result == KERN_SUCCESS else { return }
                let frames = buffer + index * Self.maxDepth
                frames[0] = UInt(state.__pc) & Self.addressMask
                frames[1] = UInt(state.__lr) & Self.addressMask
                var depth = 2
                var fp = UInt(state.__fp)
                while fp != 0, fp & 7 == 0, depth < Self.maxDepth,
                      let frame = UnsafePointer<UInt>(bitPattern: fp) {
                    let next = frame[0]
                    let returnAddress = frame[1] & Self.addressMask
                    guard returnAddress != 0 else { break }
                    frames[depth] = returnAddress
                    depth += 1
                    guard next > fp else { break }
                    fp = next
                }
                depths[index] = depth
                turns[index] = turn
                phases[index] = phase
                count.store(index + 1, ordering: .releasing)
            }
        }

        init() {
            samples = Samples(profiling: profiling)
        }

        /// From now on, turns are reported under `name`, and sampled once they run longer than `threshold`.
        func enter(_ name: String, sampling threshold: Duration? = nil) {
            let nanoseconds = threshold.map {
                profiling ? 0
                    : UInt64($0.components.seconds) * 1_000_000_000 + UInt64($0.components.attoseconds / 1_000_000_000)
            } ?? Self.stall
            phases.append(Phase(name: name, threshold: min(nanoseconds, Self.stall)))
            samples.phase.store(phases.count - 1, ordering: .relaxed)
            samples.threshold.store(min(nanoseconds, Self.stall), ordering: .relaxed)
            samples.budget.store(profiling ? samples.maxSamples : Self.phaseSamples, ordering: .relaxed)
        }

        func start() {
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0,
            ) { [weak self] _, activity in
                MainActor.assumeIsolated { self?.observe(activity) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
            let samples = samples
            let thread = Thread {
                samples.runInRealTime()
                while samples.running.load(ordering: .relaxed) {
                    let began = samples.began.load(ordering: .acquiring)
                    let running = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- began
                    if began != 0, running > samples.threshold.load(ordering: .relaxed) {
                        samples.sample(stalled: running > StallSampler.stall)
                    }
                    usleep(samples.interval)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() {
            samples.running.store(false, ordering: .relaxed)
            if let observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
            observer = nil
        }

        private func observe(_ activity: CFRunLoopActivity) {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if activity == .afterWaiting {
                turn += 1
                began = now
                samples.turn.store(turn, ordering: .relaxed)
                samples.began.store(now, ordering: .releasing)
            } else if began != 0 {
                samples.began.store(0, ordering: .releasing)
                let length = now - began
                let phase = phases.count - 1
                if length > phases[phase].threshold {
                    phases[phase].turns += 1
                    phases[phase].time += Double(length) / 1e6
                }
                if length > Self.stall {
                    stalls.append(Stall(
                        turn: turn,
                        start: Double(began - started) / 1e9,
                        length: Double(length) / 1e6,
                        phase: phase,
                    ))
                }
                began = 0
            }
        }

        /// One line for the report, "N turns over 500 ms, the longest L ms in P", or nil for none.
        var summary: String? {
            guard let longest = stalls.max(by: { $0.length < $1.length }) else { return nil }
            return String(
                format: "Main-thread turns over %.0f ms: %d, the longest %.1f ms in %@, %.1f s after the start",
                Double(Self.stall) / 1e6, stalls.count, longest.length, phases[longest.phase].name, longest.start,
            )
        }

        /// Every turn over half a second, longest first: its phase, when it began and how long it took, and
        /// for the `detailed` longest, the functions its samples were in (Redlamp's, then all of them) and
        /// their commonest stack; then each phase sampled below half a second, its turns over its threshold
        /// and the functions their samples were in. Symbols are mangled.
        func report(detailed: Int = 6) -> String {
            let count = samples.count.load(ordering: .acquiring)
            var byTurn: [Int: [Int]] = [:]
            var byPhase: [String: [Int]] = [:]
            for index in 0 ..< count {
                byTurn[samples.turns[index], default: []].append(index)
                byPhase[phases[samples.phases[index]].name, default: []].append(index)
            }
            var names: [UInt: String] = [:]
            func name(_ address: UInt) -> String {
                if let cached = names[address] {
                    return cached
                }
                var info = Dl_info()
                var resolved = String(format: "0x%lx", address)
                if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                    let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent }
                    let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
                    resolved = "\(symbol)  [\(image ?? "?")]"
                }
                names[address] = resolved
                return resolved
            }
            func profile(_ indices: [Int], stack: Bool) -> [String] {
                var total: [String: Int] = [:]
                var leaf: [String: Int] = [:]
                var stacks: [String: Int] = [:]
                for index in indices {
                    let frames = samples.buffer + index * Samples.maxDepth
                    var seen = Set<String>()
                    var symbols: [String] = []
                    for level in 0 ..< samples.depths[index] where frames[level] > 1 {
                        // Return addresses point after the call; step back into the calling instruction.
                        let symbol = name(level == 0 ? frames[level] : frames[level] - 1)
                        if seen.insert(symbol).inserted {
                            total[symbol, default: 0] += 1
                        }
                        if level == 0 {
                            leaf[symbol, default: 0] += 1
                        }
                        if stack, symbols.count < 48 {
                            symbols.append(symbol)
                        }
                    }
                    if stack {
                        stacks[symbols.joined(separator: "\n      "), default: 0] += 1
                    }
                }
                func table(_ counts: [String: Int], top: Int) -> [String] {
                    counts.sorted { $0.value > $1.value }.prefix(top).map {
                        String(
                            format: "    %5.1f%%  %@",
                            Double($0.value) / Double(max(indices.count, 1)) * 100,
                            $0.key,
                        )
                    }
                }
                var lines = ["  Redlamp's code, inclusive:"] + table(
                    total.filter { $0.key.contains("[Redlamp") },
                    top: 30,
                )
                lines += ["  Everything, inclusive:"] + table(total, top: 40)
                lines += ["  On top of the stack:"] + table(leaf, top: 15)
                if stack, let (common, times) = stacks.max(by: { $0.value < $1.value }) {
                    lines.append("  The commonest stack (\(times) of \(indices.count) samples):\n      " + common)
                }
                return lines
            }
            var lines = [summary ?? "No main-thread turn over \(Double(Self.stall) / 1e6) ms"]
            for (place, stall) in stalls.sorted(by: { $0.length > $1.length }).enumerated() {
                let indices = byTurn[stall.turn] ?? []
                lines.append(String(
                    format: "- %.1f ms in %@, %.1f s after the start: %d samples",
                    stall.length, phases[stall.phase].name, stall.start, indices.count,
                ))
                if place < detailed, !indices.isEmpty {
                    lines += profile(indices, stack: true)
                }
            }
            var sampled: [String: (threshold: UInt64, turns: Int, time: Double)] = [:]
            for phase in phases where phase.threshold < Self.stall {
                let before = sampled[phase.name] ?? (phase.threshold, 0, 0)
                sampled[phase.name] = (phase.threshold, before.turns + phase.turns, before.time + phase.time)
            }
            for (name, phase) in sampled.sorted(by: { $0.value.time > $1.value.time }) {
                let indices = byPhase[name] ?? []
                lines.append(String(
                    format: "Phase %@: %d turns over %.1f ms, %.1f ms in all; %d samples",
                    name, phase.turns, Double(phase.threshold) / 1e6, phase.time, indices.count,
                ))
                if !indices.isEmpty {
                    lines += profile(indices, stack: false)
                }
            }
            if count == samples.maxSamples {
                lines.append("(the sample buffer filled up: later turns have no samples)")
            }
            return lines.joined(separator: "\n")
        }

        /// With `--library-perf-profile-turns`, every stack sampled, a line each: its phase and its frames from
        /// the outermost in, with `;` between them, then how many samples had it: the folded form flame graphs
        /// read. Symbols are mangled. Nil without the flag.
        func folded() -> String? {
            guard profiling else { return nil }
            let count = samples.count.load(ordering: .acquiring)
            var names: [UInt: String] = [:]
            var stacks: [String: Int] = [:]
            for index in 0 ..< count {
                let frames = samples.buffer + index * Samples.maxDepth
                var symbols = [phases[samples.phases[index]].name]
                for level in (0 ..< samples.depths[index]).reversed() where frames[level] > 1 {
                    let address = level == 0 ? frames[level] : frames[level] - 1
                    if let name = names[address] {
                        symbols.append(name)
                        continue
                    }
                    var info = Dl_info()
                    var name = String(format: "0x%lx", address)
                    if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent }
                        name = "\(info.dli_sname.map { String(cString: $0) } ?? "?") [\(image ?? "?")]"
                    }
                    names[address] = name
                    symbols.append(name)
                }
                stacks[symbols.joined(separator: ";"), default: 0] += 1
            }
            return stacks.map { "\($0.key) \($0.value)\n" }.joined()
        }
    }
#endif
