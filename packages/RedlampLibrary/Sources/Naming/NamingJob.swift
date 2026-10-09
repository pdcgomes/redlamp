import Foundation
import Synchronization

/// A photo a job names, and the folder it goes to.
public struct NamingPhoto: Sendable, Hashable {
    public var fields: NamingFields
    /// The folder's path; nil for the photo's own folder, as in a rename.
    public var destination: String?

    public init(_ fields: NamingFields, destination: String? = nil) {
        self.fields = fields
        self.destination = destination
    }
}

/// Names for a batch of photos (LIB-25), for the preview the file operations show (LIB-26), for
/// imports, exports and capture sessions. Made once for the photos, it names them again for each
/// template as it's typed.
///
/// - **Raw and JPEG pairs:** photos in one folder with the same name but their extension are one
///   photo: they share a new name, made from the raw's fields, and count once in sequences. They go
///   where the raw goes.
/// - **Sequences** number the photos in the order they're given, from `NamingOptions.sequenceStart`,
///   in the job, in each folder they go to, or among those with the raw's extension. Named counters
///   carry on from `NamingCounters`, and the batch returns them moved on.
/// - **Collisions:** no two photos get one name in a folder, and no photo gets the name of a file
///   already there (`existing`, by folder path), ignoring case and Unicode's forms as APFS does. A name
///   is taken by any file of that name with any extension, or by its sidecars, so a new name never
///   looks like another photo's raw or JPEG. A photo that keeps its name keeps it; the others get
///   theirs in the order they were taken, and those after the first are numbered from 2
///   (`Wedding-2`), again in capture order. The job's own photos leave their names free, with their
///   sidecars: the file operations order the renames.
public struct NamingJob: Sendable {
    public let photos: [NamingPhoto]

    /// Sidecars named after a photo, as `IMG_1234.CR3.redlamp`, or after its name without the
    /// extension, as `IMG_1234.xmp`: they move with it.
    public static let sidecarExtensions: Set<String> = ["redlamp", "xmp", "dop", "pp3", "on1"]

    /// The longest name a sidecar adds to its photo's: `.redlamp`.
    static let sidecarBytes = ".redlamp".utf8.count

    /// Jobs with this many photos (raw and JPEG pairs counted once) are named on every core.
    static let parallelGroups = 8192

    struct Prepared: Sendable {
        var base: String
        var ext: String
        var originalBase: String
        var number: String
        var group: Int32
    }

    struct Group: Sendable {
        var primary: Int32
        var source: Int32
        var destination: Int32
        /// The name without its extension, folded for comparing.
        var foldedBase: String
        /// The most an extension of its photos adds to a name: its dot and its bytes.
        var extensionBytes: Int
        var sequence: (job: Int, folder: Int, ext: Int)
    }

    struct CollisionKey: Hashable, Sendable {
        var folder: Int32
        var base: String
    }

    let prepared: [Prepared]
    let groups: [Group]
    /// Groups by the folder they go to, each folder's in the order they were taken: by capture time,
    /// then by name.
    let byFolder: [Int32]
    /// Each folder's groups in `byFolder`, for the folders photos go to.
    let folderSpans: [Range<Int>]
    /// Each folder's name and those above it, nearest first.
    let folderNames: [[String]]
    /// For each folder, the names files already in it take (folded), and one such file for each.
    let existing: [Int32: [String: String]]

