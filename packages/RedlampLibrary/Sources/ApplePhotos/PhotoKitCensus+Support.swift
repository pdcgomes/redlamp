#if DEBUG || REDLAMP_PROFILING
    import CoreGraphics
    import Foundation
    import RedlampDocument

    extension PhotoKitCensus {
        /// An error as the report names it: the library's own by its case, others by their domain and code and those
        /// under them. Never a description, which can name a photo's file.
        public static func name(of error: any Error) -> String {
            if let error = error as? ApplePhotosError {
                switch error {
                case let .noAccess(access): return "noAccess \(access.rawValue)"
                case .notFound: return "notFound"
                case .unavailable: return "unavailable"
                case .offline: return "offline"
                case .unreadableManifest: return "unreadableManifest"
                case .expiredToken: return "expiredToken"
                }
            }
            switch error {
            case is CancellationError: return "cancelled"
            case is TimedOut: return "timedOut"
            case is NotMeasured: return "notMeasured"
            default:
                var names: [String] = []
                var next: NSError? = error as NSError
                while let error = next, names.count < 4 {
                    names.append("\(error.domain) \(error.code)")
                    next = error.userInfo[NSUnderlyingErrorKey] as? NSError
                }
                return names.joined(separator: " < ")
            }
        }

        static func label(_ locality: ApplePhotosLocality) -> String {
            switch locality {
            case .local: "local"
            case .inCloud: "inCloud"
            case let .unknown(why): "unknown: \(why)"
            }
        }

        static func tally(_ values: some Sequence<String>) -> [String: Int] {
            values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }

        static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            (ContinuousClock.now - start) / .milliseconds(1)
        }

        /// A time to read: milliseconds under a second, seconds above.
        static func seconds(_ milliseconds: Double) -> String {
            milliseconds < 1000 ? "\(Int(milliseconds.rounded())) ms" : String(format: "%.1f s", milliseconds / 1000)
        }

        /// The long side of a file Photos gives the pixel size of.
        static func longEdge(of resource: ApplePhotosResource?) -> Double? {
            guard let width = resource?.pixelWidth, let height = resource?.pixelHeight else { return nil }
            return Double(max(width, height))
        }

        /// `body`'s result, worked out on a thread of its own: Photos' images and data are asked for synchronously.
        static func blocking<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: body())
                }
            }
        }

        static func bytes(at url: URL) -> Int64 {
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }

        static func megabytes(of urls: [URL]) -> Double {
            PhotoKitCensusReport.Spread.round(Double(urls.map(bytes(at:)).reduce(0, +)) / 1_000_000)
        }

        /// The space free on the disk of the home folder: `available`, and `forImportantUsage`, which counts what macOS
        /// can purge.
        static func free() -> [String: Int64] {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            guard let values = try? home.resourceValues(forKeys: [
                .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ]) else { return [:] }
            var free: [String: Int64] = [:]
            if let available = values.volumeAvailableCapacity {
                free["available"] = Int64(available)
            }
            if let important = values.volumeAvailableCapacityForImportantUsage {
                free["forImportantUsage"] = important
            }
            return free
        }

        /// The process's memory as the design's budgets count it, in megabytes.
        static func footprint() -> Double {
            PhotoKitCensusReport.Spread.round(Footprint.megabytes(Footprint.current()))
        }
    }

    /// Requests at one size as the census counts them.
    struct RequestTally {
        private var answers = PhotoKitCensusReport.Requests()
        private var edges: [Double] = []
        private var times: [Double] = []

        /// Asks `images` for the picture at `tier`'s size, as LIB-59's thumbnail maker does, timing it.
        mutating func ask(
            _ images: any ApplePhotosImages, _ asset: String, _ version: ApplePhotosImageVersion,
            _ tier: PhotoStore.Tier,
        ) {
            let started = ContinuousClock.now
            let answer = images.image(of: asset, version: version, size: tier.pixelSize)
            times.append(PhotoKitCensus.milliseconds(since: started))
            answers.asked += 1
            switch answer {
            case let .image(image):
                answers.given += 1
                edges.append(Double(max(image.width, image.height)))
            case .inCloud: answers.inCloud += 1
            case .unavailable: answers.unavailable += 1
            }
        }

        var report: PhotoKitCensusReport.Requests {
            var report = answers
            report.longEdge = PhotoKitCensusReport.Spread(edges)
            report.milliseconds = PhotoKitCensusReport.Spread(times)
            return report
        }
    }

    /// The largest images Photos keeps, as the census counts them.
    struct LargestTally {
        private var asked = 0
        private var edges: [Double] = []
        private var shares: [Double] = []

        /// `edge`, the long side of the largest image Photos gave; `original`, its original's.
        mutating func add(_ edge: Int?, original: Double?) {
            asked += 1
            guard let edge else { return }
            edges.append(Double(edge))
            if let original, original > 0 {
                shares.append(100 * Double(edge) / original)
            }
        }

        var report: PhotoKitCensusReport.Largest {
            PhotoKitCensusReport.Largest(
                asked: asked, given: edges.count, longEdge: PhotoKitCensusReport.Spread(edges),
                ofOriginal: PhotoKitCensusReport.Spread(shares),
            )
        }
    }

    extension PhotoKitCensusReport.Mac {
        /// This Mac, the Redlamp running, and the network as `network` sees it now.
        static func current(network: any ApplePhotosNetwork) -> Self {
            let info = Bundle.main.infoDictionary
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return Self(
                model: sysctl("hw.model"), chip: sysctl("machdep.cpu.brand_string"),
                memoryGB: Int(ProcessInfo.processInfo.physicalMemory >> 30),
                macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                redlamp: info?["CFBundleShortVersionString"] as? String,
                commit: (info?["RedlampCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                performanceCores: CoreCounts.performance, reachable: network.isReachable,
                expensive: network.isExpensive,
            )
        }

        private static func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
#endif
