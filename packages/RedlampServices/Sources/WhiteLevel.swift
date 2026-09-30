import Foundation

/// Where a raw file's photosites actually clip. Clipping piles photosites onto the top value (or
/// a few values, for lossy formats), so a spike at the data's maximum marks the real clip point,
/// even where it sits above or below the nominal white level. Without a spike nothing clipped,
/// and the nominal level stands: lowering it to the brightest photosite would mark an unclipped
/// frame's highlights as clipped, and change its brightness with its content.
enum WhiteLevel {
    /// Values this close below the maximum still count as the spike.
    static let spikeWidth = 4

    static func measured(histogram: UnsafeBufferPointer<UInt32>, nominal: Float, total: Int) -> Float {
        guard let maximum = histogram.lastIndex(where: { $0 > 0 }), Float(maximum) > 0.5 * nominal else {
            return nominal
        }
        let spike = (max(0, maximum - spikeWidth) ... maximum).reduce(0) { $0 + Int(histogram[$1]) }
        let below = max(0, maximum - 100) ..< max(0, maximum - 10)
        let background = below.isEmpty ? 0 : below.reduce(0) { $0 + Int(histogram[$1]) } / below.count
        let enough = max(16, total / 500_000)
        guard spike >= enough, spike >= 20 * (background * (spikeWidth + 1) + 1) else { return nominal }
        return Float(maximum)
    }
}
