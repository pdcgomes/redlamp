// Measurements for docs/research/notes/LIB-cling.md. `TodayMatcher` has to stay what QueryText.contains
// and NameMatcher do in RedlampLibrary, or part 1 measures something else. Nothing here is Cling's code
// (GPL-3.0); the techniques are reimplemented from their descriptions.
import Darwin
import Foundation

// MARK: - Clock, memory, statistics

@inline(__always) func nowNs() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : -1
}

func megabytes(_ bytes: Int) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

func summary(_ samples: [Double], unit: String = "ms") -> String {
    let sorted = samples.sorted()
    func at(_ p: Double) -> Double {
        sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
    return String(
        format: "p50 %.3f %@, p95 %.3f %@, max %.3f %@ (%ld samples)",
        at(0.5),
        unit,
        at(0.95),
        unit,
        sorted.last ?? 0,
        unit,
        sorted.count,
    )
}

func loadAverage() -> String {
    var loads = [Double](repeating: 0, count: 3)
    getloadavg(&loads, 3)
    return String(format: "%.1f", loads[0])
}

struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[int(items.count)]
    }
}

// MARK: - 1. Text that isn't ASCII

func asciiLowercased(_ text: String) -> ContiguousArray<UInt8>? {
    var bytes = ContiguousArray<UInt8>()
    bytes.reserveCapacity(text.utf8.count)
    for byte in text.utf8 {
        guard byte < 0x80 else { return nil }
        bytes.append((0x41 ... 0x5A).contains(byte) ? byte | 0x20 : byte)
    }
    return bytes
}

func bytesContain(_ haystack: ContiguousArray<UInt8>, _ needle: ContiguousArray<UInt8>) -> Bool {
    guard !needle.isEmpty, needle.count <= haystack.count else { return false }
    return haystack.withUnsafeBytes { h in
        needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
    }
}

/// NameMatcher as on library/catalog: ASCII names lowercased once; anything else through Foundation.
struct TodayMatcher {
    let names: [String]
    let lowercased: [ContiguousArray<UInt8>?]

    init(_ names: [String]) {
        self.names = names
        lowercased = names.map(asciiLowercased)
    }

    func matches(_ part: String) -> [Bool] {
        let needle = asciiLowercased(part)
        return names.indices.map { index in
            if let needle, let name = lowercased[index] {
                return bytesContain(name, needle)
            }
            return names[index].range(of: part, options: .caseInsensitive) != nil
        }
    }
}

/// Every name folded once to bytes (case folded, then composed), the needle folded the same way, and
/// one memmem for any script; a hit followed by a mark that extends the character is skipped.
struct FoldedMatcher {
    let folded: [ContiguousArray<UInt8>]
    let options: String.CompareOptions

    init(_ names: [String], ignoringDiacritics: Bool) {
        options = ignoringDiacritics ? [.caseInsensitive, .diacriticInsensitive, .widthInsensitive] : [.caseInsensitive]
        let options = options
        folded = names.map { Self.fold($0, options) }
    }

    static func fold(_ text: String, _ options: String.CompareOptions) -> ContiguousArray<UInt8> {
        ContiguousArray(text.folding(options: options, locale: nil).precomposedStringWithCanonicalMapping.utf8)
    }

    func matches(_ part: String) -> [Bool] {
        let needle = Self.fold(part, options)
        return folded.map { containsWhole($0, needle) }
    }
}

func containsWhole(_ haystack: ContiguousArray<UInt8>, _ needle: ContiguousArray<UInt8>) -> Bool {
    guard !needle.isEmpty, needle.count <= haystack.count else { return false }
    return haystack.withUnsafeBufferPointer { h in
        needle.withUnsafeBufferPointer { n in
            var from = 0
            while from + n.count <= h.count {
                guard let hit = memmem(h.baseAddress! + from, h.count - from, n.baseAddress!, n.count) else {
                    return false
                }
                let offset = h.baseAddress!.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                let end = offset + n.count
                if end >= h.count || !extendsCharacter(h, at: end) {
                    return true
                }
                from = offset + 1
            }
            return false
        }
    }
}

