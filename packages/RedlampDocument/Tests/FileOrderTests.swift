import Foundation
import RedlampDocument
import Testing

struct FileOrderTests {
    /// The Finder's comparison: `localizedStandardCompare`, with the locale fixed to English, so the test doesn't
    /// depend on the Mac's language; it equals `localizedStandardCompare` in English and in ICU's root order.
    private static func finder(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs, options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering], range: nil,
            locale: Locale(identifier: "en"),
        )
    }

    private static func keyed(_ lhs: [UInt8], _ rhs: [UInt8]) -> ComparisonResult {
        lhs == rhs ? .orderedSame : lhs.lexicographicallyPrecedes(rhs) ? .orderedAscending : .orderedDescending
    }

    /// Photo names: digits of different lengths, leading zeros, punctuation, case and accents, and letters that sort
    /// as letters of their own or as others with a mark.
    private static let latinNames = product(
        [
            "DSC", "dsc", "IMG", "img", "Img", "photo", "Photo", "Café", "cafe", "CAFE", "café", "Cafe", "Été", "ete",
            "Zoë", "zoe", "Ölberg", "olberg", "Øresund", "oresund", "Æble", "aeble", "Łódź", "lodz", "İstanbul",
            "naïve", "naive", "Ñandú", "nandu", "þorn", "ŋa", "ð", "ə", "côte", "coté", "cote",
        ],
        ["", "_", "-", " ", ".", "–", "—", "  ", "(", ","],
        [
            "", "0", "00", "1", "01", "001", "2", "9", "09", "10", "010", "100", "5513", "05507", "123456789012",
            "18446744073709551615",
        ],
        ["", ".ARW", ".arw", ".jpg", ".JPG", "a", "A", " copy", " (2)", "é"],
    )

    /// Other scripts, kana and width, with numbers that have no leading zeros: the Finder lets a kana or width
    /// difference outweigh leading zeros in a way no order can follow (`cycles`).
    private static let otherNames = product(
        [
            "Ωμέγα", "ωμέγα", "Москва", "москва", "Ёлка", "ёлка", "елка", "Київ", "київ", "йод", "иод", "іод", "їжак",
            "東京", "大阪", "京都", "とうきょう", "トウキョウ", "かな", "カナ", "がっこう", "שלום", "מים", "مرحبا", "سلام",
            "नमस्ते", "हिंदी", "가나다", "하나", "ไทย", "กา", "เก", "Ｆｕｌｌ", "full", "FULL", "ｆｕｌｌ",
        ],
        ["", "_", " ", "-"],
        ["", "1", "2", "10", "100"],
        ["", ".jpg", ".JPG"],
    )

    private static func product(_ parts: [String]...) -> [String] {
        parts.reduce([""]) { names, part in names.flatMap { name in part.map { name + $0 } } }
    }

    /// Names drawn from `names` without repeats, the same for the same seed.
    private static func sample(_ names: [String], count: Int, using random: inout Xorshift) -> [String] {
        var remaining = names
        return (0 ..< count).map { _ in remaining.remove(at: Int(random.next() % UInt64(remaining.count))) }
    }

    @Test func `names sort as the Finder sorts them, for every pair of a wide set of names`() {
        var random = Xorshift(seed: 2026)
        let names = Array(Set(
            Self.sample(Self.latinNames, count: 700, using: &random)
                + Self.sample(Self.otherNames, count: 300, using: &random),
        ).subtracting([""])).sorted()
        let keys = names.map(FileOrder.key)
        var disagreements: [String] = []
        for left in names.indices {
            for right in left + 1 ..< names.count {
                let finder = Self.finder(names[left], names[right])
                if Self.keyed(keys[left], keys[right]) != finder {
                    disagreements.append("\(names[left]) and \(names[right])")
                }
            }
        }
        #expect(names.count > 990)
        #expect(disagreements.isEmpty, "\(disagreements.count) pairs: \(disagreements.prefix(20))")
    }

    @Test func `punctuation sorts before digits, digits by their numbers, letters ignoring case, accents and width`() {
        let ordered = [
            " a", "_a", "-a", ".a", "(a)", "0a", "9a", "10a", "a!", "a.jpg", "cafe", "Cafe", "café", "Café", "Cafe 2",
            "Café 10", "côte", "DSC 2", "DSC_5513", "DSC-2", "DSC–2", "DSC.2", "DSC0001.NEF", "DSC2", "DSC05507",
            "DSCa",
            "DSCF0001", "Ete", "Été 2", "Etude", "full", "ｆｕｌｌ", "Ｆｕｌｌ", "img_9.arw", "IMG_9.ARW", "IMG_009b.ARW",
            "IMG_10.ARW", "Ölberg.jpg", "Zoë", "þorn", "Ωμέγα", "Москва", "ა", "שלום", "مرحبا", "नमस्ते", "กา", "가나다",
            "かな", "カナ", "東京",
        ]
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            #expect(Self.finder(left, right) == .orderedAscending, "the Finder: \(left) before \(right)")
        }
        for seed in 0 ..< 20 {
            var random = Xorshift(seed: UInt64(seed + 1))
            #expect(ordered.shuffled(using: &random).sorted(by: FileOrder.precedes) == ordered, "seed \(seed)")
        }
    }

    @Test func `case and leading zeros decide by whichever differs first, and accents before either`() {
        for (left, right) in [
            ("img_1.jpg", "img_1.JPG"), ("img_1.JPG", "IMG_1.jpg"), ("img_01.jpg", "IMG_1.jpg"),
            ("IMG_1.jpg", "IMG_01.jpg"), ("a01B", "A1b"), ("a1B", "a01b"), ("A01e", "a1é"), ("CAFE", "café"),
        ] {
            #expect(Self.finder(left, right) == .orderedAscending, "the Finder: \(left) before \(right)")
            #expect(FileOrder.precedes(left, right), "\(left) before \(right)")
        }
        // Names that differ only in their characters are never the same.
        for (first, second) in [("Caf\u{E9}", "Cafe\u{301}"), ("a", "a\u{200B}")] {
            #expect(FileOrder.compare(first, second) == Self.finder(first, second), "\(first) and \(second)")
        }
    }

    /// Where the Finder's comparison isn't an order, so no key can follow it, and why.
    private static let cycles: [(names: [String], reason: String)] = [
        (
            ["a1Aカ", "a01aカ", "a01Aか"],
            "a hiragana or katakana difference outweighs an earlier leading zero, a leading zero an earlier case "
                + "difference, and case a kana difference",
        ),
        (
            ["Ａ1A", "Ａ01a", "A01A"],
            "a width difference outweighs a later leading zero, a leading zero a later case difference, and case a "
                + "width difference",
        ),
        (
            ["a100", "a１０(", "a99"],
            "fullwidth digits are compared with ASCII ones digit by digit where one run begins the other",
        ),
        (["ßz", "sst", "ssz"], "folding ß to ss misaligns what follows it"),
        (["ب", "ي", "ئ"], "yeh with hamza sorts before beh against beh, and after yeh against yeh"),
    ]

    /// Pairs the Finder puts after each other both ways round.
    private static let asymmetries: [(names: (String, String), reason: String)] = [
        (("간", "가다"), "a Hangul syllable's final consonant against the next syllable's first"),
        (("ΑΛΦΑ 1", "άλφα."), "folding an accented Greek letter misaligns what follows it"),
    ]

    @Test func `the names the Finder can't order consistently are listed, and the key orders them its own way`() {
        for (names, reason) in Self.cycles {
            let finder = zip(names, names.dropFirst() + names.prefix(1)).map { Self.finder($0, $1) }
            #expect(finder == [.orderedAscending, .orderedAscending, .orderedAscending], "a cycle: \(reason)")
            let sorted = names.sorted(by: FileOrder.precedes)
            #expect(zip(sorted, sorted.dropFirst()).allSatisfy { FileOrder.precedes($0, $1) }, "\(names)")
        }
        for ((first, second), reason) in Self.asymmetries {
            #expect(Self.finder(first, second) == Self.finder(second, first), "both ways round: \(reason)")
            #expect(FileOrder.compare(first, second) != FileOrder.compare(second, first))
        }
        // The Finder reads a run of digits into 64 bits, which wraps past 18446744073709551615.
        #expect(Self.finder("a18446744073709551617", "a2") == .orderedAscending)
        #expect(FileOrder.precedes("a2", "a18446744073709551617"))
        // Leading zeros are compared with case, by position, then width and kana: no order can follow the Finder's
        // width before a later zero, or kana over any zero, as well as its case over width and kana (the cycles).
        #expect(Self.finder("＿1", "_01") == .orderedDescending && FileOrder.precedes("＿1", "_01"))
        #expect(Self.finder("01か", "1カ") == .orderedAscending && FileOrder.precedes("1カ", "01か"))
    }

    @Test func `names sort as their keys do, whatever their digits, punctuation, case and accents`() {
        let pieces = [
            "a", "B", "z", "img", "_", "-", " ", ".", "~", "(", ":", "0", "1", "9", "007", "10", "é", "É", "e\u{301}",
            "\u{301}", "ß", "Ａ", "１", "–", "東", "か", "カ", "ｶ", "\u{1}",
        ]
        for seed in 1 ... 3 {
            var random = Xorshift(seed: UInt64(seed))
            let names = (0 ..< 300).map { _ in
                (0 ..< Int.random(in: 1 ... 6, using: &random)).map { _ in pieces.randomElement(using: &random) ?? "" }
                    .joined()
            }
            let keys = names.map(FileOrder.key)
            for (left, name) in names.enumerated() {
                for (right, other) in names.enumerated() {
                    #expect(
                        FileOrder.compare(name, other) == Self.keyed(keys[left], keys[right]),
                        "\(name) and \(other)",
                    )
                }
            }
        }
    }

    @Test func `the order holds across names beyond ASCII, as the old order mixing two comparisons didn't`() {
        // That one put a0 before a_é and a_é before a–, but a– before a0.
        let names = ["a_é", "a–", "a0"]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            #expect(order.map { names[$0] }.sorted(by: FileOrder.precedes) == names)
        }
    }
}

/// The same numbers for the same seed, so a failure can be run again.
private struct Xorshift: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