    /// `existing` lists the files in the folders the photos go to, by folder path.
    public init(_ photos: [NamingPhoto], existing: [String: Set<String>] = [:]) {
        self.photos = photos
        let parallel = photos.count >= Self.parallelGroups
        let foldedBases = UnsafeMutableBufferPointer<String>.allocate(capacity: photos.count)
        var prepared = [Prepared](unsafeUninitializedCapacity: photos.count) {
            buffer, count in
            nonisolated(unsafe) let preparedOutput = buffer
            nonisolated(unsafe) let foldedOutput = foldedBases
            Self.forEachChunk(of: photos.count, parallel: parallel) { range in
                photos.withUnsafeBufferPointer { photos in
                    for index in range {
                        let fields = photos[index].fields
                        let (base, ext) = Self.split(fields.name)
                        let originalBase = fields.originalName.map { Self.split($0).base } ?? base
                        let digits = originalBase.utf8.reversed().prefix { $0 >= 0x30 && $0 <= 0x39 }.count
                        (preparedOutput.baseAddress! + index).initialize(to: Prepared(
                            base: base, ext: ext, originalBase: originalBase,
                            number: String(decoding: originalBase.utf8.suffix(digits), as: UTF8.self), group: 0,
                        ))
                        (foldedOutput.baseAddress! + index).initialize(to: Self.fold(base))
                    }
                }
            }
            count = photos.count
        }

        var folders: [String: Int32] = [:]
        var paths: [String] = []
        func folder(_ path: String) -> Int32 {
            if let id = folders[path] {
                return id
            }
            let id = Int32(paths.count)
            folders[path] = id
            paths.append(path)
            return id
        }
        var groups: [Group] = []
        var groupIDs: [CollisionKey: Int32] = [:]
        groupIDs.reserveCapacity(photos.count)
        var last: (path: String, id: Int32)?
        for (index, photo) in photos.enumerated() {
            let source: Int32
            if let last, last.path == photo.fields.folder {
                source = last.id
            } else {
                source = folder(photo.fields.folder)
                last = (photo.fields.folder, source)
            }
            let key = CollisionKey(folder: source, base: foldedBases[index])
            let ext = prepared[index].ext
            let extensionBytes = ext.isEmpty ? 0 : 1 + ext.utf8.count
            if let group = groupIDs[key] {
                prepared[index].group = group
                groups[Int(group)].extensionBytes = max(groups[Int(group)].extensionBytes, extensionBytes)
                if !Self.isRaw(prepared[Int(groups[Int(group)].primary)].ext), Self.isRaw(ext) {
                    groups[Int(group)].primary = Int32(index)
                }
            } else {
                let group = Int32(groups.count)
                prepared[index].group = group
                groupIDs[key] = group
                groups.append(Group(
                    primary: Int32(index), source: source,
                    destination: photo.destination.map(folder) ?? source, foldedBase: key.base,
                    extensionBytes: extensionBytes, sequence: (0, 0, 0),
                ))
            }
        }
        foldedBases.deinitialize()
        foldedBases.deallocate()

        var inFolder = [Int](repeating: 0, count: paths.count)
        var withExtension: [String: Int] = [:]
        for index in groups.indices {
            let destination = Int(groups[index].destination)
            let ext = Self.fold(prepared[Int(groups[index].primary)].ext)
            groups[index].sequence = (index, inFolder[destination], withExtension[ext, default: 0])
            inFolder[destination] += 1
            withExtension[ext, default: 0] += 1
        }

        var next = [Int](repeating: 0, count: inFolder.count)
        var spans: [Range<Int>] = []
        var start = 0
        for (id, count) in inFolder.enumerated() where count > 0 {
            next[id] = start
            spans.append(start ..< start + count)
            start += count
        }
        var byFolder = [Int32](repeating: 0, count: groups.count)
        for (index, group) in groups.enumerated() {
            byFolder[next[Int(group.destination)]] = Int32(index)
            next[Int(group.destination)] += 1
        }
        let times = groups.map { photos[Int($0.primary)].fields.captured.map(NamingMoment.microseconds) ?? .max }
        let finished = groups
        byFolder.withUnsafeMutableBufferPointer { order in
            nonisolated(unsafe) let order = order
            let sort = { @Sendable (span: Range<Int>) in
                times.withUnsafeBufferPointer { times in
                    finished.withUnsafeBufferPointer { groups in
                        var slice = UnsafeMutableBufferPointer(rebasing: order[span])
                        slice.sort { a, b in
                            if times[Int(a)] != times[Int(b)] {
                                return times[Int(a)] < times[Int(b)]
                            }
                            let (first, second) = (groups[Int(a)].foldedBase, groups[Int(b)].foldedBase)
                            return first != second ? first < second : a < b
                        }
                    }
                }
            }
            let folderSpans = spans
            if parallel, folderSpans.count > 1 {
                DispatchQueue.concurrentPerform(iterations: folderSpans.count) { sort(folderSpans[$0]) }
            } else {
                folderSpans.forEach(sort)
            }
        }

        let listings = existing.map { (folder: Int(folder($0.key)), names: $0.value) }
        let taken = Self.taken(
            listings, folders: paths.count, photos: photos, prepared: prepared, groups: groups, parallel: parallel,
        )

        self.prepared = prepared
        self.groups = groups
        self.byFolder = byFolder
        folderSpans = spans
        self.existing = taken
        folderNames = paths.map { path in
            path.split(separator: "/").reversed().map(String.init)
        }
    }

