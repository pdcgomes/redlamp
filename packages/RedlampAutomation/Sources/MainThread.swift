#if DEBUG || REDLAMP_PROFILING
    import CoreFoundation
    import Foundation

    /// Work for the main thread from the driver's own thread.
    ///
    /// A modal loop (a sheet's `NSApp.runModal`, an open panel, an alert) stops main-actor
    /// tasks until it ends, but still runs blocks scheduled in the main run loop's common
    /// modes, so the driver enters the main thread that way and keeps working while a dialog
    /// is up.
    enum MainThread {
        struct Timeout: Error, CustomStringConvertible {
            var seconds: Double
            var description: String {
                "The main thread didn't answer within \(seconds) s"
            }
        }

        private final class Box<T>: @unchecked Sendable {
            var result: Result<T, Error>?
        }

        /// Runs `work` on the main thread and waits for it. Never pass work that can start a
        /// modal loop: use `post` for input, then wait for its effect.
        static func run<T>(timeout: Double = 30, _ work: @escaping @MainActor () throws -> T) throws -> T {
            let box = Box<T>()
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    box.result = Result { try work() }
                }
                return try box.result!.get()
            }
            let done = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    box.result = Result { try work() }
                }
                done.signal()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            guard done.wait(timeout: .now() + timeout) == .success, let result = box.result else {
                throw Timeout(seconds: timeout)
            }
            return try result.get()
        }

        /// Schedules `work` on the main thread without waiting: input that may open a dialog.
        static func post(_ work: @escaping @MainActor () -> Void) {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { work() }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
#endif
