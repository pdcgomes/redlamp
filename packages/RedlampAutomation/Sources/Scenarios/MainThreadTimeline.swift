#if DEBUG || REDLAMP_PROFILING
    import CoreFoundation
    import Darwin
    import Foundation
    import Synchronization

    /// The main thread over a stretch of a scenario, on one clock: its stack every half a millisecond, its run loop
    /// entering and leaving each mode, and marks the driver and the app put down, so a measurement can say what the
    /// main thread did between two of them, and in which run loop (ARC-07).
    public final class MainThreadTimeline: @unchecked Sendable {
        private struct Sample {
            var time: ContinuousClock.Instant
            var stack: [UInt]
            /// The main run loop's mode just after the sample.
            var mode: String
        }

        /// Frames read from each stack: a menu tracking inside a press, and a sheet begun in it, go deep.
        private static let depth = 400

        private let thread: thread_act_t
        private let running = Mutex(true)
        private let samples = Mutex<[Sample]>([])
        private let marks = Mutex<[(time: ContinuousClock.Instant, text: String)]>([])
        /// Only touched on main.
        private var observer: CFRunLoopObserver?
        let start = ContinuousClock.now

        init(thread: thread_act_t) {
            self.thread = thread
            Thread { [self] in
                while running.withLock({ $0 }) {
                    let stack = sample()
                    let time = ContinuousClock.now
                    // Only once the thread runs again: it may hold the run loop's lock.
                    let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String } ?? "none"
                    if !stack.isEmpty {
                        samples.withLock { $0.append(Sample(time: time, stack: stack, mode: mode)) }
                    }
                    usleep(500)
                }
            }.start()
        }

        /// Marks each time the main run loop enters or leaves a mode, and each time it waits and wakes.
        @MainActor func watchRunLoop() {
            let activities: CFRunLoopActivity = [.entry, .exit, .beforeWaiting, .afterWaiting]
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, CFIndex.min) {
                [weak self] _, activity in
                let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String } ?? "no mode"
                let what = switch activity {
                case .entry: "run loop entered \(mode)"
                case .exit: "run loop left \(mode)"
                case .beforeWaiting: "waits in \(mode)"
                default: "wakes in \(mode)"
                }
                self?.mark(what)
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        func mark(_ text: String, at time: ContinuousClock.Instant = .now) {
            marks.withLock { $0.append((time, text)) }
        }

        @MainActor func stop() {
            running.withLock { $0 = false }
            if let observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
            observer = nil
        }

        /// Milliseconds from the timeline's start.
        func offset(_ time: ContinuousClock.Instant) -> Double {
            let parts = (time - start).components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }

        /// The marks in order, then for each of `windows` what ran on the main thread in it, in order, and the
        /// functions on the most of its samples.
        func write(to url: URL, windows: [(name: String, from: ContinuousClock.Instant, to: ContinuousClock.Instant)]) {
            running.withLock { $0 = false }
            let all = samples.withLock { $0 }
            var lines = ["Marks, in ms from the timeline's start (\(all.count) samples of the main thread):"]
            var waits = 0
            for mark in marks.withLock({ $0 }).sorted(by: { $0.time < $1.time }) {
                // Turns in the default mode are many: only those in other modes and the entries and exits.
                if mark.text.hasPrefix("waits in kCFRunLoopDefaultMode")
                    || mark.text.hasPrefix("wakes in kCFRunLoopDefaultMode") {
                    waits += 1
                    continue
                }
                lines.append(String(format: "%9.2f  %@", offset(mark.time), mark.text))
            }
            lines.append("(\(waits) waits and wakes in the default mode left out)")
            var names: [UInt: String] = [:]
            func name(_ address: UInt) -> String {
                if let known = names[address] {
                    return known
                }
                var info = Dl_info()
                let found = dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0
                    ? info.dli_sname.map { Self.demangle(String(cString: $0)) } : nil
                names[address] = found ?? String(format: "0x%lx", address)
                return names[address] ?? ""
            }
            for window in windows {
                let inside = all.filter { $0.time >= window.from && $0.time <= window.to }
                lines += ["", String(
                    format: "%@: %.2f to %.2f ms, %d samples", window.name, offset(window.from), offset(window.to),
                    inside.count,
                )]
                var runs: [(from: Double, to: Double, what: String, count: Int)] = []
                var counts: [String: Int] = [:]
                for sample in inside {
                    let symbols = sample.stack.map(name)
                    let mode = sample.mode.replacingOccurrences(of: "RunLoopMode", with: "")
                    let what = "[\(mode)] " + Self.describe(symbols)
                    let time = offset(sample.time)
                    if let last = runs.last, last.what == what {
                        runs[runs.count - 1].to = time
                        runs[runs.count - 1].count += 1
                    } else {
                        runs.append((time, time, what, 1))
                    }
                    if !what.contains("] waiting") {
                        for symbol in Set(symbols) {
                            counts[symbol, default: 0] += 1
                        }
                    }
                }
                lines.append("  What ran, in order:")
                lines += runs.map { String(format: "  %9.2f to %9.2f (%3d)  %@", $0.from, $0.to, $0.count, $0.what) }
                lines.append("  Functions on the most busy samples:")
                lines += counts.sorted { $0.value > $1.value }.prefix(60).map { "  \($0.value)\t\($0.key)" }
            }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        /// A sample in a line: waiting in the run loop, or the callout of the innermost run loop and the five frames
        /// under it that aren't the run loop's or the queues' own, with how many run loops deep it is.
        private static func describe(_ symbols: [String]) -> String {
            let depth = symbols.count { $0 == "__CFRunLoopRun" }
            if symbols.prefix(4).contains(where: { $0.contains("mach_msg") }) {
                return "waiting, \(depth) run loop\(depth == 1 ? "" : "s") deep"
            }
            guard let callout = symbols.firstIndex(where: { $0.hasPrefix("__CFRUNLOOP_IS_") }) else {
                return "outside a run loop: " + symbols.prefix(6).joined(separator: " < ")
            }
            let skipped = ["_dispatch", "dispatch_", "swift_job", "swift::", "_CF", "CFRunLoop", "__CFRunLoop"]
            let under = symbols[..<callout].reversed().filter { symbol in
                !skipped.contains { symbol.hasPrefix($0) }
            }.prefix(5)
            let kind = symbols[callout].replacingOccurrences(of: "__CFRUNLOOP_IS_", with: "")
                .replacingOccurrences(of: "_FUNCTION__", with: "").replacingOccurrences(of: "__", with: "")
            return "\(depth) deep, \(kind): " + under.joined(separator: " > ")
        }

        @_silgen_name("swift_demangle")
        private static func swiftDemangle(
            _ mangled: UnsafePointer<CChar>?, _ length: UInt, _ buffer: UnsafeMutablePointer<CChar>?,
            _ size: UnsafeMutablePointer<UInt>?, _ flags: UInt32,
        ) -> UnsafeMutablePointer<CChar>?

        static func demangle(_ symbol: String) -> String {
            guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return symbol }
            let name = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
            guard let demangled = name.withCString({ swiftDemangle($0, UInt(strlen($0)), nil, nil, 0) }) else {
                return symbol
            }
            defer { free(demangled) }
            let text = String(cString: demangled)
            return text.count > 140 ? String(text.prefix(140)) + "…" : text
        }

        private func sample() -> [UInt] {
            var state = arm_thread_state64_t()
            var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
            var addresses: [UInt] = []
            // Nothing may allocate while the thread is suspended: it may hold the allocator's lock.
            addresses.reserveCapacity(Self.depth + 2)
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
                while fp != 0, fp & 7 == 0, addresses.count < Self.depth,
                      let frame = UnsafePointer<UInt>(bitPattern: fp) {
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
