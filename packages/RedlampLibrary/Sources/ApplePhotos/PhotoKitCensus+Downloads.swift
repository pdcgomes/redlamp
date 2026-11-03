#if DEBUG || REDLAMP_PROFILING
    import Foundation
    import Synchronization

    /// Downloads from iCloud as LIB-60 makes them (`ApplePhotosLibrary.write`): originals only in iCloud downloaded
    /// whole,
    /// others cancelled partway, and whether Photos keeps what it downloaded for Redlamp.
    extension PhotoKitCensus {
        /// The photos whose originals are only in iCloud that the census downloads, cancels and leaves for the offline
        /// step.
        struct Picks {
            var downloads: [ApplePhotosAsset]
            var cancels: [ApplePhotosAsset]
            var spares: [ApplePhotosAsset]
        }

        /// `inCloud` taken in turn from each kind of original (a camera's raw, a RAW+JPEG pair, a HEIC, a JPEG…), so
        /// the
        /// downloads span the kinds the library has.
        static func picks(_ inCloud: [ApplePhotosAsset], _ plan: Plan) -> Picks {
            var kinds: [String: [ApplePhotosAsset]] = [:]
            var order: [String] = []
            for asset in inCloud {
                let kind = asset.isPair ? "pair" : asset.resource(.photo)?.type ?? "other"
                if kinds[kind] == nil {
                    order.append(kind)
                }
                kinds[kind, default: []].append(asset)
            }
            var taken: [ApplePhotosAsset] = []
            var round = 0
            while taken.count < plan.downloads + plan.cancels + plan.spares,
                  order.contains(where: { kinds[$0]!.count > round }) {
                for kind in order where kinds[kind]!.count > round {
                    taken.append(kinds[kind]![round])
                }
                round += 1
            }
            let downloads = Array(taken.prefix(plan.downloads))
            let cancels = Array(taken.dropFirst(downloads.count).prefix(plan.cancels))
            let spares = Array(taken.dropFirst(downloads.count + cancels.count).prefix(plan.spares))
            return Picks(downloads: downloads, cancels: cancels, spares: spares)
        }

        /// What a download heard of its progress: when, and how far.
        final class Progress: Sendable {
            let started = ContinuousClock.now
            private let heard = Mutex<[(at: ContinuousClock.Instant, fraction: Double)]>([])

            func add(_ fraction: Double) {
                heard.withLock { $0.append((.now, fraction)) }
            }

            var calls: Int {
                heard.withLock(\.count)
            }

            /// From the start to Photos' first word of progress, and to its first above nothing.
            var first: Double? {
                heard.withLock { $0.first.map { ($0.at - started) / .milliseconds(1) } }
            }

            var firstBytes: Double? {
                heard.withLock { $0.first { $0.fraction > 0 }.map { ($0.at - started) / .milliseconds(1) } }
            }
        }

        /// Downloads each of `assets`' original files from iCloud to the scratch folder, measuring it, then removes it
        /// and
        /// asks Photos without the network whether it kept the original.
        func download(_ assets: [ApplePhotosAsset], _ plan: Plan) async -> PhotoKitCensusReport.Downloads {
            var result = PhotoKitCensusReport.Downloads()
            let files = assets.flatMap { asset in asset.originals.map { (asset: asset.id, resource: $0) } }
            guard !files.isEmpty else { return result }
            say(
                "Downloading \(files.count) originals of \(assets.count) photos from iCloud, one at a time: leave the Mac "
                    + "alone meanwhile.",
            )
            result.freeBefore = Self.free()
            var megabytes: [Double] = []
            var seconds: [Double] = []
            var rates: [Double] = []
            var firsts: [Double] = []
            var firstBytes: [Double] = []
            var calls: [Double] = []
            for (number, file) in files.enumerated() {
                result.asked += 1
                result.types[file.resource.type, default: 0] += 1
                let url = scratch.appending(path: UUID().uuidString)
                let progress = Progress()
                do {
                    try await Self.within(plan.timeout) { [photos] in
                        try await photos.write(file.resource, of: file.asset, to: url) { progress.add($0) }
                    }
                    let elapsed = (ContinuousClock.now - progress.started) / .seconds(1)
                    let size = Double(Self.bytes(at: url)) / 1_000_000
                    result.completed += 1
                    megabytes.append(size)
                    seconds.append(elapsed)
                    rates.append(elapsed > 0 ? size / elapsed : 0)
                    calls.append(Double(progress.calls))
                    progress.first.map { firsts.append($0) }
                    progress.firstBytes.map { firstBytes.append($0) }
                    say(
                        "\(number + 1) of \(files.count): \(String(format: "%.1f", size)) MB in \(Self.seconds(elapsed * 1000)).",
                    )
                } catch {
                    result.failed[Self.name(of: error), default: 0] += 1
                    say("\(number + 1) of \(files.count) failed: \(Self.name(of: error)).")
                }
                try? FileManager.default.removeItem(at: url)
                let afterwards = await probe.locality(of: file.resource, of: file.asset)
                result.afterwards[Self.label(afterwards), default: 0] += 1
            }
            result.freeAfter = Self.free()
            result.megabytes = PhotoKitCensusReport.Spread(megabytes)
            result.seconds = PhotoKitCensusReport.Spread(seconds)
            result.megabytesPerSecond = PhotoKitCensusReport.Spread(rates)
            result.firstProgressMilliseconds = PhotoKitCensusReport.Spread(firsts)
            result.firstBytesMilliseconds = PhotoKitCensusReport.Spread(firstBytes)
            result.progressCalls = PhotoKitCensusReport.Spread(calls)
            return result
        }

        /// Where a download is cancelled: at Photos' first word of progress, a quarter of the way, half way.
        static let cancelPoints: [(name: String, fraction: Double)] = [
            ("firstProgress", 0),
            ("quarter", 0.25),
            ("half", 0.5),
        ]

        /// How a download meant to be cancelled went before it was.
        enum Course: Sendable {
            case reached, ended, timedOut
        }

        /// Starts downloading each of `assets`' originals and cancels it at its point (`cancelPoints`, in turn), as
        /// Cancel in Develop does, measuring how it stops, then asks Photos whether it kept the original anyway.
        func cancel(_ assets: [ApplePhotosAsset], _ plan: Plan) async -> PhotoKitCensusReport.Cancels {
            var result = PhotoKitCensusReport.Cancels()
            let files = assets.compactMap { asset in asset.resource(.photo).map { (asset: asset.id, resource: $0) } }
            guard !files.isEmpty else { return result }
            say("Starting \(files.count) more downloads and cancelling each partway.")
            var stopped: [Double] = []
            var megabytes: [Double] = []
            for (number, file) in files.enumerated() {
                result.asked += 1
                let point = Self.cancelPoints[number % Self.cancelPoints.count]
                let url = scratch.appending(path: UUID().uuidString)
                let (reached, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
                let download = Task { [photos] in
                    defer { signal.finish() }
                    try await photos.write(file.resource, of: file.asset, to: url) { fraction in
                        if fraction >= point.fraction {
                            signal.yield()
                        }
                    }
                }
                let course = await withTaskGroup(of: Course.self) { group in
                    group.addTask {
                        for await _ in reached {
                            return .reached
                        }
                        return .ended
                    }
                    group.addTask {
                        try? await Task.sleep(for: plan.timeout)
                        return .timedOut
                    }
                    let first = await group.next() ?? .timedOut
                    group.cancelAll()
                    return first
                }
                let before = Self.bytes(at: url)
                let cancelled = ContinuousClock.now
                download.cancel()
                let ended = await download.result
                let stopping = (ContinuousClock.now - cancelled) / .milliseconds(1)
                if course == .reached, case .failure = ended {
                    result.cancelled += 1
                    result.at[point.name, default: 0] += 1
                    stopped.append(stopping)
                    megabytes.append(Double(before) / 1_000_000)
                    try? await Task.sleep(for: plan.watching)
                    if Self.bytes(at: url) > before {
                        result.grewAfterwards += 1
                    }
                } else if course != .timedOut, case .success = ended {
                    result.finishedFirst += 1
                }
                let name = switch ended {
                case .success: course == .timedOut ? "timedOut" : "completed"
                case let .failure(error): course == .timedOut ? "timedOut" : Self.name(of: error)
                }
                result.ended[name, default: 0] += 1
                say("\(number + 1) of \(files.count): \(name) at \(point.name), \(String(format: "%.1f", stopping)) ms "
                    + "after cancelling.")
                try? FileManager.default.removeItem(at: url)
            }
            try? await Task.sleep(for: plan.settling)
            for file in files {
                let afterwards = await probe.locality(of: file.resource, of: file.asset)
                result.afterwards[Self.label(afterwards), default: 0] += 1
            }
            result.stoppedMilliseconds = PhotoKitCensusReport.Spread(stopped)
            result.megabytesWhenCancelled = PhotoKitCensusReport.Spread(megabytes)
            return result
        }

        /// The census gave up waiting.
        struct TimedOut: Error {}

        /// `body`'s result, or `TimedOut` once `limit` passes, `body` then cancelled.
        static func within<T: Sendable>(
            _ limit: Duration, _ body: @escaping @Sendable () async throws -> T,
        ) async throws -> T {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await body() }
                group.addTask {
                    try await Task.sleep(for: limit)
                    throw TimedOut()
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw TimedOut() }
                return first
            }
        }
    }
#endif
