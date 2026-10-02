#if DEBUG || REDLAMP_PROFILING
    import Darwin
    import Foundation
    import Synchronization

    /// Follows the footprint every 5 ms on a thread of its own, so the main thread's statistics stay
    /// clean: each phase's peak and, with breakdowns, a detailed snapshot taken near it.
    final class FootprintWatch: Sendable {
        private struct State {
            var stopped = false
            var peak: UInt64 = 0
            var peakSnapshot: MemorySnapshot?
            var counters: [MemorySnapshot.Counter] = []
        }

        private let state = Mutex(State())
        private let breakdowns: Bool

        init(breakdowns: Bool) {
            self.breakdowns = breakdowns
        }

        func start() {
            let thread = Thread { [self] in
                var lastBreakdown = ContinuousClock.now - .seconds(1)
                while true {
                    let footprint = MemorySnapshot.footprint()
                    let (stopped, nearPeak) = state.withLock { state in
                        state.peak = max(state.peak, footprint)
                        return (state.stopped, state.peakSnapshot?.footprint ?? 0)
                    }
                    if stopped {
                        return
                    }
                    // A new high, 4 MB over the last breakdown: another one, at most every 150 ms.
                    if breakdowns, footprint > nearPeak + (4 << 20),
                       ContinuousClock.now - lastBreakdown > .milliseconds(150) {
                        let snapshot = MemorySnapshot.detailed(counters: state.withLock { $0.counters })
                        lastBreakdown = .now
                        state.withLock { state in
                            if snapshot.footprint > state.peakSnapshot?.footprint ?? 0 {
                                state.peakSnapshot = snapshot
                            }
                        }
                    }
                    usleep(5000)
                }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func stop() {
            state.withLock { $0.stopped = true }
        }

        /// Redlamp's counters as they are now, for breakdowns taken off the main thread.
        func publish(_ counters: [MemorySnapshot.Counter]) {
            state.withLock { $0.counters = counters }
        }

        /// The peak since the last call (and the breakdown taken nearest it), starting a new phase.
        func endPhase() -> (peak: UInt64, snapshot: MemorySnapshot?) {
            let now = MemorySnapshot.footprint()
            return state.withLock { state in
                defer {
                    state.peak = now
                    state.peakSnapshot = nil
                }
                return (max(state.peak, now), state.peakSnapshot)
            }
        }
    }

    /// The footprint through a measurement's phases: the peak while each ran and the memory once it
    /// finished, broken down with `--folders-perf-memory`.
    @MainActor
    final class MemoryPhases {
        struct Phase: Sendable {
            let label: String
            /// The highest footprint while the phase ran, sampled every 5 ms.
            let peak: UInt64
            let after: MemorySnapshot
            /// A breakdown taken near the peak, when it was well above `after`.
            let atPeak: MemorySnapshot?
        }

        let breakdowns: Bool
        private(set) var phases: [Phase] = []
        private let watch: FootprintWatch
        private let counters: @MainActor () -> [MemorySnapshot.Counter]
        private var timer: Timer?

        init(breakdowns: Bool, counters: @escaping @MainActor () -> [MemorySnapshot.Counter]) {
            self.breakdowns = breakdowns
            self.counters = counters
            watch = FootprintWatch(breakdowns: breakdowns)
        }

        func start() {
            watch.start()
            guard breakdowns else { return }
            watch.publish(counters())
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.watch.publish(self.counters())
                }
            }
        }

        func stop() {
            timer?.invalidate()
            watch.stop()
        }

        /// Ends the phase that led here: records its peak and the memory now (broken down off the
        /// main thread, so its statistics stay clean).
        func mark(_ label: String) async {
            let counters = counters()
            let (peak, atPeak) = watch.endPhase()
            let breakdowns = breakdowns
            let after = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: breakdowns
                        ? MemorySnapshot.detailed(counters: counters)
                        : MemorySnapshot.light(counters: counters))
                }
            }
            let useful = atPeak.flatMap { $0.footprint > after.footprint + (8 << 20) ? $0 : nil }
            phases.append(Phase(label: label, peak: max(peak, after.footprint), after: after, atPeak: useful))
            DebugPerformance.trace(String(
                format: "memory: %@ %.0f MB (peak %.0f MB)",
                label,
                mb(after.footprint),
                mb(peak),
            ))
        }

        var baseline: UInt64 {
            phases.first?.after.footprint ?? 0
        }

        /// The highest footprint over every phase after the first, exact when it was a new high since
        /// launch (the kernel keeps that), otherwise as sampled.
        var peak: UInt64 {
            let sampled = phases.dropFirst().map(\.peak).max() ?? 0
            let lifetime = phases.last?.after.ledgers.lifetimePeak ?? 0
            let atStart = phases.first?.after.ledgers.lifetimePeak ?? 0
            return lifetime > atStart ? max(lifetime, sampled) : sampled
        }

        /// One line for the performance report.
        func summary() -> String {
            "Footprint by phase: " + phases.map { phase in
                let peak = phase.peak > phase.after.footprint + (4 << 20) ? String(
                    format: " (peak %.0f)",
                    mb(phase.peak),
                ) : ""
                return String(format: "%@ %.0f%@", phase.label, mb(phase.after.footprint), peak)
            }.joined(separator: ", ") + " MB"
        }

        // MARK: - The report

        /// A table of every phase (and the breakdowns near the peaks), by category, in MB.
        func report(title: String, notes: [String]) -> String {
            Self.table(phases, breakdowns: breakdowns, title: title, notes: notes)
        }

        private nonisolated static func table(
            _ phases: [Phase], breakdowns: Bool, title: String, notes: [String],
        ) -> String {
            var columns: [(String, MemorySnapshot)] = []
            for phase in phases {
                if let atPeak = phase.atPeak {
                    columns.append(("\(phase.label)^", atPeak))
                }
                columns.append((phase.label, phase.after))
            }
            let base = phases.first?.after
            var rows: [(label: String, cells: [String])] = []
            func add(_ label: String, _ value: (MemorySnapshot) -> Double?) {
                rows.append((label, columns.map { value($0.1).map { String(format: "%.1f", $0) } ?? "" }))
            }
            func section(_ label: String) {
                rows.append((label, []))
            }
            add("Footprint (phys_footprint)") { mb($0.footprint) }
            add("  over the first column") { snapshot in base.map { mb(snapshot.footprint) - mb($0.footprint) } }
            section("Kernel ledgers")
            add("  anonymous, resident") { mb($0.ledgers.anonymous) }
            add("  anonymous, compressed") { mb($0.ledgers.compressed) }
            add("  GPU (graphics ledger)") { mb($0.ledgers.graphics) }
            if phases.contains(where: { $0.after.ledgers.media + $0.after.ledgers.neural > 0 }) {
                add("  media and neural engine") { mb($0.ledgers.media + $0.ledgers.neural) }
            }
            add("  purgeable, non-volatile") { mb($0.ledgers.purgeableNonvolatile) }
            add("  purgeable, volatile (not counted)") { mb($0.ledgers.purgeableVolatile) }
            add("  reusable (not counted)") { mb($0.ledgers.reusable) }
            if breakdowns {
                section("Regions: dirty + compressed")
                let shown = MemoryCategory.allCases.filter { category in
                    columns.contains { ($0.1.categories[category]?.footprint ?? 0) >= 1 << 19 }
                }
                for category in shown {
                    add("  \(category.rawValue)") { $0.isDetailed ? mb($0.categories[category]?.footprint ?? 0) : nil }
                }
                add("  all regions") { $0.isDetailed ? mb($0.regionsFootprint) : nil }
                add("  not in a region*") { snapshot in
                    snapshot.isDetailed ? mb(snapshot.footprint) - mb(snapshot.regionsFootprint) : nil
                }
                section("malloc")
                add("  in live blocks") { $0.isDetailed ? mb($0.mallocInUse) : nil }
                add("  held for reuse (regions - live)") { snapshot in
                    snapshot.isDetailed ? mb(snapshot.mallocFootprint) - mb(snapshot.mallocInUse) : nil
                }
            }
            section("Redlamp")
            for (index, counter) in (phases.first?.after.counters ?? []).enumerated() {
                let label = counter.isBytes ? "  \(counter.label), MB" : "  \(counter.label)"
                add(label) { snapshot in
                    guard index < snapshot.counters.count else { return nil }
                    let value = snapshot.counters[index]
                    return value.isBytes ? value.value / 1_048_576 : value.value
                }
            }
            if breakdowns {
                add("Region walk, ms") { $0.isDetailed ? $0.walkSeconds * 1000 : nil }
            }

            let labelWidth = max(rows.map(\.label.count).max() ?? 0, 10) + 2
            let width = max(columns.map(\.0.count).max() ?? 0, 7) + 2
            var lines = [title, ""]
            lines.append(pad("MB", labelWidth, left: true) + columns.map { pad($0.0, width) }.joined())
            for row in rows {
                lines.append(pad(row.label, labelWidth, left: true) + row.cells.map { pad($0, width) }.joined())
            }
            lines.append("")
            lines.append("^ a breakdown taken during the phase, near its peak (within 4 MB or 150 ms).")
            if breakdowns {
                lines.append(
                    "* GPU memory not mapped into the process (in the graphics ledger), page tables and IOKit memory.",
                )
                if let highest = columns.max(by: { $0.1.footprint < $1.1.footprint }) {
                    lines += details(highest.1, label: highest.0)
                }
            }
            return (lines + notes).joined(separator: "\n")
        }

        /// The tags and malloc zones of one breakdown.
        private nonisolated static func details(_ snapshot: MemorySnapshot, label: String) -> [String] {
            var lines = ["", "Anonymous regions by tag at the highest column (\(label)), MB:"]
            for (tag, pages) in snapshot.tags.sorted(by: { $0.value.footprint > $1.value.footprint }).prefix(16)
                where pages.footprint >= 1 << 19 {
                lines.append(pad("  " + MemoryCategory.name(ofTag: tag), 30, left: true) + String(
                    format: "%7.1f   (resident %.1f, compressed %.1f)",
                    mb(pages.footprint), mb(pages.resident), mb(pages.compressed),
                ))
            }
            lines.append("malloc zones at \(label):")
            for zone in snapshot.zones {
                lines.append(pad("  " + zone.name, 30, left: true) + String(
                    format: "%7.1f in use in %d blocks, %.1f allocated",
                    mb(zone.inUse), zone.blocks, mb(zone.allocated),
                ))
            }
            return lines
        }
    }

    /// The memory budgets for browsing folders, in MB over the footprint at launch (see "Memory
    /// budgets" in docs/plans/2026-10-02-folders-design.md). Measured on 50,000 photos: peak 150 to
    /// 177, settled 142 to 170, after a trim and idle 49 to 68, listed 1 KB a photo.
    enum MemoryBudget {
        /// The highest footprint while opening, decoding, warming, reading the pack and scrolling.
        static let peak = 200.0
        /// Once listed: the photos themselves, 1.2 KB each.
        static func listed(_ count: Int) -> Double {
            Double(count) * 1200 / 1_048_576
        }

        /// Browsing paused, without memory pressure: the photos and a full thumbnail LRU.
        static let settled = 180.0
        /// After a memory-pressure warning: the photos and what's on screen.
        static let trimmed = 80.0
        /// Then idle for a few seconds.
        static let idle = 80.0
    }

    /// A target and whether the run met it.
    struct Budget {
        let name: String
        let measured: String
        let target: String
        let passed: Bool

        var line: String {
            let padded = name.count < 50 ? name + String(repeating: " ", count: 50 - name.count) : name
            return "  \(passed ? "PASS" : "FAIL")  \(padded) \(measured) (\(target))"
        }

        static func below(_ name: String, _ value: Double, _ limit: Double, unit: String) -> Budget {
            Budget(
                name: name, measured: String(format: "%.1f %@", value, unit),
                target: "under \(number(limit)) \(unit)", passed: value < limit,
            )
        }

        static func atLeast(_ name: String, _ value: Double, _ limit: Double, unit: String) -> Budget {
            Budget(
                name: name, measured: String(format: "%.0f %@", value, unit),
                target: "at least \(number(limit)) \(unit)", passed: value >= limit,
            )
        }

        private static func number(_ value: Double) -> String {
            String(format: value.rounded() == value ? "%.0f" : "%.1f", value)
        }
    }

    private func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let space = String(repeating: " ", count: max(width - text.count, 0))
        return left ? text + space : space + text
    }
#endif
