import Foundation
import RedlampServices
import Testing

/// Phase One backs (IIQ): LibRaw subtracts their black levels and applies their calibration only in
/// `raw2image`. Unpacked, the IQ4's data sits about 1000 above the black of 0 that LibRaw reports,
/// which white balance turns magenta.
struct PhaseOneDecodeTests {
    static let sample = DecodeRegressionTests.cameras.first { $0.lastPathComponent.hasPrefix("Phase-One_") }

    @Test(.enabled(if: sample != nil))
    func `a Phase One back's shadows sit at its black level`() throws {
        let image = try ImageDecoder.decode(#require(Self.sample))
        #expect(image.blackLevels.allSatisfy { $0 == 0 })
        let shadows = image.samples.withUnsafeBufferPointer { samples in
            var counts = [Int](repeating: 0, count: 65536)
            counts.withUnsafeMutableBufferPointer { counts in
                for sample in samples {
                    counts[Int(sample)] += 1
                }
            }
            // The level one photosite in ten thousand lies below, so a defect can't decide it.
            var below = 0
            for (level, count) in counts.enumerated() {
                below += count
                if below > samples.count / 10000 {
                    return level
                }
            }
            return counts.count
        }
        #expect(shadows < 256, "the shadows sit at \(shadows), above the black level of 0")
    }
}
