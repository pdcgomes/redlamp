#if DEBUG || REDLAMP_PROFILING
    import Darwin
    import Foundation
    import RedlampServices
    import Synchronization

    /// The decode service's process, for the folders run's DATA-17 figures (`--folders-perf-decoder`):
    /// `start` launches it with a request for nothing, which it refuses without decoding, and
    /// `resident` reads its resident memory from this side. Its footprint can't be read: the
    /// sandbox refuses `proc_pid_rusage` on it.
    final class DecoderProbe: @unchecked Sendable {
        private let connection = NSXPCConnection(serviceName: DecodeServiceClient.serviceName)

        init() {
            connection.remoteObjectInterface = NSXPCInterface(with: DecodeServiceProtocol.self)
            connection.resume()
        }

        deinit {
            connection.invalidate()
        }

        /// Starts the service if it isn't running, and waits for its answer.
        func start() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let answered = Mutex(false)
                let resume: @Sendable () -> Void = {
                    if answered.withLock({ was in defer { was = true }; return !was }) {
                        continuation.resume()
                    }
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in resume() } as? DecodeServiceProtocol
                guard let proxy else { return resume() }
                proxy.decode(Data(), path: "/dev/null") { _, _ in resume() }
            }
        }

        /// The service's resident memory in bytes; nil when it isn't running.
        func resident() -> UInt64? {
            let pid = connection.processIdentifier
            guard pid > 0 else { return nil }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? info.pti_resident_size : nil
        }
    }
#endif
