import Foundation

extension FileOrder {
    /// A letter as the order reads it: lowercased, its case for the tie if it has one, and the variant of the
    /// compatibility decomposition it's in, if any.
    struct Letter {
        var lower: UInt32
        var tie: UInt8?
        var compatibility: UInt8?
    }

    /// A name beyond ASCII keyed unit by unit, a character or a run of digits, after canonical decomposition: its
    /// primary weights and the levels after them, each unit's secondary weight (common, then its marks'), the case or
    /// leading zeros of each cased letter, kana and run of digits (`TieBits`), and each unit's variant.
    struct UnicodeKey {
        var primary = ContiguousArray<UInt8>()
        var secondary = ContiguousArray<UInt8>()
        /// The tie level's units: 1 for an uppercase letter or large kana, 0 for a lowercase or small one, or minus
        /// one less than a run's leading zeros.
        var ties: [Int] = []
        var variants = ContiguousArray<UInt8>()

        mutating func append(_ name: String) {
            let scalars = Array(name.decomposedStringWithCanonicalMapping.unicodeScalars)
            var index = 0
            while index < scalars.count {
                index = appendUnit(of: scalars, at: index, compatibility: nil)
            }
        }

        /// Appends the key: the primary weights, the levels after them, and `name`'s UTF-16 code units.
        func finish(_ name: String, to key: inout ContiguousArray<UInt8>) {
            func trimmed(_ level: ContiguousArray<UInt8>) -> ArraySlice<UInt8> {
                ArraySlice(level[..<(level.lastIndex { $0 != common }.map { $0 + 1 } ?? 0)])
            }
            key.append(contentsOf: primary)
            key.append(separator)
            key.append(contentsOf: trimmed(secondary))
            key.append(separator)
            appendTies(to: &key)
            key.append(separator)
            key.append(contentsOf: trimmed(variants))
            key.append(separator)
            for unit in name.utf16 {
                key.append(UInt8(unit >> 8))
                key.append(UInt8(truncatingIfNeeded: unit))
            }
        }

        private func appendTies(to key: inout ContiguousArray<UInt8>) {
            var lastSet = 0
            var bits = 0
            for tie in ties {
                if tie >= 0 {
                    bits += 1
                    lastSet = tie > 0 ? bits : lastSet
                } else {
                    bits -= tie
                    lastSet = tie < -1 ? bits - 1 : lastSet
                }
            }
            guard lastSet > 0 else { return }
            var tieBits = TieBits()
            for tie in ties where tieBits.count < lastSet {
                if tie >= 0 {
                    tieBits.append(tie > 0, to: &key)
                } else {
                    tieBits.append(zeros: -1 - tie, upTo: lastSet, to: &key)
                }
            }
            tieBits.finish(to: &key)
        }

        mutating func unit(tie: UInt8?, variant: UInt8) {
            secondary.append(common)
            if let tie {
                ties.append(Int(tie))
            }
            variants.append(common + variant)
        }

        mutating func append(_ lead: UInt8, rank: Int) {
            primary.append(lead)
            primary.append(UInt8(truncatingIfNeeded: rank >> 8))
            primary.append(UInt8(truncatingIfNeeded: rank))
        }

        mutating func append(_ lead: UInt8, codePoint value: UInt32) {
            primary.append(lead)
            primary.append(UInt8(truncatingIfNeeded: value >> 16))
            primary.append(UInt8(truncatingIfNeeded: value >> 8))
            primary.append(UInt8(truncatingIfNeeded: value))
        }

