#if DEBUG || REDLAMP_PROFILING
    import Darwin
    import Foundation
    import Synchronization

    /// With `REDLAMP_TURN_PROFILE` set, the main thread's stacks sampled every half millisecond through each phase
    /// `watchingMainThread` watches, and what its turns over a frame (8.3 ms) were busy in, written to the run's
    /// `turn-profile-<phase>.txt`: each such turn with the calls on most of its samples that aren't on nearly every
    /// busy sample, then the functions on the slow turns' samples and the innermost of them, against every busy
    /// sample's. A phase's whole profile is mostly its cheap, frequent turns; its p99 is its slow ones.
    final class SlowTurnProfile: @unchecked Sendable {
        private let thread: thread_act_t
        private let running = Mutex(true)
        private let samples = Mutex<[(time: CFAbsoluteTime, stack: [UInt])]>([])
        private let finished = DispatchSemaphore(value: 0)

        static var isOn: Bool {
            ProcessInfo.processInfo.environment["REDLAMP_TURN_PROFILE"] != nil
        }

        /// A turn longer than this is slow.
        static let slow = 8.3

        init(thread: thread_act_t) {
            self.thread = thread
            let sampler = Thread { [self] in
                while running.withLock({ $0 }) {
                    let time = CFAbsoluteTimeGetCurrent()
                    let stack = sample()
                    if !stack.isEmpty {
                        samples.withLock { $0.append((time, stack)) }
                    }
                    usleep(500)
                }
                finished.signal()
            }
            sampler.qualityOfService = .userInteractive
            sampler.start()
        }

        /// Stops sampling and writes what the turns of `starts` and `durations` (`MainThreadMonitor`'s) over `slow`
        /// were busy in.
        func write(to url: URL, phase: String, starts: [CFAbsoluteTime], durations: [Double]) {
            running.withLock { $0 = false }
            finished.wait()
            let all = samples.withLock { $0 }.sorted { $0.time < $1.time }
            var names: [UInt: String] = [:]
            func name(_ address: UInt) -> String {
                if let known = names[address] {
                    return known
                }
                var info = Dl_info()
                let found = dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0
                    ? info.dli_sname.map { Self.demangled(String(cString: $0)) } : nil
                let named = found ?? String(format: "0x%lx", address)
                names[address] = named
                return named
            }
            let symbolled = all.map { (time: $0.time, symbols: $0.stack.map(name)) }
            // Waiting in the run loop for the next event isn't work.
            let busy = symbolled.filter { !$0.symbols.prefix(4).contains { $0.contains("mach_msg") } }
            var everywhere: [String: Int] = [:]
            for sample in busy {
                for symbol in Set(sample.symbols) {
                    everywhere[symbol, default: 0] += 1
                }
            }
            let slowTurns = zip(starts, durations).filter { $0.1 > Self.slow }
                .map { (start: $0.0, end: $0.0 + $0.1 / 1000, milliseconds: $0.1) }
            var (inclusive, innermost, sampled) = ([String: Int](), [String: Int](), 0)
            var turnLines: [String] = []
            for turn in slowTurns.sorted(by: { $0.milliseconds > $1.milliseconds }) {
                let inside = busy.filter { $0.time >= turn.start && $0.time <= turn.end }
                sampled += inside.count
                var counts: [String: Int] = [:]
                for sample in inside {
                    for symbol in Set(sample.symbols) {
                        counts[symbol, default: 0] += 1
                        inclusive[symbol, default: 0] += 1
                    }
                    if let leaf = sample.symbols.first {
                        innermost[leaf, default: 0] += 1
                    }
                }
                // Which of the display cycle's steps it was in, and Redlamp's own calls on a fifth of it or more.
                let steps = Self.steps.compactMap { step, marker -> String? in
                    let count = counts.first { $0.key.contains(marker) }?.value ?? 0
                    return count == 0 ? nil : "\(step) \(count)"
                }
                let own = counts.filter { symbol, count in
                    symbol.contains("Redlamp") && count * 5 >= inside.count
                }.sorted { $0.value > $1.value }.prefix(6).map { "\(Self.short($0.key)) (\($0.value))" }
                turnLines.append(String(
                    format: "%.1f ms at +%.3f s, %d samples: ", turn.milliseconds, turn.start - (starts.first ?? 0),
                    inside.count,
                ) + steps.joined(separator: ", ") + (own.isEmpty ? "" : "; ") + own.joined(separator: "; "))
            }
            func ranked(_ counts: [String: Int], _ count: Int) -> [String] {
                counts.sorted { $0.value > $1.value }.prefix(count).map { "\($0.value)\t\($0.key)" }
            }
            let slowSamples = busy.filter { sample in
                slowTurns.contains { sample.time >= $0.start && sample.time <= $0.end }
            }
            let lines = [
                "\(phase): \(durations.count) turns, \(slowTurns.count) over \(Self.slow) ms "
                    + String(format: "(%.1f ms in all)", slowTurns.reduce(0) { $0 + $1.milliseconds })
                    + ", \(busy.count) busy samples of \(all.count), \(sampled) in the slow turns",
                "", "The slow turns, the slowest first:",
            ] + turnLines + ["", "The slow turns' calls, outermost first, those on 1% of their samples or more:"]
                + Self.tree(slowSamples.map(\.symbols)) + ["", "In the slow turns, by samples:"] + ranked(
                    inclusive,
                    200,
                )
                + ["", "Innermost in the slow turns:"] + ranked(innermost, 80)
                + ["", "Every busy sample, by the functions on them:"] + ranked(everywhere, 150)
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        /// `stacks` (innermost first) as a call tree, each call under its caller with the samples it's on, those on
        /// less than 1% of them left out.
        private static func tree(_ stacks: [[String]]) -> [String] {
            final class Node {
                var count = 0
                var children: [String: Node] = [:]
            }
            let root = Node()
            for stack in stacks {
                var node = root
                // The return address in the link register repeats the caller of the innermost frame.
                var previous: String?
                for symbol in stack.reversed() where symbol != previous {
                    previous = symbol
                    let child = node.children[symbol] ?? Node()
                    node.children[symbol] = child
                    child.count += 1
                    node = child
                }
            }
            let least = max(stacks.count / 100, 1)
            var lines: [String] = []
            /// A call with one callee shown keeps its indent, so a chain reads down the page; the callees of a call
            /// with several are indented under it, each marked where it starts.
            func walk(_ node: Node, depth: Int) {
                let shown = node.children.sorted(by: { $0.value.count > $1.value.count })
                    .filter { $0.value.count >= least }
                for (symbol, child) in shown {
                    let branch = shown.count > 1
                    let indent = String(repeating: "  ", count: min(depth + (branch ? 1 : 0), 40))
                    lines.append(indent + (branch ? "• " : "") + "\(child.count)\t\(short(symbol))")
                    walk(child, depth: depth + (branch ? 1 : 0))
                }
            }
            walk(root, depth: 0)
            return lines
        }

        /// The steps a slow turn is told by, each by a call only it makes.
        private static let steps = [
            ("event", "sendEvent:"), ("timer", "__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__"),
            ("main queue", "SERVICING_THE_MAIN_DISPATCH_QUEUE"), ("animation", "NSAnimationManager performAnimations"),
            ("constraints", "updateConstraintsIfNeeded"), ("layout", "_layoutViewTree"),
            ("tracking areas", "displayCycleUpdateStructuralRegions"), ("display", "-[NSWindow displayIfNeeded]"),
            ("SwiftUI", "ViewGraphRootValueUpdater._updateViewGraph"), ("commit", "commit_transaction"),
        ]

        private static func short(_ symbol: String) -> String {
            symbol.count > 160 ? String(symbol.prefix(160)) + "…" : symbol
        }

        private typealias Demangle = @convention(c) (
            UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32,
        ) -> UnsafeMutablePointer<CChar>?

        private static let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
            .map { unsafeBitCast($0, to: Demangle.self) }

        private static func demangled(_ symbol: String) -> String {
            guard let demangle, symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return symbol }
            let bare = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
            return bare.withCString { mangled in
                guard let result = demangle(mangled, strlen(mangled), nil, nil, 0) else { return symbol }
                defer { free(result) }
                return String(cString: result)
            }
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
#endif