    /// For each folder of `listings` (of `folders` in all), the names its files take (folded) that no photo moving
    /// out of it frees, and one such file for each.
    private static func taken(
        _ listings: [(folder: Int, names: Set<String>)], folders: Int, photos: [NamingPhoto], prepared: [Prepared],
        groups finished: [Group], parallel: Bool,
    ) -> [Int32: [String: String]] {
        var fromFolder = [Int](repeating: 0, count: folders + 1)
        for photo in prepared {
            fromFolder[Int(finished[Int(photo.group)].source) + 1] += 1
        }
        for id in 0 ..< folders {
            fromFolder[id + 1] += fromFolder[id]
        }
        var placed = fromFolder
        var bySource = [Int32](repeating: 0, count: photos.count)
        for (index, photo) in prepared.enumerated() {
            let source = Int(finished[Int(photo.group)].source)
            bySource[placed[source]] = Int32(index)
            placed[source] += 1
        }
        let (named, sources, firsts) = (prepared, bySource, fromFolder)
        let found = [[String: String]](unsafeUninitializedCapacity: listings.count) { buffer, count in
            nonisolated(unsafe) let output = buffer
            let list = { @Sendable (number: Int) in
                let listing = listings[number]
                var names = Set<String>()
                var bases = Set<String>()
                photos.withUnsafeBufferPointer { photos in
                    named.withUnsafeBufferPointer { prepared in
                        finished.withUnsafeBufferPointer { groups in
                            for index in sources[firsts[listing.folder] ..< firsts[listing.folder + 1]] {
                                names.insert(Self.fold(photos[Int(index)].fields.name))
                                bases.insert(groups[Int(prepared[Int(index)].group)].foldedBase)
                            }
                        }
                    }
                }
                var taken: [String: String] = [:]
                for name in listing.names {
                    let folded = Self.fold(name)
                    guard !Self.moves(folded, names: names, bases: bases) else { continue }
                    let base = Self.photoBase(folded)
                    if taken[base].map({ name < $0 }) ?? true {
                        taken[base] = name
                    }
                }
                (output.baseAddress! + number).initialize(to: taken)
            }
            if parallel, listings.count > 1 {
                DispatchQueue.concurrentPerform(iterations: listings.count, execute: list)
            } else {
                (0 ..< listings.count).forEach(list)
            }
            count = listings.count
        }
        var taken: [Int32: [String: String]] = [:]
        for (listing, names) in zip(listings, found) {
            taken[Int32(listing.folder)] = names
        }
        return taken
    }
}

extension NamingJob {
    // MARK: - Naming

