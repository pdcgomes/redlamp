import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampServices

struct NikonHighEfficiencyTests {
    /// The start of a real HE raw image: JPEG XS's SOC and CAP markers, then intoPIX's capabilities.
    static let highEfficiency: [UInt8] = [0xFF, 0x10, 0xFF, 0x50, 0x00, 0x22] + Array("CONTACT_INTOPIX_".utf8)
    /// The start of a lossless-compressed raw image.
    static let lossless: [UInt8] = [0xD4, 0x22, 0xA4, 0x7F, 0x3D, 0xFD, 0x3F, 0x79]

    @Test func `a raw image that opens with JPEG XS markers is High Efficiency`() {
        #expect(NikonHighEfficiency.isHighEfficiency(Self.nef(strip: Self.highEfficiency)))
    }

    @Test func `a lossless raw image isn't`() {
        #expect(!NikonHighEfficiency.isHighEfficiency(Self.nef(strip: Self.lossless)))
    }

    @Test func `only the full-size Nikon-compressed directory counts`() {
        #expect(!NikonHighEfficiency.isHighEfficiency(Self.nef(strip: Self.highEfficiency, compression: 1)))
        #expect(!NikonHighEfficiency.isHighEfficiency(Self.nef(strip: Self.highEfficiency, subfileType: 1)))
        #expect(!NikonHighEfficiency.isHighEfficiency(Self.nef(strip: Self.highEfficiency, width: 0)))
    }

    @Test func `a strip past the end of the file isn't read`() {
        #expect(!NikonHighEfficiency.isHighEfficiency(Self.nef(strip: Self.highEfficiency, stripOffset: 1 << 30)))
        #expect(!NikonHighEfficiency.isHighEfficiency(Data([0x49, 0x49, 0x2A, 0x00])))
    }

    @Test func `an HE image from a verified body opens once LibRaw's HE decoder takes it`() {
        for model in ["Z 9", "Z 8", "Z f", "Z6_3", "Z5_2", "Z50_2"] {
            #expect(!NikonHighEfficiency.refuses(model: model, decoder: "nikon_he_load_raw()", unsupported: false))
        }
    }

    @Test func `it is refused when LibRaw's HE decoder is the unsupported stub or isn't the one chosen`() {
        #expect(NikonHighEfficiency.refuses(model: "Z5_2", decoder: "nikon_he_load_raw()", unsupported: true))
        #expect(NikonHighEfficiency.refuses(model: "Z5_2", decoder: "nikon_load_raw()", unsupported: false))
    }

    @Test func `it is refused from a body whose files haven't been verified`() {
        #expect(NikonHighEfficiency.refuses(model: "ZR", decoder: "nikon_he_load_raw()", unsupported: false))
        #expect(NikonHighEfficiency.refuses(model: nil, decoder: "nikon_he_load_raw()", unsupported: false))
    }

    @Test func `the refusal says the format isn't supported yet and names its tracker row`() {
        let refusal = NikonHighEfficiency.refusal
        #expect(refusal.localizedDescription == "Nikon's High Efficiency raw files (HE and HE*) aren't supported yet.")
        #expect(refusal.notSupportedYetTracker == "CAM-12")
    }

    /// A little-endian NEF laid out as the cameras write it: IFD0 (a thumbnail) points at two
    /// SubIFDs, an empty one with Nikon's compression and then the raw image.
    static func nef(
        strip: [UInt8], compression: Int = NikonHighEfficiency.nefCompression, subfileType: Int = 0,
        width: Int = 4000, stripOffset: Int? = nil,
    ) -> Data {
        var data = Data()
        func append16(_ value: Int) {
            data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
        }
        func append32(_ value: Int) {
            append16(value & 0xFFFF)
            append16(value >> 16 & 0xFFFF)
        }
        func directory(_ entries: [(tag: Int, type: Int, count: Int, value: Int)]) {
            append16(entries.count)
            for entry in entries {
                append16(entry.tag)
                append16(entry.type)
                append32(entry.count)
                append32(entry.value)
            }
            append32(0)
        }
        let short = 3, long = 4
        let size = { (entries: Int) in 2 + entries * 12 + 4 }
        let ifd0 = 8, subIFDList = ifd0 + size(2), placeholder = subIFDList + 8
        let rawIFD = placeholder + size(4), stripStart = rawIFD + size(6)

        data.append(contentsOf: [0x49, 0x49])
        append16(42)
        append32(ifd0)
        directory([(254, long, 1, 1), (330, long, 2, subIFDList)])
        append32(placeholder)
        append32(rawIFD)
        directory([(254, long, 1, 1), (256, long, 1, 0), (259, short, 1, compression), (273, long, 1, 0)])
        directory([
            (254, long, 1, subfileType), (256, long, 1, width), (257, long, 1, 2672),
            (259, short, 1, compression), (273, long, 1, stripOffset ?? stripStart), (279, long, 1, strip.count),
        ])
        data.append(contentsOf: strip)
        return data
    }
}
