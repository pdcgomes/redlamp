extension FileOrder {
    static let separator: UInt8 = 0x01
    /// The secondary and variant weight of a unit with nothing to say at that level.
    static let common: UInt8 = 0x02
    /// Primary weights: whitespace, punctuation and symbols below `digits` (`symbolOrder`), each ASCII one a byte
    /// and the others two, after a lead byte between the ASCII ones around them; a run of digits, `digits` plus the
    /// count of its significant digits up to 15, or `longDigits` and the count; numbers that aren't decimal digits;
    /// Latin letters, a to z, each with the letters that follow it after the byte after it; then other Latin
    /// letters, other scripts (`scripts`), Han, and anything else.
    static let digits: UInt8 = 0x50
    static let longDigits: UInt8 = 0x60
    static let otherNumber: UInt8 = 0x61
    static let letterA: UInt8 = 0x63
    static let otherLatin: UInt8 = 0x97
    static let greek: UInt8 = 0xA0
    static let cyrillic: UInt8 = 0xA2
    static let armenian: UInt8 = 0xA5
    static let hebrew: UInt8 = 0xA6
    static let arabic: UInt8 = 0xA8
    static let hangul: UInt8 = 0xC2
    static let kana: UInt8 = 0xC3
    static let han: UInt8 = 0xD0
    static let otherLetter: UInt8 = 0xE0
    static let other: UInt8 = 0xE1
    /// The second byte of a symbol the table doesn't list, which three bytes of its code point follow.
    static let unlisted: UInt8 = 0xF0

    /// Variants, after case and leading zeros: the Finder's tertiary differences.
    enum Variant {
        static let wide: UInt8 = 1
        static let compat: UInt8 = 2
        static let font: UInt8 = 3
        static let circle: UInt8 = 4
        static let katakana: UInt8 = 5
        static let narrow: UInt8 = 6
        static let superscriptForm: UInt8 = 7
        static let subscriptForm: UInt8 = 8
        static let vertical: UInt8 = 9
        static let final: UInt8 = 10
        static let small: UInt8 = 12
        static let square: UInt8 = 13
        static let fraction: UInt8 = 14
        static let unlistedSpace: UInt8 = 0x40
    }

    static func letter(_ index: Int) -> UInt8 {
        letterA + UInt8(2 * index)
    }

    /// A symbol's primary weight, one or two bytes, and its variant.
    struct Symbol {
        var lead: UInt8
        var rank: UInt8?
        var variant: UInt8

        func append(to key: inout ContiguousArray<UInt8>) {
            key.append(lead)
            if let rank {
                key.append(rank)
            }
        }
    }

    /// The symbol table laid out in weights: each ASCII character's primary weight (0 for controls, which have
    /// none), every other listed character's, and the lead bytes of the kinds the table doesn't list.
    struct SymbolLayout {
        var ascii = [UInt8](repeating: 0, count: 128)
        var symbols: [UInt32: Symbol] = [:]
        var unlisted: [SymbolKind: UInt8] = [:]

        init() {
            var lead: UInt8 = 0x02
            var rank: UInt8 = 0
            for entry in symbolOrder {
                switch entry {
                case let .unknown(kind):
                    unlisted[kind] = lead
                    rank = FileOrder.unlisted + 1
                case let .group(characters):
                    let symbol: Symbol
                    if characters[0] < 0x80 {
                        symbol = Symbol(lead: lead + 1, rank: nil, variant: 0)
                        lead += 2
                        rank = 0
                    } else {
                        symbol = Symbol(lead: lead, rank: rank, variant: 0)
                        rank += 1
                    }
                    for (variant, character) in characters.enumerated() {
                        var weighted = symbol
                        weighted.variant = UInt8(variant)
                        if character < 0x80 {
                            ascii[Int(character)] = symbol.lead
                        } else {
                            symbols[character] = weighted
                        }
                    }
                }
            }
            precondition(lead < digits, "the symbols' weights run into the digits'")
            for (offset, letter) in (UInt8(ascii: "a") ... UInt8(ascii: "z")).enumerated() {
                ascii[Int(letter)] = FileOrder.letter(offset)
                ascii[Int(letter - 0x20)] = FileOrder.letter(offset)
            }
            for digit in UInt8(ascii: "0") ... UInt8(ascii: "9") {
                ascii[Int(digit)] = digits
            }
        }
    }

    static let symbolLayout = SymbolLayout()
    static let asciiWeights = symbolLayout.ascii
    static let symbols = symbolLayout.symbols

    /// Each combining mark's secondary weight, from 0x04 in steps of 2, leaving room after a mark for the stroke and
    /// ligature marks of the letters that don't decompose.
    static let markWeights: [UInt32: UInt8] = {
        var weights: [UInt32: UInt8] = [:]
        for (index, group) in markOrder.enumerated() {
            for mark in group {
                weights[mark] = 0x04 + UInt8(2 * index)
            }
        }
        return weights
    }()

    static let strokeOverlay = markWeights[0x0338, default: 0] + 1
    static let shortStroke = markWeights[0x0335, default: 0] + 1
    static let ligature = markWeights[0x0361, default: 0] + 1
    /// A mark the table doesn't list.
    static let unlistedMark: UInt8 = 0xF0

    /// How a Latin letter that doesn't decompose sorts: as a letter of its own after one from a to z, as one of
    /// them with a secondary mark, or as two of them with one between (æ as a, a mark and e).
    enum LatinLetter {
        case own(after: Int, rank: UInt8)
        case marked(Int, mark: UInt8, variant: UInt8)
        case expansion(Int, mark: UInt8, Int)
    }

    static let latinLetters: [UInt32: LatinLetter] = {
        func index(_ letter: Character) -> Int {
            Int(letter.asciiValue! - UInt8(ascii: "a"))
        }
        var letters: [UInt32: LatinLetter] = [:]
        for (after, gap) in latinAfter.enumerated() {
            for (rank, letter) in gap.enumerated() {
                letters[letter] = .own(after: after, rank: UInt8(rank))
            }
        }
        letters[0x00F8] = .marked(index("o"), mark: strokeOverlay, variant: 0) // ø
        letters[0x0111] = .marked(index("d"), mark: shortStroke, variant: 0) // đ
        letters[0x0127] = .marked(index("h"), mark: shortStroke, variant: 0) // ħ
        letters[0x0142] = .marked(index("l"), mark: shortStroke, variant: 0) // ł
        letters[0x00F0] = .marked(index("d"), mark: ligature, variant: 0) // ð
        letters[0x0140] = .marked(index("l"), mark: ligature, variant: Variant.compat) // ŀ
        letters[0x017F] = .marked(index("s"), mark: common, variant: Variant.compat) // ſ
        letters[0x00E6] = .expansion(index("a"), mark: ligature, index("e")) // æ
        letters[0x0153] = .expansion(index("o"), mark: ligature, index("e")) // œ
        letters[0x00DF] = .expansion(index("s"), mark: ligature, index("s")) // ß
        return letters
    }()

    /// A letter's rank among its script's letters, and its place in its group (`greekOrder`, `cyrillicOrder`).
    static func ranks(_ order: [[UInt32]]) -> [UInt32: (rank: Int, place: Int)] {
        var ranks: [UInt32: (rank: Int, place: Int)] = [:]
        for (rank, group) in order.enumerated() {
            for (place, letter) in group.enumerated() {
                ranks[letter] = (rank, place)
            }
        }
        return ranks
    }

    static let greekRanks = ranks(greekOrder)
    static let cyrillicRanks = ranks(cyrillicOrder)

    /// Small kana and the kana they're small forms of.
    static let smallKana: [UInt32: UInt32] = [
        0x3041: 0x3042, 0x3043: 0x3044, 0x3045: 0x3046, 0x3047: 0x3048, 0x3049: 0x304A, 0x3063: 0x3064,
        0x3083: 0x3084, 0x3085: 0x3086, 0x3087: 0x3088, 0x308E: 0x308F, 0x3095: 0x304B, 0x3096: 0x3051,
        0x31F0: 0x304F, 0x31F1: 0x3057, 0x31F2: 0x3059, 0x31F3: 0x3068, 0x31F4: 0x306C, 0x31F5: 0x306F,
        0x31F6: 0x3072, 0x31F7: 0x3075, 0x31F8: 0x3078, 0x31F9: 0x307B, 0x31FA: 0x3080, 0x31FB: 0x3089,
        0x31FC: 0x308A, 0x31FD: 0x308B, 0x31FE: 0x308C, 0x31FF: 0x308D,
    ]

    /// Persian and Urdu letters after the Arabic letters they follow, in ranks of four per Arabic letter.
    static let arabicRanks: [UInt32: Int] = [
        0x067E: 4 * 0x28 + 1, 0x0679: 4 * 0x2A + 1, 0x0686: 4 * 0x2C + 1, 0x0688: 4 * 0x2F + 1,
        0x0691: 4 * 0x31 + 1, 0x0698: 4 * 0x32 + 1, 0x06A9: 4 * 0x43 + 1, 0x06AF: 4 * 0x43 + 2,
        0x06BA: 4 * 0x46 + 1, 0x06BE: 4 * 0x47 + 1, 0x06C1: 4 * 0x47 + 2, 0x06CC: 4 * 0x4A + 1,
        0x06D2: 4 * 0x4A + 2,
    ]

    /// Hebrew final forms and the letters they're the final forms of.
    static let hebrewFinals: [UInt32: UInt32] = [
        0x05DA: 0x05DB, 0x05DD: 0x05DE, 0x05DF: 0x05E0, 0x05E3: 0x05E4, 0x05E5: 0x05E6,
    ]

    /// Each script's lead byte, the code point its ranks count from and the blocks it's written in, in ICU's order of
    /// scripts after Latin.
    struct Script {
        var lead: UInt8
        var base: UInt32
        var blocks: [ClosedRange<UInt32>]

        init(_ lead: UInt8, _ base: UInt32, _ blocks: [ClosedRange<UInt32>]) {
            self.lead = lead
            self.base = base
            self.blocks = blocks
        }
    }

    static let scripts: [Script] = [
        Script(greek, 0x0370, [0x0370 ... 0x03FF, 0x1F00 ... 0x1FFF]),
        Script(0xA1, 0x2C80, [0x2C80 ... 0x2CFF]), // Coptic
        Script(cyrillic, 0x0400, [0x0400 ... 0x052F, 0x1C80 ... 0x1C8F, 0x2DE0 ... 0x2DFF, 0xA640 ... 0xA69F]),
        Script(0xA3, 0x2C00, [0x2C00 ... 0x2C5F]), // Glagolitic
        Script(0xA4, 0x10A0, [0x10A0 ... 0x10FF, 0x1C90 ... 0x1CBF, 0x2D00 ... 0x2D2F]), // Georgian
        Script(armenian, 0x0530, [0x0530 ... 0x058F, 0xFB13 ... 0xFB17]),
        Script(hebrew, 0x0590, [0x0590 ... 0x05FF, 0xFB1D ... 0xFB4F]),
        Script(0xA7, 0x0800, [0x0800 ... 0x083F]), // Samaritan
        Script(
            arabic,
            0x0600,
            [0x0600 ... 0x06FF, 0x0750 ... 0x077F, 0x08A0 ... 0x08FF, 0xFB50 ... 0xFDFF, 0xFE70 ... 0xFEFF],
        ),
        Script(0xA9, 0x0700, [0x0700 ... 0x074F]), // Syriac
        Script(0xAA, 0x0780, [0x0780 ... 0x07BF]), // Thaana
        Script(0xAB, 0x07C0, [0x07C0 ... 0x07FF]), // N'Ko
        Script(0xAC, 0x2D30, [0x2D30 ... 0x2D7F]), // Tifinagh
        Script(0xAD, 0x1200, [0x1200 ... 0x139F, 0x2D80 ... 0x2DDF, 0xAB00 ... 0xAB2F]), // Ethiopic
        Script(0xAE, 0x0900, [0x0900 ... 0x097F, 0xA8E0 ... 0xA8FF]), // Devanagari
        Script(0xAF, 0x0980, [0x0980 ... 0x09FF]), // Bengali
        Script(0xB0, 0x0A00, [0x0A00 ... 0x0A7F]), // Gurmukhi
        Script(0xB1, 0x0A80, [0x0A80 ... 0x0AFF]), // Gujarati
        Script(0xB2, 0x0B00, [0x0B00 ... 0x0B7F]), // Oriya
        Script(0xB3, 0x0B80, [0x0B80 ... 0x0BFF]), // Tamil
        Script(0xB4, 0x0C00, [0x0C00 ... 0x0C7F]), // Telugu
        Script(0xB5, 0x0C80, [0x0C80 ... 0x0CFF]), // Kannada
        Script(0xB6, 0x0D00, [0x0D00 ... 0x0D7F]), // Malayalam
        Script(0xB7, 0x0D80, [0x0D80 ... 0x0DFF]), // Sinhala
        Script(0xB8, 0x0E00, [0x0E00 ... 0x0E7F]), // Thai
        Script(0xB9, 0x0E80, [0x0E80 ... 0x0EFF]), // Lao
        Script(0xBA, 0x0F00, [0x0F00 ... 0x0FFF]), // Tibetan
        Script(0xBB, 0x1000, [0x1000 ... 0x109F]), // Myanmar
        Script(0xBC, 0x1780, [0x1780 ... 0x17FF]), // Khmer
        Script(0xBD, 0x1800, [0x1800 ... 0x18AF]), // Mongolian
        Script(0xBE, 0x13A0, [0x13A0 ... 0x13FF, 0xAB70 ... 0xABBF]), // Cherokee
        Script(0xBF, 0x1400, [0x1400 ... 0x167F]), // Canadian syllabics
        Script(0xC0, 0x1680, [0x1680 ... 0x169F]), // Ogham
        Script(0xC1, 0x16A0, [0x16A0 ... 0x16FF]), // Runic
        Script(0xC4, 0x3100, [0x3100 ... 0x312F, 0x31A0 ... 0x31BF]), // Bopomofo
        Script(0xC5, 0xA000, [0xA000 ... 0xA4CF]), // Yi
    ]

    static func scriptLead(of value: UInt32) -> (lead: UInt8, base: UInt32)? {
        scripts.first { $0.blocks.contains { $0.contains(value) } }.map { ($0.lead, $0.base) }
    }

    /// Marks that are letters' own primary weights in the scripts that write vowels and tone with them, unless they
    /// only change a letter: a nukta, and Thai and Lao tone marks.
    static func isPrimaryMark(_ value: UInt32) -> Bool {
        switch value {
        case 0x093C, 0x09BC, 0x0A3C, 0x0ABC, 0x0B3C, 0x0C3C, 0x0CBC, 0x0E47 ... 0x0E4E, 0x0EC8 ... 0x0ECD: false
        case 0x0900 ... 0x0DFF, 0x0E00 ... 0x0EFF, 0x0F00 ... 0x0FFF, 0x1000 ... 0x109F, 0x1780 ... 0x17FF: true
        default: false
        }
    }

    /// The secondary weight of a mark that isn't a primary weight: the table's, those of Hebrew, Arabic, Thai and Lao
    /// by code point, and the same for any other.
    static func markWeight(_ value: UInt32) -> UInt8 {
        if let weight = markWeights[value] {
            return weight
        }
        switch value {
        case 0x0591 ... 0x05C7: return 0x80 + UInt8(value - 0x0591)
        case 0x064B ... 0x065F: return 0xC0 + UInt8(value - 0x064B)
        case 0x0670: return 0xD5
        case 0x0E47 ... 0x0E4E: return 0xD8 + UInt8(value - 0x0E47)
        case 0x0EC8 ... 0x0ECD: return 0xE0 + UInt8(value - 0x0EC8)
        default: return unlistedMark
        }
    }

    /// Characters with no weight at all: format controls, variation selectors, the grapheme joiner and tatweel.
    static func isIgnorable(_ value: UInt32, _ properties: Unicode.Scalar.Properties) -> Bool {
        switch value {
        case 0x034F, 0x0640, 0xFE00 ... 0xFE0F, 0xE0100 ... 0xE01EF: true
        default:
            switch properties.generalCategory {
            case .control, .format, .surrogate: true
            default: false
            }
        }
    }

    /// The variant of the characters a compatibility decomposition gives, by the block of what's decomposed.
    static func compatibilityVariant(of value: UInt32) -> UInt8 {
        switch value {
        case 0xFF01 ... 0xFF5E, 0xFFE0 ... 0xFFE6, 0x3000: Variant.wide
        case 0xFF61 ... 0xFFDC, 0xFFE8 ... 0xFFEE: Variant.narrow
        case 0x2460 ... 0x24FF, 0x2776 ... 0x2793, 0x3200 ... 0x32FF, 0x1F100 ... 0x1F1FF: Variant.circle
        case 0x00B2, 0x00B3, 0x00B9, 0x00AA, 0x00BA, 0x2070 ... 0x207F, 0x2122, 0x2120, 0x1D2C ... 0x1D61:
            Variant.superscriptForm
        case 0x2080 ... 0x209F, 0x1D62 ... 0x1D6A: Variant.subscriptForm
        case 0xFE10 ... 0xFE19, 0xFE30 ... 0xFE4F: Variant.vertical
        case 0xFE50 ... 0xFE6B: Variant.small
        case 0x3300 ... 0x33FF: Variant.square
        case 0x00BC ... 0x00BE, 0x2150 ... 0x215F, 0x2189: Variant.fraction
        case 0x1D400 ... 0x1D7FF, 0x2102 ... 0x2149: Variant.font
        default: Variant.compat
        }
    }
}

