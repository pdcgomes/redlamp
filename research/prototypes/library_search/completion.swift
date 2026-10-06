// Fuzzy matching and typos over the library's small tables, from fzf's published first algorithm (MIT),
// Hyyrö's bit-parallel LCS (2004) and restricted Damerau-Levenshtein distance.
import Darwin
import Foundation

struct Name {
    let text: String
    let table: String
    let folded: ContiguousArray<UInt8>
    let mask: UInt64
    let starts: UInt64
    /// Runs of letters (bytes past ASCII count as letters), where a typo may sit.
    let words: [Range<Int>]
}

func fold(_ text: String) -> ContiguousArray<UInt8> {
    ContiguousArray(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        .precomposedStringWithCanonicalMapping.utf8)
}

func letterMask(_ bytes: ContiguousArray<UInt8>) -> UInt64 {
    var mask: UInt64 = 0
    for byte in bytes {
        switch byte {
        case 0x61 ... 0x7A: mask |= 1 << UInt64(byte - 0x61)
        case 0x30 ... 0x39: mask |= 1 << UInt64(26 + byte - 0x30)
        default: break
        }
    }
    return mask
}

@inline(__always) func isLetterByte(_ byte: UInt8) -> Bool {
    (0x61 ... 0x7A).contains(byte) || byte >= 0x80
}

@inline(__always) func isDigitByte(_ byte: UInt8) -> Bool {
    (0x30 ... 0x39).contains(byte)
}

@inline(__always) func isAlphanumericByte(_ byte: UInt8) -> Bool {
    isLetterByte(byte) || isDigitByte(byte)
}

func wordStarts(_ bytes: ContiguousArray<UInt8>) -> UInt64 {
    var starts: UInt64 = 0
    for index in 0 ..< min(bytes.count, 64) where isAlphanumericByte(bytes[index]) {
        if index == 0 {
            starts |= 1
            continue
        }
        let before = bytes[index - 1]
        if !isAlphanumericByte(before) || isLetterByte(bytes[index]) != isLetterByte(before) {
            starts |= 1 << UInt64(index)
        }
    }
    return starts
}

func makeName(_ text: String, _ table: String) -> Name {
    let folded = fold(text)
    var words: [Range<Int>] = []
    var index = 0
    while index < folded.count {
        guard isLetterByte(folded[index]) else {
            index += 1
            continue
        }
        let start = index
        while index < folded.count, isLetterByte(folded[index]) {
            index += 1
        }
        words.append(start ..< index)
    }
    return Name(
        text: text,
        table: table,
        folded: folded,
        mask: letterMask(folded),
        starts: wordStarts(folded),
        words: words,
    )
}

@inline(__always) func find(_ text: UnsafeBufferPointer<UInt8>, _ byte: UInt8, from: Int) -> Int? {
    guard from < text.count,
          let hit = memchr(text.baseAddress! + from, Int32(byte), text.count - from) else { return nil }
    return text.baseAddress!.distance(to: hit.assumingMemoryBound(to: UInt8.self))
}

/// The query's letters matched in order inside [start, end): 16 a letter, more at a word's start (twice
/// for the first letter) and in runs, less for each gap.
@inline(__always) func scoreWindow(
    _ query: UnsafeBufferPointer<UInt8>,
    _ text: UnsafeBufferPointer<UInt8>,
    _ start: Int,
    _ end: Int,
    _ starts: UInt64,
) -> Int {
    var score = 0, q = 0, run = 0, inGap = false
    var index = start
    while index < end {
        if q < query.count, text[index] == query[q] {
            let atStart = index < 64 && starts & (1 << UInt64(index)) != 0
            var bonus = atStart ? 8 : 0
            if run > 0 {
                bonus = max(bonus, 4)
            }
            score += 16 + (q == 0 ? bonus * 2 : bonus)
            run += 1
            q += 1
            inGap = false
        } else {
            score += inGap ? -1 : -3
            inGap = true
            run = 0
        }
        index += 1
    }
    return score
}

