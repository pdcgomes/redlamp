import Foundation
import RedlampEngineAPI
import RedlampServices

/// A frame of a merge that didn't decode, by index among the frames being merged.
struct FrameDecodeFailure: Error {
    let index: Int
    let error: any Error
    /// The merge's other frames found not to decode before it stopped, by index.
    var others: [(index: Int, error: any Error)] = []

    var all: [(index: Int, error: any Error)] {
        [(index, error)] + others
    }

    /// `error` from decoding frame `index`; a decoder that isn't available fails every frame, so
    /// its error stays as it is and fails the merge.
    static func wrapping(_ error: any Error, frame index: Int) -> any Error {
        error as? EngineError == .decoderUnavailable ? error : FrameDecodeFailure(index: index, error: error)
    }
}

extension FocusStackCache {
    /// Whether every frame a cached merge left out still doesn't decode, so the merge stands; once
    /// one does, the stack merges again. A frame that failed within `unreadableRetry` isn't tried.
    func stillMissing(_ stack: MergedStack, frames: [URL], now: Date = Date()) -> Bool {
        (stack.report.failedFrames ?? []).allSatisfy { failed in
            guard frames.indices.contains(failed.index) else { return false }
            let frame = frames[failed.index]
            if let identity = try? Self.identity(of: frame),
               let failedAt = unreadable.withLock({ $0[identity] }),
               now.timeIntervalSince(failedAt) < Self.unreadableRetry {
                return true
            }
            guard (try? decoder.decode(frame)) == nil else { return false }
            noteUnreadable([frame], at: now)
            return true
        }
    }

    func noteUnreadable(_ frames: [URL], at now: Date = Date()) {
        let identities = frames.compactMap { try? Self.identity(of: $0) }
        unreadable.withLock { known in
            known = known.filter { now.timeIntervalSince($0.value) < Self.unreadableRetry }
            for identity in identities {
                known[identity] = now
            }
        }
    }

    /// Lets the next merge or load of the stack at `url` try its unreadable frames again.
    func retryUnreadableFrames(of url: URL) {
        guard let document = try? FocusStackDocument.read(url) else { return }
        let identities = document.frameURLs(at: url).compactMap { try? Self.identity(of: $0) }
        unreadable.withLock { known in
            for identity in identities {
                known[identity] = nil
            }
        }
    }

    /// The frames after `position` in a merge's first pass that don't decode: those already
    /// decoding ahead, then the rest a few at a time, so the merge restarts once without them all.
    static func undecodable(
        after position: Int, of urls: [URL], pending: [Int: Prefetch<DecodedImage>],
        decoder: any ImageDecoding, on queue: DispatchQueue,
    ) throws -> [(index: Int, error: any Error)] {
        var failures: [(index: Int, error: any Error)] = []
        var frames = Array(position + 1 ..< urls.count)
        while !frames.isEmpty {
            let batch = Array(frames.prefix(decodesAhead + 1))
            frames.removeFirst(batch.count)
            let decodes = batch.map { frame in
                pending[frame] ?? Prefetch(on: queue) { [url = urls[frame]] in
                    do {
                        return try decoder.decode(url)
                    } catch {
                        throw FrameDecodeFailure.wrapping(error, frame: frame)
                    }
                }
            }
            for (frame, decode) in zip(batch, decodes) {
                do {
                    _ = try decode.value()
                } catch let failure as FrameDecodeFailure {
                    failures.append((frame, failure.error))
                }
            }
        }
        return failures
    }
}

extension MergedStack {
    /// A merge of the frames `included` (indices into the stack's `count` frames) as a merge of
    /// all of them: the reference, alignment and depth map indexed by stack frame, with `failed`
    /// in the report and its info saying how many couldn't be read. Left-out frames keep the
    /// identity alignment.
    func spread(over included: [Int], of count: Int, failed: [FocusStackReport.FailedFrame]) -> MergedStack {
        var info = decoded.info
        info.sensorDescription += failed.count == 1
            ? ", 1 frame couldn't be read" : ", \(failed.count) frames couldn't be read"
        let decoded = with(samples: decoded.samples, info: info).decoded
        var report = report
        report.frames = count
        report.reference = included[report.reference]
        report.failedFrames = failed.sorted { $0.index < $1.index }
        var spread = StackAlignment(
            reference: included[alignment.reference],
            transforms: Array(repeating: .identity, count: count),
            gains: Array(repeating: SIMD3(repeating: 1), count: count),
            correlations: Array(repeating: 0, count: count),
        )
        for (merged, frame) in included.enumerated() {
            spread.transforms[frame] = alignment.transforms[merged]
            spread.gains[frame] = alignment.gains[merged]
            spread.correlations[frame] = alignment.correlations[merged]
        }
        let depth = depth.map { value -> Float in
            let position = min(max(value, 0), Float(included.count - 1))
            let lower = min(Int(position), included.count - 2)
            let t = position - Float(lower)
            return Float(included[lower]) + t * Float(included[lower + 1] - included[lower])
        }
        return MergedStack(
            decoded: decoded, report: report, depth: depth, depthWidth: depthWidth, depthHeight: depthHeight,
            crop: crop, frameWidth: frameWidth, frameHeight: frameHeight, referenceURL: referenceURL,
            alignment: spread,
        )
    }
}