        /// Appends the unit at `index` and returns the index after it. Within a compatibility decomposition,
        /// `compatibility` is its variant, and digits aren't decimal.
        mutating func appendUnit(of scalars: [Unicode.Scalar], at index: Int, compatibility: UInt8?) -> Int {
            let scalar = scalars[index]
            let value = scalar.value
            if value < 0x80 {
                return appendASCII(of: scalars, at: index, compatibility: compatibility)
            }
            if let symbol = symbols[value] {
                symbol.append(to: &primary)
                unit(tie: nil, variant: compatibility ?? symbol.variant)
                return index + 1
            }
            let properties = scalar.properties
            if isIgnorable(value, properties) {
                return index + 1
            }
            switch properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                appendMark(value, compatibility: compatibility)
                return index + 1
            default:
                break
            }
            if properties.numericType == .decimal {
                return appendDigits(of: scalars, at: index, compatibility: compatibility)
            }
            if let next = appendLetter(of: scalars, at: index, compatibility: compatibility) {
                return next
            }
            if !appendDecomposition(of: scalar, compatibility: compatibility) {
                appendUnlisted(scalar, compatibility: compatibility)
            }
            return index + 1
        }

        private mutating func appendASCII(of scalars: [Unicode.Scalar], at index: Int, compatibility: UInt8?) -> Int {
            let value = scalars[index].value
            let weight = asciiWeights[Int(value)]
            if weight == 0 {
                return index + 1
            }
            if weight == digits {
                return appendDigits(of: scalars, at: index, compatibility: compatibility)
            }
            primary.append(weight)
            unit(tie: weight >= letterA ? (value < 0x61 ? 1 : 0) : nil, variant: compatibility ?? 0)
            return index + 1
        }

        private mutating func appendMark(_ value: UInt32, compatibility: UInt8?) {
            if isPrimaryMark(value), let (lead, base) = scriptLead(of: value) {
                append(lead, rank: Int(value - base))
                unit(tie: nil, variant: compatibility ?? 0)
            } else {
                secondary.append(markWeight(value))
            }
        }

        /// Appends a run of decimal digits as its number (`appendRun`), a single zero for a run of zeros, its leading
        /// zeros for the tie. In a compatibility decomposition each digit is a number that isn't decimal, as ICU has
        /// them.
        private mutating func appendDigits(of scalars: [Unicode.Scalar], at index: Int, compatibility: UInt8?) -> Int {
            func digit(_ scalar: Unicode.Scalar) -> UInt8? {
                guard scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue else {
                    return nil
                }
                return UInt8(value)
            }
            if let compatibility {
                primary.append(otherNumber)
                primary.append(0x30 + (digit(scalars[index]) ?? 0))
                unit(tie: nil, variant: compatibility)
                return index + 1
            }
            var end = index
            var values: [UInt8] = []
            while end < scalars.count, let value = digit(scalars[end]) {
                values.append(value)
                end += 1
            }
            let zeros = values.dropLast().prefix { $0 == 0 }.count
            appendRun(values[zeros...].map { 0x30 + $0 }, to: &primary)
            secondary.append(common)
            ties.append(-1 - zeros)
            variants.append(common + ((0xFF10 ... 0xFF19).contains(scalars[index].value) ? Variant.wide : 0))
            return end
        }

        /// Appends a letter of Latin or another script the order knows, and returns the index after it; nil for one
        /// it doesn't, which goes by its compatibility decomposition if it has one.
        mutating func appendLetter(of scalars: [Unicode.Scalar], at index: Int, compatibility: UInt8?) -> Int? {
            let scalar = scalars[index]
            let value = scalar.value
            let properties = scalar.properties
            let lower = properties.changesWhenLowercased
                ? properties.lowercaseMapping.unicodeScalars.first?.value ?? value : value
            let letter = Letter(
                lower: lower, tie: properties.isCased ? (properties.changesWhenLowercased ? 1 : 0) : nil,
                compatibility: compatibility,
            )
            if (0xFF21 ... 0xFF3A).contains(value) || (0xFF41 ... 0xFF5A).contains(value) {
                primary.append(asciiWeights[Int(value - 0xFEE0)])
                unit(tie: letter.tie, variant: compatibility ?? Variant.wide)
                return index + 1
            }
            if let latin = latinLetters[lower] {
                appendLatin(latin, letter)
                return index + 1
            }
            if let next = appendScriptLetter(of: scalars, at: index, letter) {
                return next
            }
            if properties.isUnifiedIdeograph || (0x3005 ... 0x3007).contains(lower) {
                // 々, 〆 and 〇 come before the ideographs.
                primary.append(han + UInt8(truncatingIfNeeded: lower >> 16))
                primary.append(UInt8(truncatingIfNeeded: lower >> 8))
                primary.append(UInt8(truncatingIfNeeded: lower))
                unit(tie: nil, variant: compatibility ?? 0)
                return index + 1
            }
            guard properties.isAlphabetic || properties.generalCategory == .otherLetter,
                  String(scalar).decomposedStringWithCompatibilityMapping.unicodeScalars
                  .elementsEqual(CollectionOfOne(scalar)) else { return nil }
            return appendOtherLetter(letter, at: index)
        }

