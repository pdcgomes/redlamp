import Foundation

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
        var members: Range<Int32>
        /// The most an extension adds to a name: its dot and its bytes.
        var extensionBytes: Int
        var sequence: (job: Int, folder: Int, ext: Int)
    }

    struct CollisionKey: Hashable, Sendable {
        var folder: Int32
        var base: String
    }

    let prepared: [Prepared]
    let groups: [Group]
    /// Photos by group, each group's together.
    let members: [Int32]
    /// Groups in the order they were taken: by capture time, then by name.
    let captureOrder: [Int32]
    /// Each folder's name and those above it, nearest first.
    let folderNames: [[String]]
    /// The names files already in the folders take, and one such file for each.
    let existing: [CollisionKey: String]

    /// `existing` lists the files in the folders the photos go to, by folder path.
    public init(_ photos: [NamingPhoto], existing: [String: Set<String>] = [:]) {
        self.photos = photos
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

        var prepared: [Prepared] = []
        prepared.reserveCapacity(photos.count)
        var groups: [Group] = []
        var groupIDs: [CollisionKey: Int32] = [:]
        var memberCounts: [Int32] = []
        for (index, photo) in photos.enumerated() {
            let (base, ext) = Self.split(photo.fields.name)
            let originalBase = photo.fields.originalName.map { Self.split($0).base } ?? base
            let source = folder(photo.fields.folder)
            let key = CollisionKey(folder: source, base: Self.fold(base))
            let group: Int32
            if let found = groupIDs[key] {
                group = found
                memberCounts[Int(group)] += 1
                if !Self.isRaw(prepared[Int(groups[Int(group)].primary)].ext), Self.isRaw(ext) {
                    groups[Int(group)].primary = Int32(index)
                }
            } else {
                group = Int32(groups.count)
                groupIDs[key] = group
                memberCounts.append(1)
                groups.append(Group(
                    primary: Int32(index), source: source,
                    destination: photo.destination.map(folder) ?? source, foldedBase: key.base, members: 0 ..< 0,
                    extensionBytes: 0, sequence: (0, 0, 0),
                ))
            }
            let digits = originalBase.utf8.reversed().prefix { $0 >= 0x30 && $0 <= 0x39 }.count
            prepared.append(Prepared(
                base: base, ext: ext, originalBase: originalBase,
                number: String(decoding: originalBase.utf8.suffix(digits), as: UTF8.self), group: group,
            ))
        }

        var starts: [Int32] = []
        starts.reserveCapacity(groups.count)
        var total: Int32 = 0
        for count in memberCounts {
            starts.append(total)
            total += count
        }
        var members = [Int32](repeating: 0, count: photos.count)
        var filled = starts
        for (index, photo) in prepared.enumerated() {
            members[Int(filled[Int(photo.group)])] = Int32(index)
            filled[Int(photo.group)] += 1
        }

        var inFolder: [Int32: Int] = [:]
        var withExtension: [String: Int] = [:]
        for index in groups.indices {
            var group = groups[index]
            group.members = starts[index] ..< starts[index] + memberCounts[index]
            for member in members[Int(group.members.lowerBound) ..< Int(group.members.upperBound)] {
                let ext = prepared[Int(member)].ext
                group.extensionBytes = max(group.extensionBytes, ext.isEmpty ? 0 : 1 + ext.utf8.count)
            }
            let ext = Self.fold(prepared[Int(group.primary)].ext)
            group.sequence = (index, inFolder[group.destination, default: 0], withExtension[ext, default: 0])
            inFolder[group.destination, default: 0] += 1
            withExtension[ext, default: 0] += 1
            groups[index] = group
        }

        let times = groups.map { group in
            photos[Int(group.primary)].fields.captured.map(NamingMoment.microseconds) ?? .max
        }
        captureOrder = groups.indices.sorted { a, b in
            if times[a] != times[b] {
                return times[a] < times[b]
            }
            if groups[a].foldedBase != groups[b].foldedBase {
                return groups[a].foldedBase < groups[b].foldedBase
            }
            return a < b
        }.map(Int32.init)

        var taken: [CollisionKey: String] = [:]
        for (path, names) in existing {
            let id = folder(path)
            for name in names {
                let folded = Self.fold(name)
                guard !Self.moves(folded, in: id, groups: groupIDs, prepared: prepared, members: members, of: groups)
                else { continue }
                let key = CollisionKey(folder: id, base: Self.photoBase(folded))
                if taken[key] == nil || name < taken[key]! {
                    taken[key] = name
                }
            }
        }

        self.prepared = prepared
        self.groups = groups
        self.members = members
        self.existing = taken
        folderNames = paths.map { path in
            path.split(separator: "/").reversed().map(String.init)
        }
    }

    // MARK: - Naming

    /// Every photo's name from `template`, in the job's order, with collisions resolved.
    public func names(
        _ template: NamingTemplate, options: NamingOptions = NamingOptions(),
        context: NamingContext = NamingContext(), counters: NamingCounters = NamingCounters(),
    ) -> NamingBatch {
        let program = NamingProgram(
            template,
            options: options,
            context: context,
            counters: counters,
            total: groups.count,
        )
        let count = groups.count
        let bases = UnsafeMutableBufferPointer<String>.allocate(capacity: count)
        bases.initialize(repeating: "")
        let folded = UnsafeMutableBufferPointer<String>.allocate(capacity: count)
        folded.initialize(repeating: "")
        let flags = UnsafeMutableBufferPointer<(NamingTokenSet, NamingAdjustments)>.allocate(capacity: count)
        flags.initialize(repeating: (NamingTokenSet(), []))
        defer {
            for buffer in [bases, folded] {
                buffer.deinitialize()
                buffer.deallocate()
            }
            flags.deinitialize()
            flags.deallocate()
        }

        nonisolated(unsafe) let baseOutput = bases
        nonisolated(unsafe) let foldedOutput = folded
        nonisolated(unsafe) let flagOutput = flags
        let chunk = 2048
        let chunks = (count + chunk - 1) / chunk
        let evaluate: @Sendable (Range<Int>) -> Void = { range in
            var values: [String] = []
            for index in range {
                let group = groups[index]
                let budget = max(options.maximumBytes - Self.sidecarBytes - group.extensionBytes, 1)
                let (base, empty, adjustments) = program.base(
                    for: subject(group), maximumBytes: budget, values: &values,
                )
                baseOutput[index] = base
                foldedOutput[index] = Self.fold(base)
                flagOutput[index] = (empty, adjustments)
            }
        }
        if chunks > 1, count >= 4 * chunk {
            DispatchQueue.concurrentPerform(iterations: chunks) { number in
                evaluate(number * chunk ..< min(count, (number + 1) * chunk))
            }
        } else {
            evaluate(0 ..< count)
        }

        let collisions = resolve(bases: bases, folded: folded, options: options, safety: program.safety)

        var results: [NamingResult] = []
        results.reserveCapacity(photos.count)
        var emptyCounts = [Int](repeating: 0, count: program.tokens.count)
        var collided = 0
        var unchanged = 0
        for (index, photo) in photos.enumerated() {
            let item = prepared[index]
            let group = groups[Int(item.group)]
            let ext = switch options.extensionCase {
            case .keep: item.ext
            case .lowercase: item.ext.lowercased()
            case .uppercase: item.ext.uppercased()
            }
            let base = collisions[Int(item.group)]?.base ?? bases[Int(item.group)]
            let name = ext.isEmpty ? base : base + "." + ext
            let isUnchanged = group.destination == group.source && name == photo.fields.name
            let (empty, adjustments) = flags[Int(item.group)]
            for token in empty {
                emptyCounts[token] += 1
            }
            if collisions[Int(item.group)] != nil {
                collided += 1
            }
            if isUnchanged {
                unchanged += 1
            }
            results.append(NamingResult(
                name: name, extensionBytes: ext.isEmpty ? 0 : 1 + ext.utf8.count, emptyTokens: empty,
                adjustments: adjustments, collision: collisions[Int(item.group)]?.collision, isUnchanged: isUnchanged,
            ))
        }

        var moved = counters
        for (slot, name) in program.counterNames.enumerated() {
            moved[name] = program.counterStarts[slot] + groups.count
        }
        return NamingBatch(
            results: results, counters: moved, emptyCounts: emptyCounts, collisions: collided, unchanged: unchanged,
        )
    }

    private func subject(_ group: Group) -> NamingProgram.Subject {
        let primary = Int(group.primary)
        let item = prepared[primary]
        return NamingProgram.Subject(
            fields: photos[primary].fields, base: item.base, ext: item.ext, originalBase: item.originalBase,
            number: item.number, folders: folderNames[Int(group.source)][...], sequence: group.sequence,
        )
    }

    /// The groups whose name was taken, with the numbered name each gets and who has the name.
    private func resolve(
        bases: UnsafeMutableBufferPointer<String>, folded: UnsafeMutableBufferPointer<String>,
        options: NamingOptions, safety: NamingSafety,
    ) -> [(base: String, collision: NamingCollision)?] {
        var resolved = [(base: String, collision: NamingCollision)?](repeating: nil, count: groups.count)
        var holders: [CollisionKey: Int32] = [:]
        holders.reserveCapacity(groups.count)
        for (index, group) in groups.enumerated()
            where group.destination == group.source && folded[index] == group.foldedBase {
            holders[CollisionKey(folder: group.destination, base: folded[index])] = Int32(index)
        }
        var waiting: [Int32] = []
        for index in captureOrder {
            let group = groups[Int(index)]
            let key = CollisionKey(folder: group.destination, base: folded[Int(index)])
            if holders[key] == index {
                continue
            }
            if existing[key] == nil, holders[key] == nil {
                holders[key] = index
            } else {
                waiting.append(index)
            }
        }
        guard !waiting.isEmpty else { return resolved }

        let separator = safety.clean(options.collisionSeparator).0
        var next: [CollisionKey: Int] = [:]
        for index in waiting {
            let group = groups[Int(index)]
            let key = CollisionKey(folder: group.destination, base: folded[Int(index)])
            let holder: NamingCollision.Holder = existing[key].map { .file($0) }
                ?? .photo(Int(groups[Int(holders[key]!)].primary))
            let budget = max(options.maximumBytes - Self.sidecarBytes - group.extensionBytes, 1)
            var suffix = next[key] ?? 2
            while true {
                let number = separator + String(suffix)
                let base = NamingSafety.cut(bases[Int(index)], toBytes: max(budget - number.utf8.count, 0)) + number
                let candidate = CollisionKey(folder: group.destination, base: Self.fold(base))
                if existing[candidate] == nil, holders[candidate] == nil {
                    holders[candidate] = index
                    resolved[Int(index)] = (base, NamingCollision(suffix: suffix, holder: holder))
                    next[key] = suffix + 1
                    break
                }
                suffix += 1
            }
        }
        return resolved
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
        name.utf8.contains(where: { $0 >= 0x80 }) ? name.precomposedStringWithCanonicalMapping.lowercased()
            : name.lowercased()
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

    /// Whether the file `folded` names in folder `folder` is one of the job's photos or one of their
    /// sidecars, which leave their names with them.
    private static func moves(
        _ folded: String, in folder: Int32, groups: [CollisionKey: Int32], prepared: [Prepared], members: [Int32],
        of all: [Group],
    ) -> Bool {
        func holds(_ base: String, _ ext: String?) -> Bool {
            guard let group = groups[CollisionKey(folder: folder, base: base)] else { return false }
            guard let ext else { return true }
            let range = all[Int(group)].members
            return members[Int(range.lowerBound) ..< Int(range.upperBound)]
                .contains { fold(prepared[Int($0)].ext) == ext }
        }
        let (rest, ext) = split(folded)
        if sidecarExtensions.contains(ext) {
            let (photoBase, photoExt) = split(rest)
            return photoExt.isEmpty ? holds(rest, nil) : holds(photoBase, photoExt) || holds(rest, nil)
        }
        return holds(rest, ext)
    }
}
