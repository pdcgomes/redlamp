import Darwin
import Dispatch
import Synchronization

/// The process's memory as Activity Monitor and the design's budgets count it: `phys_footprint`,
/// which leaves out clean pages mapped from files, such as the column store's snapshot.
enum Footprint {
    /// Bytes, now; 0 if the kernel doesn't say.
    static func current() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Hands the allocator's free pages back to the system, as `--library-perf`'s trim does.
    static func relieve() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    /// Megabytes, as the budgets give them.
    static func megabytes(_ bytes: Int) -> Double {
        Double(bytes) / 1_048_576
    }
}

/// The highest footprint seen while it runs, sampled every 10 ms.
final class FootprintPeak: @unchecked Sendable {
    /// Touched only here and in `stop`, which cancels it.
    private let timer: any DispatchSourceTimer
    private let peak = Atomic(Footprint.current())

    init() {
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        timer.resume()
    }

    private func sample() {
        _ = peak.max(Footprint.current(), ordering: .relaxed)
    }

    /// Stops sampling and returns the peak, in bytes.
    func stop() -> Int {
        timer.cancel()
        sample()
        return peak.load(ordering: .relaxed)
    }
}