        private mutating func appendLatin(_ latin: LatinLetter, _ letter: Letter) {
            let variant = letter.compatibility ?? 0
            switch latin {
            case let .own(after, rank):
                primary.append(FileOrder.letter(after) + 1)
                primary.append(rank)
                unit(tie: letter.tie, variant: variant)
            case let .marked(base, mark, letterVariant):
                primary.append(FileOrder.letter(base))
                unit(tie: letter.tie, variant: letter.compatibility ?? letterVariant)
                if mark != common {
                    secondary.append(mark)
                }
            case let .expansion(first, mark, second):
                primary.append(FileOrder.letter(first))
                unit(tie: letter.tie, variant: variant)
                secondary.append(mark)
                primary.append(FileOrder.letter(second))
                unit(tie: letter.tie, variant: variant)
            }
        }

        /// Appends a letter of a script with an order of its own, and returns the index after it.
        private mutating func appendScriptLetter(of scalars: [Unicode.Scalar], at index: Int, _ letter: Letter)
            -> Int? {
            let lower = letter.lower
            let variant = letter.compatibility ?? 0
            switch lower {
            case 0x0370 ... 0x03FF:
                guard let (rank, place) = greekRanks[lower] else { return nil }
                append(greek, rank: rank)
                unit(tie: letter.tie, variant: letter.compatibility ?? UInt8(place))
                return index + 1
            case 0x0400 ... 0x052F:
                return appendCyrillic(of: scalars, at: index, letter)
            case 0x0561 ... 0x0586:
                append(armenian, rank: Int(lower - 0x0530))
                unit(tie: letter.tie, variant: variant)
                return index + 1
            case 0x05D0 ... 0x05EA:
                let base = hebrewFinals[lower] ?? lower
                append(hebrew, rank: Int(base - 0x0590))
                unit(tie: nil, variant: letter.compatibility ?? (base == lower ? 0 : Variant.final))
                return index + 1
            case 0x0620 ... 0x064A, 0x0671 ... 0x06D3:
                append(arabic, rank: arabicRanks[lower] ?? 4 * Int(lower - 0x0600))
                unit(tie: nil, variant: variant)
                return index + 1
            case 0x0E40 ... 0x0E44, 0x0EC0 ... 0x0EC4:
                return appendPrevowel(of: scalars, at: index, letter)
            case 0x1100 ... 0x11FF:
                let next = FileOrder.appendJamo(of: scalars, at: index, to: &primary)
                unit(tie: nil, variant: variant)
                return next
            case 0x3131 ... 0x318E:
                FileOrder.appendCompatibilityJamo(lower, to: &primary)
                unit(tie: nil, variant: letter.compatibility ?? Variant.compat)
                return index + 1
            case 0x3041 ... 0x3096, 0x30A1 ... 0x30F6, 0x31F0 ... 0x31FF:
                appendKana(letter)
                return index + 1
            default:
                return nil
            }
        }

        private mutating func appendCyrillic(of scalars: [Unicode.Scalar], at index: Int, _ letter: Letter) -> Int? {
            // й is a letter of its own, which canonical decomposition makes и and a breve.
            let shortI = letter.lower == 0x0438 && index + 1 < scalars.count && scalars[index + 1].value == 0x0306
            guard let (rank, place) = cyrillicRanks[shortI ? 0x0439 : letter.lower] else { return nil }
            append(cyrillic, rank: rank)
            unit(tie: letter.tie, variant: letter.compatibility ?? 0)
            if place > 0 {
                secondary.append(ligature + UInt8(place))
            }
            return shortI ? index + 2 : index + 1
        }