/// Whether the scalar starting at `index` is a mark (or a joiner) that belongs to the character before it.
func extendsCharacter(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
    guard bytes[index] >= 0xCC else { return false } // nothing below U+0300 is a mark
    var iterator = UnsafeBufferPointer(rebasing: bytes[index...]).makeIterator()
    var decoder = UTF8()
    guard case let .scalarValue(scalar) = decoder.decode(&iterator) else { return false }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark: return true
    default: return scalar.value == 0x200D
    }
}

func folderPaths(count: Int, otherScripts: Bool, seed: UInt64) -> [String] {
    var random = SplitMix(state: seed)
    let events = [
        "Wedding",
        "Birthday",
        "Hike",
        "Beach Day",
        "Concert",
        "Graduation",
        "Road Trip",
        "Garden",
        "Zoo",
        "Christmas",
        "Museum Visit",
        "City Walk",
        "Football Match",
        "Family Dinner",
        "Snow Day",
        "Harbour Walk",
        "Picnic",
        "Airshow",
        "Market",
        "Camping",
    ]
    let elsewhere = [
        "São João",
        "Açores",
        "Festa do Avante",
        "Zürich",
        "Fête de la Musique",
        "Montréal",
        "Kraków",
        "Ελλάδα",
        "東京駅",
        "京都",
        "서울",
        "Straße",
        "İstanbul",
        "Réveillon",
        "Guimarães",
        "Ñuñoa",
        "ÉTÉ À NICE",
        "ＣＡＮＯＮ ＤＡＹ",
        "Malmö",
        "Coração",
    ]
    let clients = ["Acme Corp", "Northwind Traders", "Globex", "Initech", "Umbrella Studio", "Stark Atelier"]
    let jobs = ["Catalogue", "Product Launch", "Headshots", "Annual Report", "Lookbook", "Trade Show"]
    let root = "/Volumes/Photos/lib-1m.noindex/"
    return (0 ..< count).map { index in
        let year = 2000 + random.int(26)
        let day = String(format: "%04d-%02d-%02d", year, 1 + random.int(12), 1 + random.int(28))
        if index % 10 == 0 {
            return root + "Clients/\(random.pick(clients))/\(day) \(random.pick(jobs))"
        }
        var event = random.pick(events)
        if otherScripts, random.int(5) == 0 {
            event = random.pick(elsewhere)
            if random.int(2) == 0 {
                event = event.decomposedStringWithCanonicalMapping
            }
        }
        return root + "\(year)/\(day) \(event)"
    }
}

func prefixes(_ query: String) -> [String] {
    (1 ... query.count).map { String(query.prefix($0)) }
}

/// Results are counted into it so the optimiser keeps the work being timed.
nonisolated(unsafe) var matchesSeen = 0

func timeKeystrokes(_ queries: [String], rounds: Int, _ match: (String) -> [Bool]) -> [Double] {
    var samples: [Double] = []
    for _ in 0 ..< rounds {
        for query in queries {
            for typed in prefixes(query) {
                let start = nowNs()
                let found = match(typed)
                let elapsed = nowNs() - start
                matchesSeen += found.count(where: { $0 })
                samples.append(Double(elapsed) / 1e6)
            }
        }
    }
    return samples
}

