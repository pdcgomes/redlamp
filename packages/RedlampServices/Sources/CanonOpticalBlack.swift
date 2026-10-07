import Foundation
import LibRaw

/// Canon's black levels checked against the masked photosites its files declare (CAM-21).
///
/// LibRaw reads a Canon body's black levels from its maker note's colour data, whose layout it
/// recognises by the block's length. A newer body's block can share an older layout's length with
/// other contents: in LibRaw 0.22.2 the EOS R6 Mark III's and PowerShot V1's are read as the
/// R6 Mark II's, and give black levels of 0 to 145 where the sensor's masked photosites sit at 512.
/// Subtracting too little leaves an offset that white balance turns pink. A CR3 says where its
/// masked photosites are, the left and upper optical-black areas, so where their level is far from
/// the stated black it replaces it.
enum CanonOpticalBlack {
    /// A rectangle of the raw readout, its edges included, as Canon's files give it.
    struct Area: Equatable {
        var top: Int
        var left: Int
        var bottom: Int
        var right: Int

        init(top: Int, left: Int, bottom: Int, right: Int) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        init?(_ area: libraw_area_t) {
            guard area.r > area.l, area.b > area.t else { return nil }
            self.init(top: Int(area.t), left: Int(area.l), bottom: Int(area.b), right: Int(area.r))
        }
    }

    /// A pattern position's level in the masked photosites and their robust noise sigma, in raw units.
    struct Level: Equatable {
        var value: Float
        var noise: Float
    }

    /// Declared areas take in a few exposed photosites beside the image on some bodies (the
    /// R6 Mark III's last two columns), and the sensor's edge reads differently on others.
    static let guardBand = 8
    /// Each area is sampled down to about this many photosites per pattern position.
    static let samplesPerArea = 16384
    /// Fewer photosites per pattern position than this can't stand in for the black level.
    static let minimumSamples = 1024
    /// The stated black stands unless the masked photosites sit further from it than all three:
    /// the thresholds at which the camera bench fails a black level (`CameraBenchChecks`).
    static let sigmas: Float = 5
    static let units: Float = 4
    static let rangeShare: Float = 0.01

    /// `stated`, or the black level of each position of a Bayer pattern as the masked photosites
    /// measure it, for a Canon CR3 whose stated black they show to be wrong.
    static func checked(
        _ raw: UnsafeMutablePointer<libraw_data_t>,
        stated: [Float],
        pattern: CFAPattern,
        white: Float,
    ) -> [Float] {
        guard raw.pointee.idata.maker_index == LIBRAW_CAMERAMAKER_Canon.rawValue,
              pattern.width == 2, pattern.height == 2, stated.count == 4,
              let image = raw.pointee.rawdata.raw_image
        else {
            return stated
        }
        let canon = raw.pointee.makernotes.canon
        // Only CR3s declare both areas (LibRaw reads the left one from CR2s too), and every Canon
        // body newer than LibRaw's tables shoots CR3.
        guard let leftArea = Area(canon.LeftOpticalBlack), let upperArea = Area(canon.UpperOpticalBlack) else {
            return stated
        }
        let sizes = raw.pointee.sizes
        let measured = measure(
            raw: image, pitch: Int(sizes.raw_pitch) / MemoryLayout<UInt16>.size,
            rawWidth: Int(sizes.raw_width), rawHeight: Int(sizes.raw_height),
            top: Int(sizes.top_margin), left: Int(sizes.left_margin),
            areas: [leftArea, upperArea], white: white,
        )
        guard let measured, isWrong(stated, measured: measured, white: white) else { return stated }
        return measured.map(\.value)
    }

    /// Whether any position's stated black is further from its masked photosites' level than the
    /// camera bench allows.
    static func isWrong(_ stated: [Float], measured: [Level], white: Float) -> Bool {
        zip(stated, measured).contains { stated, level in
            let offset = abs(level.value - stated)
            return offset > max(units, sigmas * level.noise) && offset > rangeShare * (white - level.value)
        }
    }

    /// Each position of a 2 × 2 pattern (its origin the image's top left, `top` and `left` into the
    /// readout) measured over `areas`, less a guard band; nil where they hold too few photosites,
    /// one value (padding) or a spread like an image's.
    static func measure(
        raw: UnsafePointer<UInt16>, pitch: Int, rawWidth: Int, rawHeight: Int, top: Int, left: Int,
        areas: [Area], white: Float,
    ) -> [Level]? {
        var samples = [[UInt16]](repeating: [], count: 4)
        for area in areas {
            let firstRow = max(area.top, 0) + guardBand
            let lastRow = min(area.bottom, rawHeight - 1) - guardBand
            let firstColumn = max(area.left, 0) + guardBand
            let lastColumn = min(area.right, rawWidth - 1) - guardBand
            guard lastRow >= firstRow, lastColumn >= firstColumn else { continue }
            let count = (lastRow - firstRow + 1) * (lastColumn - firstColumn + 1)
            // An odd step alternates the rows' and columns' parity, so every position is sampled.
            let step = max(1, Int((Double(count) / Double(4 * samplesPerArea)).squareRoot().rounded(.up))) | 1
            for y in stride(from: firstRow, through: lastRow, by: step) {
                let row = raw + y * pitch
                let phase = ((y - top) & 1) << 1
                for x in stride(from: firstColumn, through: lastColumn, by: step) {
                    samples[phase | ((x - left) & 1)].append(row[x])
                }
            }
        }
        var levels: [Level] = []
        for var values in samples {
            guard values.count >= minimumSamples else { return nil }
            values.sort()
            guard values[values.count / 100] < values[values.count - 1 - values.count / 100] else { return nil }
            let median = Float(values[values.count / 2])
            var deviations = values.map { abs(Float($0) - median) }
            deviations.sort()
            let noise = 1.4826 * deviations[deviations.count / 2]
            guard noise < 0.02 * white else { return nil }
            levels.append(Level(value: median, noise: max(noise, 0.5)))
        }
        return levels
    }
}