        /// A Thai or Lao vowel written before its consonant sorts after it.
        private mutating func appendPrevowel(of scalars: [Unicode.Scalar], at index: Int, _ letter: Letter) -> Int? {
            let consonants: ClosedRange<UInt32> = letter.lower < 0x0E80 ? 0x0E01 ... 0x0E2E : 0x0E81 ... 0x0EAE
            guard index + 1 < scalars.count, consonants.contains(scalars[index + 1].value),
                  let (lead, base) = scriptLead(of: letter.lower) else { return nil }
            append(lead, rank: Int(scalars[index + 1].value - base))
            unit(tie: nil, variant: letter.compatibility ?? 0)
            append(lead, rank: Int(letter.lower - base))
            unit(tie: nil, variant: letter.compatibility ?? 0)
            return index + 2
        }

        /// Hiragana and katakana as one, a small kana as its large one with a lowercase tie, katakana as a variant.
        private mutating func appendKana(_ letter: Letter) {
            let lower = letter.lower
            let isKatakana = lower >= 0x30A1 && lower <= 0x30F6 || lower >= 0x31F0
            let kana = lower >= 0x30A1 && lower <= 0x30F6 ? lower - 0x60 : lower
            let large = smallKana[kana] ?? kana
            append(FileOrder.kana, rank: Int(large - 0x3040))
            unit(tie: large == kana ? 1 : 0, variant: letter.compatibility ?? (isKatakana ? Variant.katakana : 0))
        }

        /// A letter the tables don't list: after the listed ones of its script, or among the other Latin letters.
        private mutating func appendOtherLetter(_ letter: Letter, at index: Int) -> Int? {
            let lower = letter.lower
            if let (lead, base) = scriptLead(of: lower) {
                let unlisted = lead == greek || lead == cyrillic ? 0x1000 : 0
                append(lead, rank: Int(lower - base) + unlisted)
            } else if (0x00C0 ... 0x02AF).contains(lower) || (0x1D00 ... 0x1EFF).contains(lower)
                || (0x2C60 ... 0x2C7F).contains(lower) || (0xA720 ... 0xA7FF).contains(lower) {
                append(otherLatin, codePoint: lower)
            } else {
                return nil
            }
            unit(tie: letter.tie, variant: letter.compatibility ?? 0)
            return index + 1
        }

        /// A character with a compatibility decomposition goes by it, with its variant; false for one without.
        private mutating func appendDecomposition(of scalar: Unicode.Scalar, compatibility: UInt8?) -> Bool {
            let decomposed = String(scalar).decomposedStringWithCompatibilityMapping.unicodeScalars
            guard decomposed.count > 1 || decomposed.first != scalar else { return false }
            let parts = Array(decomposed)
            let variant = compatibility ?? compatibilityVariant(of: scalar.value)
            var part = 0
            while part < parts.count {
                part = appendUnit(of: parts, at: part, compatibility: variant)
            }
            return true
        }

        /// A character the tables don't list: after the listed ones of its kind, by code point.
        private mutating func appendUnlisted(_ scalar: Unicode.Scalar, compatibility: UInt8?) {
            let value = scalar.value
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                 .finalPunctuation, .otherPunctuation:
                primary.append(symbolLayout.unlisted[.punctuation, default: other])
                append(unlisted, codePoint: value)
            case .mathSymbol, .modifierSymbol, .otherSymbol:
                primary.append(symbolLayout.unlisted[.symbol, default: other])
                append(unlisted, codePoint: value)
            case .currencySymbol:
                primary.append(symbolLayout.unlisted[.currency, default: other])
                append(unlisted, codePoint: value)
            case .spaceSeparator:
                primary.append(asciiWeights[0x20])
                unit(tie: nil, variant: compatibility ?? Variant.unlistedSpace)
                return
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber,
                 .otherNumber:
                append(otherLetter, codePoint: value)
            default:
                append(other, codePoint: value)
            }
            unit(tie: nil, variant: compatibility ?? 0)
        }
    }
}
