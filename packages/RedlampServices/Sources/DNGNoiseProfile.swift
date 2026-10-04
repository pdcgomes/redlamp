import Foundation

/// Reads the DNG NoiseProfile tag (0xC761): per color plane, variance = S · value + O in
/// normalised units, the same model `NoiseEstimator` fits. LibRaw doesn't expose it.
enum DNGNoiseProfile {
    static let tag: UInt16 = 0xC761

    static func read(_ url: URL) -> NoiseModel? {
        guard url.pathExtension.lowercased() == "dng",
              let data = try? Data(contentsOf: url, options: .alwaysMapped)
        else {
            return nil
        }
        return read(data, url: url)
    }

    /// The same from the file's bytes, `url` naming the file.
    static func read(_ data: Data, url: URL) -> NoiseModel? {
        guard url.pathExtension.lowercased() == "dng" else {
            return nil
        }
        return data.withUnsafeBytes { bytes in
            guard let reader = TIFFReader(bytes: bytes) else { return nil }
            for entries in reader.imageFileDirectories() {
                for entry in entries where entry.tag == tag && entry.type == TIFFReader.doubleType {
                    if let model = model(entry, reader: reader) {
                        return model
                    }
                }
            }
            return nil
        }
    }

    private static func model(_ entry: TIFFReader.Entry, reader: TIFFReader) -> NoiseModel? {
        let pairs = entry.count / 2
        let start = Int(reader.u32(entry.valueOffset))
        guard pairs >= 1, start + entry.count * 8 <= reader.bytes.count else { return nil }
        let values = (0 ..< entry.count).map { reader.f64(start + $0 * 8) }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        // One pair covers every plane; otherwise the first three planes are R, G, B.
        let plane = { (channel: Int) in pairs >= 3 ? channel : 0 }
        let a = SIMD3<Float>((0 ..< 3).map { Float(values[plane($0) * 2]) })
        let b = SIMD3<Float>((0 ..< 3).map { Float(values[plane($0) * 2 + 1]) })
        guard a.max() > 0 || b.max() > 0, (a + b).max().isFinite else { return nil }
        return NoiseModel(a: a, b: b)
    }
}