/// fzf's first algorithm: from each of the first 16 places the first letter appears, match forward, and
/// score both that window and the one tightened backward, keeping the best. Nil when the query's letters
/// aren't in the name in order.
func fuzzyScore(_ query: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>, starts: UInt64) -> Int? {
    guard !query.isEmpty, query.count <= text.count else { return nil }
    var best = Int.min
    var from = 0
    var anchors = 0
    while anchors < 16, let anchor = find(text, query[0], from: from) {
        var end = anchor + 1, q = 1
        while q < query.count, let next = find(text, query[q], from: end) {
            end = next + 1
            q += 1
        }
        guard q == query.count else { break }
        best = max(best, scoreWindow(query, text, anchor, end, starts))
        var start = end - 1, back = query.count - 1
        while true {
            if text[start] == query[back] {
                if back == 0 {
                    break
                }
                back -= 1
            }
            start -= 1
        }
        if start != anchor {
            best = max(best, scoreWindow(query, text, start, end, starts))
        }
        from = anchor + 1
        anchors += 1
    }
    return best == Int.min ? nil : best
}

/// Length of the longest common subsequence of the query (as `peq`, a bit per query position for each
/// byte) and `text`, bit-parallel (Hyyrö 2004): a few word operations a byte.
@inline(__always) func lcsLength(_ peq: UnsafePointer<UInt64>, _ m: Int, _ text: UnsafeBufferPointer<UInt8>) -> Int {
    var v = UInt64.max
    for byte in text {
        let u = v & peq[Int(byte)]
        v = (v &+ u) | (v &- u)
    }
    let full: UInt64 = m == 64 ? .max : (1 << UInt64(m)) &- 1
    return (~v & full).nonzeroBitCount
}