extension FileOrder {
    /// Hangul: a syllable as its leading consonant, vowel (one more, so a consonant alone comes first) and final
    /// consonant, its jamo put together again after canonical decomposition took it apart.
    static func appendJamo(
        of scalars: [Unicode.Scalar], at index: Int, to primary: inout ContiguousArray<UInt8>,
    ) -> Int {
        let value = scalars[index].value
        var next = index + 1
        primary.append(hangul)
        if value <= 0x1112, next < scalars.count, (0x1161 ... 0x1175).contains(scalars[next].value) {
            primary.append(UInt8(value - 0x1100))
            primary.append(UInt8(scalars[next].value - 0x1161 + 1))
            next += 1
            if next < scalars.count, (0x11A8 ... 0x11C2).contains(scalars[next].value) {
                primary.append(UInt8(scalars[next].value - 0x11A7))
                next += 1
            } else {
                primary.append(0)
            }
        } else if value < 0x1160 {
            primary.append(contentsOf: [UInt8(value - 0x1100), 0, 0])
        } else if value < 0x11A8 {
            primary.append(contentsOf: [0x7F, UInt8(value - 0x1160 + 1), 0])
        } else {
            primary.append(contentsOf: [0x7F, 0, UInt8(value - 0x11A7)])
        }
        return next
    }

    /// Compatibility jamo: a consonant as the leading consonant alone, a cluster after its first consonant, a
    /// vowel as a vowel alone.
    static func appendCompatibilityJamo(_ value: UInt32, to primary: inout ContiguousArray<UInt8>) {
        // Leading consonants for ㄱ to ㅎ, a cluster's first consonant with 0x80.
        let consonants: [UInt8] = [
            0, 1, 0x80, 2, 0x82, 0x82, 3, 4, 5, 0x85, 0x85, 0x85, 0x85, 0x85, 0x85, 0x85, 6, 7, 8, 0x87, 9, 10, 11,
            12, 13, 14, 15, 16, 17, 18,
        ]
        primary.append(hangul)
        let offset = Int(value - 0x3131)
        if offset < consonants.count {
            let consonant = consonants[offset]
            primary.append(contentsOf: [consonant & 0x7F, 0, consonant & 0x80 == 0 ? 0 : 0x40 + UInt8(offset)])
        } else {
            primary.append(contentsOf: [0x7F, UInt8(min(offset - consonants.count + 1, 0x7E)), 0])
        }
    }
}
