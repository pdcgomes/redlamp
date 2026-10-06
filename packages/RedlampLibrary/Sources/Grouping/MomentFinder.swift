import Foundation

/// Finds moments (LIB-41): photos taken together. In capture order, a new moment starts at a pause
/// longer than the setting's floor and longer than its multiple of the pace around the pause, which
/// is the median of the `gapsAround` gaps nearest it, half before and half after (the nearest at the
/// ends of the photos), counted as `MomentSetting.slowestPace` at most. So a wedding shot every few
/// seconds splits where its pauses pass the floor, and a walk shot every few minutes where they're
/// several times its pace.
///
/// Gaps of `StackFinder.burstGap` or less, a burst's frames or a raw beside its JPEG, never start a
/// moment and aren't the photographer's pace: the median is of the longer gaps, so bursts don't make
/// a walk's pace look like a wedding's. Capture times are milliseconds of the camera's clock read as
/// UTC, with the sidecar's shift (`ColumnEncoding.captured`), as `date:` and the capture-time sort
/// compare them. The same times and setting always give the same moments.
public enum MomentFinder {
    /// The gaps a pause's pace is the median of.
    static let gapsAround = 20

    /// Where moments start among photos taken at `times`, capture times in milliseconds in ascending
    /// order: the place of each moment's first photo, the first moment's left out.
    static func starts(_ times: UnsafeBufferPointer<Int64>, setting: MomentSetting) -> ContiguousArray<Int32> {
        let burst = Int64(StackFinder.burstGap * 1000)
        var pauses = ContiguousArray<Int64>()
        var after = ContiguousArray<Int32>()
        for place in times.indices.dropFirst() {
            let (gap, overflow) = times[place].subtractingReportingOverflow(times[place - 1])
            let length = overflow ? Int64.max : gap
            if length > burst {
                pauses.append(length)
                after.append(Int32(place))
            }
        }
        let floor = Int64((setting.floor * 1000).rounded())
        let slowest = MomentSetting.slowestPace * 1000
        let count = pauses.count
        var window = SortedWindow()
        var starts = ContiguousArray<Int32>()
        for pause in 0 ..< count where pauses[pause] > floor {
            let lower = max(0, min(pause - gapsAround / 2, count - gapsAround - 1))
            window.move(to: lower ..< min(count, lower + gapsAround + 1), in: pauses)
            let pace = window.median(leavingOut: pauses[pause]).map { min($0, slowest) } ?? slowest
            if Double(pauses[pause]) > setting.multiple * pace {
                starts.append(after[pause])
            }
        }
        return starts
    }
}

/// A run of pauses kept sorted as it moves forward along them, for their median.
struct SortedWindow {
    private var values = ContiguousArray<Int64>()
    private var range = 0 ..< 0

    /// Holds `pauses[range]`: a range starting and ending no earlier than the last one.
    mutating func move(to range: Range<Int>, in pauses: ContiguousArray<Int64>) {
        if range.lowerBound >= self.range.upperBound {
            values.removeAll(keepingCapacity: true)
            self.range = range.lowerBound ..< range.lowerBound
        }
        for place in self.range.lowerBound ..< range.lowerBound {
            values.remove(at: firstIndex(notBelow: pauses[place]))
        }
        for place in self.range.upperBound ..< range.upperBound {
            values.insert(pauses[place], at: firstIndex(notBelow: pauses[place]))
        }
        self.range = range
    }

    /// The median of the values held, one of them `value` left out; nil when it's the only one.
    func median(leavingOut value: Int64) -> Double? {
        let others = values.count - 1
        guard others > 0 else { return nil }
        let skipped = firstIndex(notBelow: value)
        func other(_ index: Int) -> Double {
            Double(values[index < skipped ? index : index + 1])
        }
        return others % 2 == 1 ? other(others / 2) : (other(others / 2 - 1) + other(others / 2)) / 2
    }

    private func firstIndex(notBelow value: Int64) -> Int {
        var (low, high) = (0, values.count)
        while low < high {
            let middle = (low + high) / 2
            (low, high) = values[middle] < value ? (middle + 1, high) : (low, middle)
        }
        return low
    }
}