    /// Every photo's name from `template`, in the job's order, with collisions resolved.
    public func names(
        _ template: NamingTemplate, options: NamingOptions = NamingOptions(),
        context: NamingContext = NamingContext(), counters: NamingCounters = NamingCounters(),
    ) -> NamingBatch {
        let compile = { @Sendable in
            NamingProgram(template, options: options, context: context, counters: counters, total: groups.count)
        }
        let program = compile()
        let count = groups.count
        let parallel = count >= Self.parallelGroups
        let bases = UnsafeMutableBufferPointer<String>.allocate(capacity: count)
        bases.initialize(repeating: "")
        let folded = UnsafeMutableBufferPointer<String>.allocate(capacity: count)
        folded.initialize(repeating: "")
        let flags = UnsafeMutableBufferPointer<(NamingTokenSet, NamingAdjustments)>.allocate(capacity: count)
        flags.initialize(repeating: (NamingTokenSet(), []))
        let resolved = UnsafeMutableBufferPointer<(base: String, collision: NamingCollision)?>.allocate(capacity: count)
        resolved.initialize(repeating: nil)
        defer {
            for buffer in [bases, folded] {
                buffer.deinitialize()
                buffer.deallocate()
            }
            flags.deinitialize()
            flags.deallocate()
            resolved.deinitialize()
            resolved.deallocate()
        }

        nonisolated(unsafe) let baseOutput = bases
        nonisolated(unsafe) let foldedOutput = folded
        nonisolated(unsafe) let flagOutput = flags
        nonisolated(unsafe) let resolvedOutput = resolved
        Self.forEachChunk(of: count, parallel: parallel) { range in
            // Threads that share a program's arrays, or count references to the job's, wait on each
            // other's reference counts: each chunk compiles its own and reads the job's through pointers.
            let program = parallel ? compile() : program
            var values: [String] = []
            withPointers { photos, prepared, groups in
                for index in range {
                    let group = groups[index]
                    let primary = Int(group.primary)
                    let item = prepared[primary]
                    let subject = NamingProgram.Subject(
                        base: item.base, ext: item.ext, originalBase: item.originalBase, number: item.number,
                        folder: Int(group.source), sequence: group.sequence,
                    )
                    let budget = max(options.maximumBytes - Self.sidecarBytes - group.extensionBytes, 1)
                    let (base, empty, adjustments) = program.base(
                        for: photos[primary].fields, subject, folders: folderNames, maximumBytes: budget,
                        values: &values,
                    )
                    baseOutput[index] = base
                    foldedOutput[index] = Self.fold(base)
                    flagOutput[index] = (empty, adjustments)
                }
            }
        }

        let separator = program.safety.clean(options.collisionSeparator).0
        let spans = folderSpans
        if parallel, spans.count > 1 {
            DispatchQueue.concurrentPerform(iterations: spans.count) { number in
                resolve(
                    spans[number], bases: baseOutput, folded: foldedOutput, separator: separator,
                    maximumBytes: options.maximumBytes, into: resolvedOutput,
                )
            }
        } else {
            for span in spans {
                resolve(
                    span, bases: bases, folded: folded, separator: separator, maximumBytes: options.maximumBytes,
                    into: resolved,
                )
            }
        }

        let tokenCount = program.tokens.count
        let tallies = Mutex((empty: [Int](repeating: 0, count: tokenCount), collided: 0, unchanged: 0))
        let results = [NamingResult](unsafeUninitializedCapacity: photos.count) { buffer, initialized in
            nonisolated(unsafe) let output = buffer
            Self.forEachChunk(of: photos.count, parallel: parallel) { range in
                var empty = [Int](repeating: 0, count: tokenCount)
                var collided = 0
                var unchanged = 0
                withPointers { photos, prepared, groups in
                    for index in range {
                        let item = prepared[index]
                        let groupIndex = Int(item.group)
                        let group = groups[groupIndex]
                        let ext = switch options.extensionCase {
                        case .keep: item.ext
                        case .lowercase: item.ext.lowercased()
                        case .uppercase: item.ext.uppercased()
                        }
                        let collision = resolvedOutput[groupIndex]
                        let base = collision?.base ?? baseOutput[groupIndex]
                        let name = ext.isEmpty ? base : base + "." + ext
                        let isUnchanged = group.destination == group.source && name == photos[index].fields.name
                        let (emptyTokens, adjustments) = flagOutput[groupIndex]
                        for token in emptyTokens {
                            empty[token] += 1
                        }
                        collided += collision == nil ? 0 : 1
                        unchanged += isUnchanged ? 1 : 0
                        (output.baseAddress! + index).initialize(to: NamingResult(
                            name: name, extensionBytes: ext.isEmpty ? 0 : 1 + ext.utf8.count,
                            emptyTokens: emptyTokens, adjustments: adjustments, collision: collision?.collision,
                            isUnchanged: isUnchanged,
                        ))
                    }
                }
                tallies.withLock { tallies in
                    for token in 0 ..< tokenCount {
                        tallies.empty[token] += empty[token]
                    }
                    tallies.collided += collided
                    tallies.unchanged += unchanged
                }
            }
            initialized = photos.count
        }

        var moved = counters
        for (slot, name) in program.counterNames.enumerated() {
            moved[name] = program.counterStarts[slot] + groups.count
        }
        let (empty, collided, unchanged) = tallies.withLock { ($0.empty, $0.collided, $0.unchanged) }
        return NamingBatch(
            results: results, counters: moved, emptyCounts: empty, collisions: collided, unchanged: unchanged,
        )
    }

    private func withPointers<T>(
        _ body: (
            UnsafeBufferPointer<NamingPhoto>, UnsafeBufferPointer<Prepared>, UnsafeBufferPointer<Group>,
        ) throws -> T,
    ) rethrows -> T {
        try photos.withUnsafeBufferPointer { photos in
            try prepared.withUnsafeBufferPointer { prepared in
                try groups.withUnsafeBufferPointer { groups in try body(photos, prepared, groups) }
            }
        }
    }