func partOne() {
    print("== 1. Text that isn't ASCII, over 5,604 folder paths (load average \(loadAverage())) ==")
    let foreign = ["São João", "Zürich", "Fête", "東京駅", "Ελλάδα", "Kraków", "Straße", "İstanbul"]
    let ascii = ["wedding", "acme corp", "2019-03", "harbour walk"]
    for (label, otherScripts) in [
        ("the fixture's folders (all ASCII)", false),
        ("a fifth of the events in other scripts", true),
    ] {
        let names = folderPaths(count: 5604, otherScripts: otherScripts, seed: 2026)
        let foldStart = nowNs()
        let folded = FoldedMatcher(names, ignoringDiacritics: false)
        let foldMs = Double(nowNs() - foldStart) / 1e6
        let loose = FoldedMatcher(names, ignoringDiacritics: true)
        let today = TodayMatcher(names)
        print("-- \(label) --")
        print(String(format: "  folding 5,604 paths once: %.2f ms", foldMs))
        for (kind, queries) in [("queries that aren't ASCII", foreign), ("ASCII queries", ascii)] {
            _ = timeKeystrokes(queries, rounds: 1, today.matches)
            _ = timeKeystrokes(queries, rounds: 1, folded.matches)
            print("  \(kind), a keystroke:")
            print("    today (Foundation once either side isn't ASCII): " + summary(timeKeystrokes(
                queries,
                rounds: 5,
                today.matches,
            )))
            print("    folded bytes:                                    " + summary(timeKeystrokes(
                queries,
                rounds: 5,
                folded.matches,
            )))
        }
        var differ: [String: (today: Bool, folded: Bool)] = [:]
        var differences = 0, comparisons = 0, looser = 0
        for query in foreign + ascii + [
            "sao",
            "zurich",
            "fete",
            "strasse",
            "STRASSE",
            "istanbul",
            "ete a nice",
            "canon day",
            "ΕΛΛΆΔΑ",
            "東京",
        ] {
            for typed in prefixes(query) {
                let a = today.matches(typed), b = folded.matches(typed), c = loose.matches(typed)
                for index in names.indices {
                    comparisons += 1
                    if a[index] != b[index] {
                        differences += 1
                        let name = String(names[index].split(separator: " ", maxSplits: 1).last ?? "")
                        differ["\"\(typed)\" in \"\(name)\""] = (a[index], b[index])
                    }
                    if c[index], !a[index] {
                        looser += 1
                    }
                }
            }
        }
        print("  agreement with today: \(comparisons - differences) of \(comparisons) (query prefix, folder) pairs")
        for (pair, result) in differ.sorted(by: { $0.key < $1.key }).prefix(12) {
            print("    differs: \(pair): today \(result.today), folded \(result.folded)")
        }
        print("  ignoring accents and width too would add \(looser) matches over the same pairs")
    }
    let filter = "São Paulo".range(of: "sao", options: .caseInsensitive) != nil
    let completion = FoldedMatcher(["São Paulo"], ignoringDiacritics: true).matches("sao")[0]
    print("  \"sao\" finds \"São Paulo\": the filter's contains \(filter), completion's fold \(completion)")
}

// MARK: - 2. A mapped column store

struct Column {
    let name: String
    let stride: Int
}

let columns: [Column] = [
    ("ids", 8), ("folders", 4), ("captured", 8), ("cameras", 2), ("lenses", 2), ("packed", 2), ("iso", 2),
    ("aperture", 2), ("focal", 2), ("shutter", 4), ("kinds", 1), ("nameRanks", 4), ("editedAt", 4), ("sizes", 4),
    ("modifiedAt", 4), ("states", 1), ("creators", 2), ("copyrights", 2), ("customLabels", 1), ("places", 4),
    ("megapixels", 2), ("aspects", 2), ("rowOfID", 4), ("byCaptured", 4), ("byName", 4), ("byRating", 4),
    ("byEdited", 4),
].map { Column(name: $0.0, stride: $0.1) }

let page = 16384

func aligned(_ bytes: Int) -> Int {
    (bytes + page - 1) / page * page
}

func writeColumnFile(_ path: String, photos: Int) -> [(offset: Int, length: Int)] {
    var sections: [(Int, Int)] = []
    var offset = page
    for column in columns {
        sections.append((offset, column.stride * photos))
        offset += aligned(column.stride * photos)
    }
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    precondition(fd >= 0)
    ftruncate(fd, off_t(offset))
    var random = SplitMix(state: 7)
    for (index, column) in columns.enumerated() {
        let length = column.stride * photos
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        let words = buffer.bindMemory(to: UInt64.self, capacity: length / 8)
        for word in 0 ..< length / 8 {
            words[word] = random.next()
        }
        if column.name == "cameras" {
            let cameras = buffer.bindMemory(to: UInt16.self, capacity: photos)
            for row in 0 ..< photos {
                cameras[row] = UInt16(random.int(30))
            }
        }
        var written = 0
        while written < length {
            let n = pwrite(fd, buffer + written, length - written, off_t(sections[index].0 + written))
            precondition(n > 0)
            written += n
        }
        buffer.deallocate()
    }
    fsync(fd)
    close(fd)
    return sections
}

/// The filter pass a query like `rating>=3 camera:"X-T5"` makes: two columns, every row.
func columnPass(packed: UnsafePointer<UInt16>, cameras: UnsafePointer<UInt16>, photos: Int) -> Int {
    var found = 0
    for row in 0 ..< photos where packed[row] & 0x7 >= 3 && cameras[row] == 7 {
        found += 1
    }
    return found
}

