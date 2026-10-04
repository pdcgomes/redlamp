import Foundation
import RedlampEngineAPI

public extension CameraMode {
    /// The camera mode a file's identity puts it in: camera, LibRaw decoder, bits and frame.
    init(identity: RawFileIdentity) {
        let make = identity.normalizedMake ?? identity.make ?? "Unknown"
        let model = identity.displayModel
        let decoder = identity.decoder ?? (identity.refusal == nil ? "unknown" : "refused")
        let frame = identity.imageSize
        let key = [
            make,
            model,
            decoder,
            identity.bitsPerSample.map(String.init) ?? "-",
            "\(frame.width)x\(frame.height)",
        ]
        .joined(separator: "|")
        var words: [String] = []
        if let bits = identity.bitsPerSample, (8 ... 16).contains(bits) {
            words.append("\(bits)-bit")
        }
        if let scheme = Self.scheme(identity), scheme != identity.format {
            words.append(scheme)
        }
        words.append(identity.format)
        let size = frame.width > 0 ? ", \(frame.width) × \(frame.height)" : ""
        self.init(key: key, camera: identity.camera, label: words.joined(separator: " ") + size)
    }

    /// LibRaw's decoders in words, for the schemes cameras write today; others by their name.
    private static let schemes: [String: String] = [
        "sony_arw2_load_raw": "compressed",
        "sony_arw_load_raw": "compressed",
        "sony_ljpeg_load_raw": "lossless compressed",
        "unpacked_load_raw": "uncompressed",
        "unpacked_load_raw_reversed": "uncompressed",
        "packed_load_raw": "uncompressed",
        "nikon_load_raw": "compressed",
        "nikon_14bit_load_raw": "uncompressed",
        "nikon_load_padded_packed_raw": "uncompressed",
        "crxLoadRaw": "CR3",
        "lossless_jpeg_load_raw": "lossless JPEG",
        "fuji_compressed_load_raw": "compressed",
        "fuji_14bit_load_raw": "uncompressed",
        "panasonicC6_load_raw": "compressed",
        "panasonicC7_load_raw": "compressed",
        "panasonicC8_load_raw": "compressed",
        "panasonic_load_raw": "compressed",
        "olympus_load_raw": "compressed",
        "pentax_load_raw": "compressed",
        "samsung_load_raw": "compressed",
        "samsung2_load_raw": "compressed",
        "samsung3_load_raw": "compressed",
        "hasselblad_load_raw": "Hasselblad compressed",
        "phase_one_load_raw": "uncompressed",
        "phase_one_load_raw_c": "compressed",
        "phase_one_load_raw_s": "lossless",
        "lossless_dng_load_raw": "lossless",
        "packed_dng_load_raw": "uncompressed",
        "lossy_dng_load_raw": "lossy",
        "deflate_dng_load_raw": "deflate",
        "uncompressed_fp_dng_load_raw": "floating-point",
    ]

    private static func scheme(_ identity: RawFileIdentity) -> String? {
        if identity.refusal != nil, identity.decoder == nil {
            return "refused"
        }
        guard let decoder = identity.decoder else { return nil }
        return schemes[decoder] ?? decoder.replacingOccurrences(of: "_load_raw", with: "")
    }
}

public extension BenchCondition {
    /// The conditions a photo covers. `temperature` is the camera's white balance in kelvin.
    static func met(by identity: RawFileIdentity, measurements: DecodeMeasurements?, temperature: Double?)
        -> [BenchCondition] {
        var met: [BenchCondition] = []
        if let iso = identity.iso {
            if iso <= 200 {
                met.append(.baseISO)
            }
            if iso >= 3200 {
                met.append(.highISO)
            }
        }
        if identity.orientation == 5 || identity.orientation == 6 {
            met.append(.portrait)
        }
        if let share = measurements?.clippedShare, share >= 0.001 {
            met.append(.clippedHighlights)
        }
        if let temperature, temperature < 4000 {
            met.append(.warmLight)
        }
        return met
    }
}
