#if DEBUG || REDLAMP_PROFILING
    import Darwin
    import Foundation
    import RedlampServices
    import Synchronization

    /// The decode service's process, for the folders run's DATA-17 figures (`--folders-perf-decoder`):
    /// `start` launches it with a request for nothing, which it refuses without decoding, and
    /// `footprint` reads what macOS charges it for, from this side.
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

        /// The service's footprint in bytes; nil when it isn't running.
        func footprint() -> UInt64? {
            let pid = connection.processIdentifier
            guard pid > 0 else { return nil }
            var info = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            return read == 0 ? info.ri_phys_footprint : nil
        }
    }
#endif