func touchEveryPage(_ base: UnsafeRawPointer, _ length: Int) -> UInt64 {
    var sum: UInt64 = 0
    var at = 0
    while at < length {
        sum &+= UInt64(base.load(fromByteOffset: at, as: UInt8.self))
        at += 4096
    }
    return sum
}

func partTwo() {
    let photos = 1_000_000
    let path = NSTemporaryDirectory() + "cling-study-columns.bin"
    print(
        "\n== 2. A column store of \(columns.reduce(0) { $0 + $1.stride }) bytes a photo, \(photos) photos (load average \(loadAverage())) ==",
    )
    let sections = writeColumnFile(path, photos: photos)
    let size = sections.last!.offset + aligned(sections.last!.length)
    let packedIndex = columns.firstIndex { $0.name == "packed" }!
    let camerasIndex = columns.firstIndex { $0.name == "cameras" }!
    print("  file: \(megabytes(size)), each column on a 16 KB boundary; page cache warm (cold runs need `sudo purge`)")

    // Held in memory, as the column store's arrays are.
    do {
        let before = footprint()
        let start = nowNs()
        let fd = open(path, O_RDONLY)
        var arrays: [UnsafeMutableRawPointer] = []
        for section in sections {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: section.length, alignment: 16)
            var read = 0
            while read < section.length {
                let n = pread(fd, buffer + read, section.length - read, off_t(section.offset + read))
                precondition(n > 0)
                read += n
            }
            arrays.append(buffer)
        }
        close(fd)
        let loadMs = Double(nowNs() - start) / 1e6
        let loaded = footprint()
        var passes: [Double] = []
        var found = 0
        for _ in 0 ..< 20 {
            let passStart = nowNs()
            found = columnPass(
                packed: arrays[packedIndex].assumingMemoryBound(to: UInt16.self),
                cameras: arrays[camerasIndex].assumingMemoryBound(to: UInt16.self),
                photos: photos,
            )
            passes.append(Double(nowNs() - passStart) / 1e6)
        }
        print(String(
            format: "  in arrays: read in %.1f ms; the app's memory +%@; a two-column pass %@ (%ld found)",
            loadMs,
            megabytes(loaded - before),
            summary(passes),
            found,
        ))
        for buffer in arrays {
            buffer.deallocate()
        }
    }

    // Mapped from the file, copy-on-write, as Cling maps its index.
    do {
        let before = footprint()
        let start = nowNs()
        let fd = open(path, O_RDONLY)
        guard let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0), base != MAP_FAILED else {
            print("  mmap failed: \(errno)")
            return
        }
        close(fd)
        let mapUs = Double(nowNs() - start) / 1e3
        let mapped = footprint()
        let packed = (base + sections[packedIndex].offset).assumingMemoryBound(to: UInt16.self)
        let cameras = (base + sections[camerasIndex].offset).assumingMemoryBound(to: UInt16.self)
        var passes: [Double] = []
        var found = 0
        for _ in 0 ..< 20 {
            let passStart = nowNs()
            found = columnPass(packed: packed, cameras: cameras, photos: photos)
            passes.append(Double(nowNs() - passStart) / 1e6)
        }
        let afterPass = footprint()
        let scanStart = nowNs()
        let sum = touchEveryPage(UnsafeRawPointer(base), size)
        let scanMs = Double(nowNs() - scanStart) / 1e6
        let afterScan = footprint()
        var random = SplitMix(state: 11)
        for _ in 0 ..< 10000 {
            let row = random.int(photos)
            packed[row] = (packed[row] & ~0x7) | 5
        }
        let afterWrites = footprint()
        print(String(
            format: "  mapped: in %.0f µs; the app's memory +%@ mapped, +%@ after 20 passes (%@, %ld found)",
            mapUs,
            megabytes(mapped - before),
            megabytes(afterPass - before),
            summary(passes),
            found,
        ))
        print(String(
            format: "          every page of every column read in %.1f ms: the app's memory +%@ (sum %llu)",
            scanMs,
            megabytes(afterScan - before),
            sum,
        ))
        print(
            "          a rating on 10,000 photos spread across the library: +\(megabytes(afterWrites - afterScan)) copied",
        )
        munmap(base, size)
    }
    unlink(path)
}
