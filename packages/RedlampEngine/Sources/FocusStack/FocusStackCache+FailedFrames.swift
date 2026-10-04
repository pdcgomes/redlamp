import Foundation
import RedlampEngineAPI
import RedlampServices

/// A frame of a merge that didn't decode, by index among the frames being merged.
struct FrameDecodeFailure: Error {
    let index: Int
    let error: any Error

    /// `error` from decoding frame `index`; a decoder that isn't available fails every frame, so
    /// its error stays as it is and fails the merge.
    static func wrapping(_ error: any Error, frame index: Int) -> any Error {
        error as? EngineError == .decoderUnavailable ? error : FrameDecodeFailure(index: index, error: error)
    }
}

extension MergedStack {
    /// A merge of the frames `included` (indices into the stack's `count` frames) as a merge of
    /// all of them: the reference, alignment and depth map indexed by stack frame, with `failed`
    /// in the report. Left-out frames keep the identity alignment.
    func spread(over included: [Int], of count: Int, failed: [FocusStackReport.FailedFrame]) -> MergedStack {
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