    /// Runs `body` over `0 ..< count` in chunks on every core, or in one go.
    private static func forEachChunk(of count: Int, parallel: Bool, _ body: @Sendable (Range<Int>) -> Void) {
        let chunk = 2048
        let chunks = (count + chunk - 1) / chunk
        guard parallel, chunks > 1 else {
            body(0 ..< count)
            return
        }
        DispatchQueue.concurrentPerform(iterations: chunks) { number in
            body(number * chunk ..< min(count, (number + 1) * chunk))
        }
    }

    /// Gives the groups going to one folder (`span` of `byFolder`) their names: those keeping theirs
    /// first, then the others in the order they were taken; those whose name is taken get the next
    /// number free.
    private func resolve(
        _ span: Range<Int>, bases: UnsafeMutableBufferPointer<String>, folded: UnsafeMutableBufferPointer<String>,
        separator: String, maximumBytes: Int,
        into resolved: UnsafeMutableBufferPointer<(base: String, collision: NamingCollision)?>,
    ) {
        guard let first = span.first else { return }
        let taken = existing[groups[Int(byFolder[first])].destination] ?? [:]
        var holders: [String: Int32] = [:]
        holders.reserveCapacity(span.count)
        for position in span {
            let index = Int(byFolder[position])
            let group = groups[index]
            if group.destination == group.source, folded[index] == group.foldedBase {
                holders[folded[index]] = Int32(index)
            }
        }
        var waiting: [Int32] = []
        for position in span {
            let index = byFolder[position]
            let key = folded[Int(index)]
            if holders[key] == index {
                continue
            }
            if taken[key] == nil, holders[key] == nil {
                holders[key] = index
            } else {
                waiting.append(index)
            }
        }
        var next: [String: Int] = [:]
        for index in waiting {
            let group = groups[Int(index)]
            let key = folded[Int(index)]
            let holder: NamingCollision.Holder = taken[key].map { .file($0) }
                ?? .photo(Int(groups[Int(holders[key]!)].primary))
            let budget = max(maximumBytes - Self.sidecarBytes - group.extensionBytes, 1)
            var suffix = next[key] ?? 2
            while true {
                let number = separator + String(suffix)
                let base = NamingSafety.cut(bases[Int(index)], toBytes: max(budget - number.utf8.count, 0)) + number
                let candidate = Self.fold(base)
                if taken[candidate] == nil, holders[candidate] == nil {
                    holders[candidate] = index
                    resolved[Int(index)] = (base, NamingCollision(suffix: suffix, holder: holder))
                    next[key] = suffix + 1
                    break
                }
                suffix += 1
            }
        }
    }

    // MARK: - Names and files

    /// A name without its extension, and the extension without its dot; a name that starts with its
    /// only dot has no extension.
    static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")), dot != name.utf8.startIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// For comparing names as APFS and SMB shares do: composed and in small letters.
    static func fold(_ name: String) -> String {
        var capitals = false
        for byte in name.utf8 {
            if byte >= 0x80 {
                return name.precomposedStringWithCanonicalMapping.lowercased()
            }
            capitals = capitals || byte >= 0x41 && byte <= 0x5A
        }
        return capitals ? name.lowercased() : name
    }

    static func isRaw(_ ext: String) -> Bool {
        PhotoRecord.Kind(pathExtension: ext) == .raw
    }

    /// The name of the photo a folded file name belongs to, without its extension: `img_1` for
    /// `img_1.arw`, `img_1.arw.redlamp` and `img_1.xmp`.
    static func photoBase(_ folded: String) -> String {
        var name = folded
        let (rest, ext) = split(name)
        if sidecarExtensions.contains(ext), split(rest).ext != "" {
            name = rest
        }
        return split(name).base
    }

    /// Whether the file `folded` names is one of the job's photos in its folder (by their folded
    /// `names`) or a sidecar of one (named after one of their `names` or `bases`), which leave their
    /// names with them.
    static func moves(_ folded: String, names: Set<String>, bases: Set<String>) -> Bool {
        if names.contains(folded) {
            return true
        }
        let (rest, ext) = split(folded)
        return sidecarExtensions.contains(ext) && (names.contains(rest) || bases.contains(rest))
    }
}