/// Restricted Damerau-Levenshtein distance of `query` and `word`, or nil past `limit`.
func typos(_ query: UnsafeBufferPointer<UInt8>, _ word: UnsafeBufferPointer<UInt8>, limit: Int) -> Int? {
    let m = query.count, n = word.count
    guard abs(m - n) <= limit, n > 0 else { return nil }
    return withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * (n + 1)) { rows in
        var before = rows.baseAddress!, previous = before + (n + 1), current = previous + (n + 1)
        for j in 0 ... n {
            previous[j] = j
        }
        for i in 1 ... m {
            current[0] = i
            var rowMin = i
            for j in 1 ... n {
                let cost = query[i - 1] == word[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, query[i - 1] == word[j - 2], query[i - 2] == word[j - 1] {
                    value = min(value, before[j - 2] + 1)
                }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > limit {
                return nil
            }
            (before, previous, current) = (previous, current, before)
        }
        return previous[n] <= limit ? previous[n] : nil
    }
}

struct Hit {
    let tier: Int
    let score: Int
    let name: Int
    let how: String
}

/// Tiers, best first: the name starts with the query, a word of it does, it holds it, it holds its
/// letters in order (by score, within half the best fuzzy score), or one of its words is the query with
/// typos (letters-only queries of four or more: one typo, two from eight letters), always after every
/// name holding the query as typed.
func search(_ typed: String, in names: [Name], limit: Int) -> [Hit] {
    let query = fold(typed)
    guard !query.isEmpty else { return [] }
    let queryMask = letterMask(query)
    let budget = query.count >= 8 ? 2 : 1
    let typoQuery = query.count >= 4 && query.count <= 64 && query.allSatisfy { (0x61 ... 0x7A).contains($0) }
    var peq = [UInt64](repeating: 0, count: 256)
    for (index, byte) in query.prefix(64).enumerated() {
        peq[Int(byte)] |= 1 << UInt64(index)
    }
    var hits: [Hit] = []
    query.withUnsafeBufferPointer { q in
        peq.withUnsafeBufferPointer { peq in
            for (number, name) in names.enumerated() {
                name.folded.withUnsafeBufferPointer { text in
                    if name.mask & queryMask == queryMask {
                        if q.count <= text.count, let hit = memmem(
                            text.baseAddress,
                            text.count,
                            q.baseAddress,
                            q.count,
                        ) {
                            let start = text.baseAddress!.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                            let atWord = start < 64 && name.starts & (1 << UInt64(start)) != 0
                            let tier = start == 0 ? 0 : atWord ? 1 : 2
                            hits.append(Hit(
                                tier: tier,
                                score: -text.count,
                                name: number,
                                how: ["starts", "word", "inside"][tier],
                            ))
                            return
                        }
                        if let score = fuzzyScore(q, text, starts: name.starts) {
                            hits.append(Hit(tier: 3, score: score, name: number, how: "fuzzy \(score)"))
                            return
                        }
                    }
                    guard typoQuery, (queryMask & ~name.mask).nonzeroBitCount <= budget,
                          lcsLength(peq.baseAddress!, q.count, text) >= q.count - budget else { return }
                    for word in name.words {
                        let letters = UnsafeBufferPointer(rebasing: text[word])
                        if let count = typos(q, letters, limit: budget), count > 0 {
                            hits.append(Hit(
                                tier: 4,
                                score: -count,
                                name: number,
                                how: count == 1 ? "1 typo" : "\(count) typos",
                            ))
                            return
                        }
                    }
                }
            }
        }
    }
    let bestFuzzy = hits.lazy.filter { $0.tier == 3 }.map(\.score).max() ?? 0
    hits.removeAll { $0.tier == 3 && $0.score * 2 < bestFuzzy }
    hits
        .sort { $0.tier != $1.tier ? $0.tier < $1.tier : $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name
        }
    return Array(hits.prefix(limit))
}

/// The library's small tables as a large library fills them: cameras, lenses, places, 3,000 keywords and
/// the 5,604 folders of the million-photo fixture.
func smallTables() -> [Name] {
    let cameras = [
        "X-T5",
        "X-T4",
        "X-H2S",
        "X100V",
        "ILCE-7M4",
        "ILCE-7RM5",
        "ILCE-6400",
        "DSC-RX100M7",
        "Canon EOS R5",
        "Canon EOS R6 Mark II",
        "Canon EOS 5D Mark IV",
        "Canon EOS 90D",
        "NIKON Z 8",
        "NIKON Z 6_2",
        "NIKON D850",
        "DC-GH6",
        "iPhone 15 Pro",
        "iPhone 13",
        "Pixel 8 Pro",
        "Galaxy S23 Ultra",
        "FC3582",
        "FUJIFILM GFX100S",
        "LEICA Q3",
        "OM-1",
        "Hasselblad X2D 100C",
    ]
    let lenses = [
        "FE 24-70mm F2.8 GM II",
        "FE 70-200mm F2.8 GM OSS II",
        "FE 35mm F1.4 GM",
        "FE 85mm F1.4 GM",
        "FE 16-35mm F2.8 GM",
        "RF24-70mm F2.8 L IS USM",
        "RF70-200mm F2.8 L IS USM",
        "RF50mm F1.2 L USM",
        "RF15-35mm F2.8 L IS USM",
        "NIKKOR Z 24-70mm f/2.8 S",
        "NIKKOR Z 70-200mm f/2.8 VR S",
        "NIKKOR Z 50mm f/1.8 S",
        "XF16-55mmF2.8 R LM WR",
        "XF56mmF1.2 R WR",
        "XF23mmF1.4 R LM WR",
        "XF100-400mmF4.5-5.6 R LM OIS WR",
        "M.Zuiko 12-40mm F2.8 PRO",
        "Sigma 35mm F1.4 DG DN Art",
        "Tamron 28-75mm F/2.8 Di III VXD G2",
        "Leica Summilux 28 f/1.7 ASPH.",
    ]
    let places = [
        "Lisbon",
        "Porto",
        "Tokyo",
        "Kyoto",
        "New York",
        "San Francisco",
        "London",
        "Paris",
        "Reykjavík",
        "Cape Town",
        "Sydney",
        "Buenos Aires",
        "Montréal",
        "Marrakesh",
        "Hanoi",
        "São Paulo",
        "Zürich",
        "Kraków",
        "Portugal",
        "Japan",
        "Iceland",
        "Morocco",
        "Vietnam",
        "Guimarães",
    ]
    let subjects = [
        "birds",
        "portrait",
        "landscape",
        "family",
        "architecture",
        "street",
        "food",
        "travel",
        "macro",
        "wildlife",
        "night",
        "sunset",
        "beach",
        "mountains",
        "city",
        "flowers",
        "dog",
        "snow",
        "autumn",
        "concert",
        "sports",
        "kids",
        "boats",
        "trains",
        "market",
        "forest",
        "river",
        "festival",
        "museum",
        "garden",
    ]
    var keywords = Set(subjects)
    var random = SplitMix(state: 99)
    let people = ["Ana", "João", "Maria", "Pedro", "Inês", "Tomás", "Beatriz", "Rui", "Sofia", "Miguel"]
    let families = [
        "Silva",
        "Costa",
        "Gomes",
        "Sousa",
        "Santos",
        "Ferreira",
        "Pereira",
        "Oliveira",
        "Rodrigues",
        "Martins",
    ]
    while keywords.count < 3000 {
        switch random.int(3) {
        case 0: keywords.insert("People/\(random.pick(people)) \(random.pick(families))")
        case 1:
            let spot = random.pick(["Old Town", "Harbour", "Station", "Park", "Bridge"])
            keywords.insert("Places/\(random.pick(places))/\(spot) \(random.int(900))")
        default:
            let view = random.pick(["close-up", "wide", "detail", "black and white"])
            keywords.insert("Subjects/\(random.pick(subjects))/\(view) \(random.int(900))")
        }
    }
    let folders = folderPaths(count: 5604, otherScripts: true, seed: 2026)
    var names = cameras.map { makeName($0, "camera") } + lenses.map { makeName($0, "lens") }
    names += places.map { makeName($0, "place") } + keywords.sorted().map { makeName($0, "keyword") }
    names += folders.map { makeName($0, "folder") }
    print("  \(names.count) names: \(cameras.count) cameras, \(lenses.count) lenses, \(places.count) places,")
    print("  \(keywords.count) keywords and \(folders.count) folders, searched on one thread")
    return names
}

func partThree() {
    print("\n== 3. Fuzzy matching and typos over the small tables (load average \(loadAverage())) ==")
    let names = smallTables()
    let demo = [
        "nz8",
        "z8",
        "r5",
        "xt5",
        "2470gm",
        "eosr6",
        "東京",
        "lisbom",
        "fujiflim",
        "wedidng",
        "landscpae",
        "portgual",
        "nikkon",
        "sao",
        "zurich",
    ]
    for query in demo {
        _ = search(query, in: names, limit: 3)
    }
    var samples: [Double] = []
    for _ in 0 ..< 5 {
        for query in demo {
            for typed in prefixes(query) {
                let start = nowNs()
                _ = search(typed, in: names, limit: 3)
                samples.append(Double(nowNs() - start) / 1e6)
            }
        }
    }
    print("  a keystroke, every table at once: " + summary(samples))
    for query in demo {
        let found = search(query, in: names, limit: 3).map { hit -> String in
            let name = names[hit.name]
            let shown = name
                .table == "folder" ? String(name.text.dropFirst("/Volumes/Photos/lib-1m.noindex/".count)) : name.text
            return "\(shown) (\(name.table), \(hit.how))"
        }
        print("  \"\(query)\": " + (found.isEmpty ? "nothing" : found.joined(separator: "; ")))
    }
}
