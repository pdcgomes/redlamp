import Foundation
import LibRaw
import RedlampEngineAPI

/// Nikon's High Efficiency raw files (HE and HE*, CAM-12): NEFs whose raw image is a JPEG XS
/// codestream (intoPIX's TicoRAW) instead of Nikon's own coding.
///
/// LibRaw 0.22 looks for these only in the Z 9, Z 8, Z f and Z 6III, and refuses them there; the
/// Z5 II's and Z50 II's go to its ordinary Nikon decoder, which turns them into noise. They are
/// refused here until LibRaw routes them to a decoder that reads them.
enum NikonHighEfficiency {
    static let refusal = EngineError.notSupportedYet(
        "Nikon's High Efficiency raw files (HE and HE*)",
        tracker: "CAM-12",
    )

    /// LibRaw's name for the decoder of this data.
    static let libRawDecoder = "nikon_he_load_raw"

    /// TIFF's Compression value for Nikon's compressed NEF data, HE included.
    static let nefCompression = 34713

    /// JPEG XS's start-of-codestream and capabilities markers, which open every HE and HE* raw image.
    static let markers: [UInt8] = [0xFF, 0x10, 0xFF, 0x50]

    /// Whether LibRaw would decode an HE raw image wrongly or not at all.
    static func libRawCantDecode(_ raw: UnsafeMutablePointer<libraw_data_t>, data: Data?, url: URL) -> Bool {
        guard isHighEfficiency(raw, data: data, url: url) else { return false }
        var info = libraw_decoder_info_t()
        guard libraw_get_decoder_info(raw, &info) == 0, let name = info.decoder_name else { return true }
        let unsupported = info.decoder_flags & LIBRAW_DECODER_UNSUPPORTED_FORMAT.rawValue != 0
        return String(cString: name).replacingOccurrences(of: "()", with: "") != libRawDecoder || unsupported
    }

    /// Whether an opened Nikon file's raw image is HE or HE* data.
    static func isHighEfficiency(_ raw: UnsafeMutablePointer<libraw_data_t>, data: Data?, url: URL) -> Bool {
        guard RawDecoder.string(rl_make(raw))?.lowercased().hasPrefix("nikon") == true,
              let bytes = data ?? (try? Data(contentsOf: url, options: .alwaysMapped))
        else {
            return false
        }
        return isHighEfficiency(bytes)
    }

    static func isHighEfficiency(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            TIFFReader(bytes: bytes).map(isHighEfficiency) ?? false
        }
    }

    /// The raw image is the directory with NewSubfileType 0, Nikon's compression and a size; NEFs
    /// also carry empty directories with the same compression.
    static func isHighEfficiency(_ reader: TIFFReader) -> Bool {
        for entries in reader.imageFileDirectories() {
            let tags = Dictionary(entries.map { ($0.tag, $0) }) { first, _ in first }
            func value(_ tag: UInt16) -> Int? {
                tags[tag].flatMap { reader.integers($0).first }
            }
            guard value(254) ?? 0 == 0, value(259) == nefCompression, value(256) ?? 0 > 0, value(257) ?? 0 > 0,
                  let offset = value(273)
            else {
                continue
            }
            guard offset >= 0, offset + markers.count <= reader.bytes.count else { return false }
            return markers.indices.allSatisfy { reader.bytes[offset + $0] == markers[$0] }
        }
        return false
    }
}
