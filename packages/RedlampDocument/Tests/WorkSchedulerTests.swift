import Foundation
import Synchronization
import Testing
@testable import RedlampDocument

struct WorkSchedulerTests {
    /// A gate jobs wait on, so a test decides when they finish.
    private final class Gate: Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func wait() {
            semaphore.wait()
        }

        func open(_ count: Int = 1) {
            for _ in 0 ..< count {
                semaphore.signal()
            }
        }
    }

    private final class Flag: Sendable {
        private let state = Mutex(false)

        var value: Bool {
            state.withLock { $0 }
        }

        func set() {
            state.withLock { $0 = true }
        }
    }

    /// Sets its flag when it goes.
    private final class Watched: Sendable {
        let gone: Flag

        init(gone: Flag) {
            self.gone = gone
        }

        deinit {
            gone.set()
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `what a job autoreleases goes when the job ends, while the lane stays busy`() async throws {
        let scheduler = WorkScheduler(widths: .init(onScreen: 1, lookAhead: 1, background: 1))
        let gone = Flag()
        let goneWhenNextStarted = Mutex<Bool?>(nil)
        scheduler.submit(.onScreen) {
            _ = Unmanaged.passRetained(Watched(gone: gone)).autorelease()
        }
        scheduler.submit(.onScreen) {
            goneWhenNextStarted.withLock { $0 = gone.value }
        }
        try await eventually { goneWhenNextStarted.withLock { $0 } != nil }
        #expect(goneWhenNextStarted.withLock { $0 } == true)
    }

    @Test func `a lane runs no more jobs at once than its width`() async throws {
        let scheduler = WorkScheduler(widths: .init(onScreen: 2, lookAhead: 1, background: 1))
        let gate = Gate()
        let running = Atomic(0)
        let peak = Atomic(0)
        let finished = Atomic(0)
        for _ in 0 ..< 6 {
            scheduler.submit(.onScreen) {
                let now = running.add(1, ordering: .relaxed).newValue
                _ = peak.max(now, ordering: .relaxed)
                gate.wait()
                running.subtract(1, ordering: .relaxed)
                finished.add(1, ordering: .relaxed)
            }
        }
        try await eventually { scheduler.load().running[.onScreen] == 2 }
        #expect(scheduler.load().waiting[.onScreen] == 4)
        gate.open(6)
        try await eventually { finished.load(ordering: .relaxed) == 6 }
        let highest = peak.load(ordering: .relaxed)
        #expect(highest == 2)
    }

    @Test func `a promoted job runs before the ones it overtook`() async throws {
        let scheduler = WorkScheduler(widths: .init(onScreen: 1, lookAhead: 1, background: 1))
        let gate = Gate()
        let order = Mutex<[String]>([])
        scheduler.submit(.lookAhead) { gate.wait() }
        try await eventually { scheduler.load().running[.lookAhead] == 1 }
        for name in ["a", "b", "c"] {
            scheduler.submit(.lookAhead, key: name) { order.withLock { $0.append(name) } }
        }
        scheduler.promote("c", to: .onScreen)
        try await eventually { !order.withLock { $0 }.isEmpty }
        #expect(order.withLock { $0 } == ["c"], "c ran while the look-ahead lane was still busy")
        gate.open()
        try await eventually { order.withLock { $0.count } == 3 }
        #expect(order.withLock { $0 } == ["c", "a", "b"])
    }

    @Test func `a cancelled job never runs, and says so`() async throws {
        let scheduler = WorkScheduler(widths: .init(onScreen: 1, lookAhead: 1, background: 1))
        let gate = Gate()
        let ran = Flag()
        let cancelled = Flag()
        scheduler.submit(.onScreen) { gate.wait() }
        scheduler.submit(.onScreen, key: "thumb:a", onCancel: { cancelled.set() }, { ran.set() })
        scheduler.cancel(prefix: "thumb:")
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ran.value)
        #expect(cancelled.value)
    }

    @Test func `run returns the job's result, and a cancelled caller drops the job`() async throws {
        let scheduler = WorkScheduler(widths: .init(onScreen: 1, lookAhead: 1, background: 1))
        #expect(try await scheduler.run(.lookAhead) { 6 * 7 } == 42)

        let gate = Gate()
        scheduler.submit(.onScreen) { gate.wait() }
        let ran = Flag()
        let task = Task { try await scheduler.run(.onScreen) { ran.set() } }
        try await eventually { scheduler.load().waiting[.onScreen] == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ran.value)
    }

    @Test func `background work waits while anything on screen does`() async throws {
        let scheduler = WorkScheduler(widths: .init(onScreen: 1, lookAhead: 1, background: 2))
        let gate = Gate()
        let background = Flag()
        scheduler.submit(.onScreen) { gate.wait() }
        scheduler.submit(.onScreen) { gate.wait() }
        scheduler.submit(.background) { background.set() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!background.value, "an on-screen job is still waiting")
        gate.open(2)
        try await eventually { background.value }
        #expect(background.value)
    }

    @Test func `background work pauses while the Mac is hot or saving power`() async throws {
        let relaxed = Flag()
        let scheduler = WorkScheduler(
            widths: .init(onScreen: 1, lookAhead: 1, background: 1),
            canRunBackground: { relaxed.value },
        )
        let ran = Flag()
        scheduler.submit(.background) { ran.set() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ran.value)
        relaxed.set()
        scheduler.submit(.onScreen) {}
        try await eventually { ran.value }
        #expect(ran.value)
    }

    @Test func `the machine's widths follow its cores`() {
        let widths = WorkScheduler.Widths.machine
        #expect(widths.onScreen == CoreCounts.performance)
        #expect(widths.onScreen >= 1 && widths.lookAhead >= 2 && widths.background >= 2)
    }
}
