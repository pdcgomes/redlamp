import Foundation
import RedlampDocument

/// Finds a library's stacks from its index alone (LIB-28), never reading a photo's file: from the
/// column store's capture columns and each photo's name, a folder at a time on every core.
///
/// - **Pairs:** raw, JPEG and HEIC photos in one folder whose names differ only in their extension,
///   compared as APFS compares names, as naming pairs them (`NamingJob`). The raw is on top, then
///   the JPEG, then the HEIC.
/// - **Bursts:** a camera's frames in one folder with one exposure length, each starting at most
///   `burstGap` after the one before ended: its capture time plus its exposure length, so long
///   exposures shot back to back stay together where the gap between capture times would part
///   them. The index knows a camera's model but not its body, so a folder (one card's photos)
///   keeps two bodies of one model, or a second card's copies, from mixing. The first frame is on
///   top unless the user chose another.
/// - **Focus suggestions:** `StackDetector.runs`' rules over each folder's frames in name order,
///   from the settings the column store keeps (f-numbers to a hundredth, focal lengths to a tenth
///   of a millimetre, exposure lengths to the microsecond, times to the millisecond). A raw and its
///   JPEG are one frame, so a pair doesn't halve the step the rules expect. The app confirms them
///   from their thumbnails, leaving out runs a stack document covers, as it does today.
/// - **Manual stacks** and photos taken out of stacks come from `StackChoices`; a frame in one is
///   in no burst.
///
/// A raw and its JPEG are one frame in bursts, suggestions and manual stacks, by the raw.
public enum StackFinder {
    /// The most a burst's frames are apart, in seconds, from the end of one exposure to the start of
    /// the next. Continuous drive shoots a frame a second at its slowest, so its frames stay one
    /// burst, while shots taken one at a time are usually further apart.
    public static let burstGap: Double = 1

    /// The stacks among `store`'s photos, `names` holding their names and `choices` what the user
    /// decided. Runs on every core; call it off the main thread.
    public static func find(
        in store: ColumnStore, names: StackNames, choices: StackChoices = StackChoices(),
    ) -> Stacks {
        let photos = Int(store.ids.max() ?? 0) + 1
        let flags = Self.flags(choices, photos: photos)
        let (rows, spans) = byFolder(store)
        let chunks = Self.chunks(spans, photos: 4096)
        let results = UnsafeMutableBufferPointer<Found>.allocate(capacity: chunks.count)
        results.initialize(repeating: Found())
        defer {
            results.deinitialize()
            results.deallocate()
        }
        Columns.reading(store, names: names, flags: flags) { columns in
            nonisolated(unsafe) let columns = columns
            nonisolated(unsafe) let output = results
            DispatchQueue.concurrentPerform(iterations: chunks.count) { chunk in
                var pass = FolderPass(columns: columns)
                rows.withUnsafeBufferPointer { rows in
                    for span in spans[chunks[chunk]] {
                        pass.find(UnsafeBufferPointer(rebasing: rows[span]))
                    }
                }
                output[chunk] = pass.found
            }
        }

        var found = Found()
        for result in results {
            found.pairs.append(result.pairs)
            found.bursts.append(result.bursts)
            found.focus.append(result.focus)
        }
        let (manual, ids) = manualStacks(choices, pairs: found.pairs, store: store)
        var all = found.pairs
        all.append(found.bursts)
        all.append(manual)
        all.append(found.focus)
        var kinds = ContiguousArray<Stack.Kind>()
        kinds.reserveCapacity(all.count)
        kinds.append(contentsOf: repeatElement(.pair, count: found.pairs.count))
        kinds.append(contentsOf: repeatElement(.burst, count: found.bursts.count))
        kinds.append(contentsOf: repeatElement(.manual, count: manual.count))
        kinds.append(contentsOf: repeatElement(.focus, count: found.focus.count))
        let first = found.pairs.count + found.bursts.count
        var stackIDs: [Int32: UUID] = [:]
        for (offset, id) in ids.enumerated() {
            stackIDs[Int32(first + offset)] = id
        }
        return Stacks(
            members: all.members, starts: all.starts, kinds: kinds, ids: stackIDs, pairs: found.pairs.count,
            groups: found.bursts.count + manual.count, photos: photos,
        )
    }

    // MARK: - Choices

    static let hasChoice: UInt8 = 1 << 0
    static let hasID: UInt8 = 1 << 1
    static let isTop: UInt8 = 1 << 2

    /// Each photo's choice by ID, as bits: one, with an ID, on top.
    private static func flags(_ choices: StackChoices, photos: Int) -> ContiguousArray<UInt8> {
        var flags = ContiguousArray<UInt8>(repeating: 0, count: choices.isEmpty ? 0 : photos)
        for (photo, choice) in choices.choices where photo >= 0 && photo < photos {
            flags[Int(photo)] = hasChoice | (choice.id == nil ? 0 : hasID) | (choice.top ? isTop : 0)
        }
        return flags
    }

    /// The manual stacks `choices` make of `store`'s photos, each with two frames or more, and their
    /// IDs: the frame chosen for the top first, else the earliest, then the others by capture time.
    private static func manualStacks(_ choices: StackChoices, pairs: Table, store: ColumnStore) -> (Table, [UUID]) {
        guard !choices.isEmpty else { return (Table(), []) }
        var pairOf: [Int64: Int] = [:]
        for pair in 0 ..< pairs.count {
            for photo in pairs.members[pairs.range(of: pair)] where choices[photo] != nil {
                pairOf[photo] = pair
            }
        }
        var frames: [UUID: [(top: Int64, shown: Bool)]] = [:]
        for (photo, choice) in choices.choices.sorted(by: { $0.key < $1.key }) {
            guard let id = choice.id, store.contains(photo) else { continue }
            let frame = pairOf[photo].map { Array(pairs.members[pairs.range(of: $0)]) } ?? [photo]
            guard let decision = frame.lazy.compactMap({ choices[$0] }).first, decision.id == id,
                  frames[id]?.contains(where: { $0.top == frame[0] }) != true
            else { continue }
            frames[id, default: []].append((frame[0], decision.top))
        }
        func captured(_ photo: Int64) -> Int64 {
            store.row(of: photo).map { store.captured[$0] } ?? .min
        }
        var stacks: [(id: UUID, photos: [Int64])] = []
        for (id, members) in frames where members.count > 1 {
            var ordered = members.sorted { (captured($0.top), $0.top) < (captured($1.top), $1.top) }
            if let shown = ordered.firstIndex(where: \.shown) {
                ordered.insert(ordered.remove(at: shown), at: 0)
            }
            stacks.append((id, ordered.map(\.top)))
        }
        stacks.sort { $0.photos[0] < $1.photos[0] }
        var table = Table()
        for stack in stacks {
            table.append(stack.photos)
        }
        return (table, stacks.map(\.id))
    }

    // MARK: - Folders

    /// The store's photos by folder: their rows, and each folder's span of them, in folder order.
    private static func byFolder(_ store: ColumnStore) -> (rows: ContiguousArray<Int32>, spans: [Range<Int>]) {
        let folders = store.folders
        var largest: Int32 = 0
        store.live.forEach { row in
            largest = max(largest, folders[row])
            return true
        }
        var counts = ContiguousArray<Int32>(repeating: 0, count: Int(largest) + 2)
        store.live.forEach { row in
            counts[Int(max(folders[row], 0)) + 1] += 1
            return true
        }
        var spans: [Range<Int>] = []
        var start = 0
        for folder in 1 ..< counts.count {
            let count = Int(counts[folder])
            counts[folder] = Int32(start)
            if count > 0 {
                spans.append(start ..< start + count)
            }
            start += count
        }
        var rows = ContiguousArray<Int32>(repeating: 0, count: start)
        store.live.forEach { row in
            let folder = Int(max(folders[row], 0)) + 1
            rows[Int(counts[folder])] = Int32(row)
            counts[folder] += 1
            return true
        }
        return (rows, spans)
    }

    /// Runs of `spans` holding at least `photos` photos each, or one folder.
    private static func chunks(_ spans: [Range<Int>], photos: Int) -> [Range<Int>] {
        var chunks: [Range<Int>] = []
        var start = 0
        var count = 0
        for (index, span) in spans.enumerated() {
            count += span.count
            if count >= photos {
                chunks.append(start ..< index + 1)
                start = index + 1
                count = 0
            }
        }
        if start < spans.count {
            chunks.append(start ..< spans.count)
        }
        return chunks
    }
}

extension StackFinder {
    /// Stacks' photos one after another, as `Stacks` keeps them.
    struct Table: Sendable {
        var members = ContiguousArray<Int64>()
        var starts: ContiguousArray<Int32> = [0]

        var count: Int {
            starts.count - 1
        }

        func range(of stack: Int) -> Range<Int> {
            Int(starts[stack]) ..< Int(starts[stack + 1])
        }

        mutating func append(_ photos: some Sequence<Int64>) {
            members.append(contentsOf: photos)
            end()
        }

        /// Adds a photo to the stack being made, which `end` finishes.
        mutating func add(_ photo: Int64) {
            members.append(photo)
        }

        mutating func end() {
            starts.append(Int32(members.count))
        }

        mutating func append(_ table: Table) {
            let offset = Int32(members.count)
            members.append(contentsOf: table.members)
            starts.append(contentsOf: table.starts.dropFirst().lazy.map { $0 + offset })
        }
    }

    /// What a run of folders holds.
    struct Found: Sendable {
        var pairs = Table()
        var bursts = Table()
        var focus = Table()
    }

    /// The column store's columns finding reads by row, the names by ID and the choices' bits, through
    /// pointers: threads reading one array's elements through the array count references to it, and
    /// wait on each other.
    struct Columns {
        let ids: UnsafeBufferPointer<Int64>
        let captured: UnsafeBufferPointer<Int64>
        let cameras: UnsafeBufferPointer<UInt16>
        let lenses: UnsafeBufferPointer<UInt16>
        let iso: UnsafeBufferPointer<UInt16>
        let aperture: UnsafeBufferPointer<UInt16>
        let focal: UnsafeBufferPointer<UInt16>
        let shutter: UnsafeBufferPointer<UInt32>
        let kinds: UnsafeBufferPointer<UInt8>
        let nameRanks: UnsafeBufferPointer<Int32>
        let names: UnsafeBufferPointer<String>
        let flags: UnsafeBufferPointer<UInt8>

        /// Runs `body` with `store`'s columns, `names` and `flags`.
        static func reading<T>(
            _ store: ColumnStore, names: StackNames, flags: ContiguousArray<UInt8>, _ body: (Columns) -> T,
        ) -> T {
            store.ids.withUnsafeBufferPointer { ids in
                store.captured.withUnsafeBufferPointer { captured in
                    store.cameras.withUnsafeBufferPointer { cameras in
                        store.lenses.withUnsafeBufferPointer { lenses in
                            store.iso.withUnsafeBufferPointer { iso in
                                store.aperture.withUnsafeBufferPointer { aperture in
                                    store.focal.withUnsafeBufferPointer { focal in
                                        store.shutter.withUnsafeBufferPointer { shutter in
                                            store.kinds.withUnsafeBufferPointer { kinds in
                                                store.nameRanks.withUnsafeBufferPointer { nameRanks in
                                                    names.withUnsafeBufferPointer { names in
                                                        flags.withUnsafeBufferPointer { flags in
                                                            body(Columns(
                                                                ids: ids, captured: captured, cameras: cameras,
                                                                lenses: lenses, iso: iso, aperture: aperture,
                                                                focal: focal, shutter: shutter, kinds: kinds,
                                                                nameRanks: nameRanks, names: names, flags: flags,
                                                            ))
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        func name(ofRow row: Int) -> String {
            let id = Int(ids[row])
            return id < names.count ? names[id] : ""
        }

        /// The choice of the photo in `row`, as `StackFinder.flags` keeps them.
        func flag(ofRow row: Int) -> UInt8 {
            let id = Int(ids[row])
            return id < flags.count ? flags[id] : 0
        }

        /// Shot with the settings `StackDetector.Capture.sameSettings` compares.
        func sameSettings(_ lhs: Int, _ rhs: Int) -> Bool {
            cameras[lhs] == cameras[rhs] && lenses[lhs] == lenses[rhs] && focal[lhs] == focal[rhs]
                && aperture[lhs] == aperture[rhs] && iso[lhs] == iso[rhs] && shutter[lhs] == shutter[rhs]
        }
    }

    /// Finds one folder's stacks at a time, keeping its buffers from one folder to the next.
    struct FolderPass {
        let columns: Columns
        var found = Found()

        /// For each of the folder's photos: the next with its name, -1 for none.
        private var links: [Int32] = []
        /// For each photo: the first with its name, -1 for a photo that can't be in a pair.
        private var heads: [Int32] = []
        private var bases: [String: Int32] = [:]
        private var members: [Int32] = []
        /// The folder's frames, by their top photo, and each one's choice.
        private var frames: [Int32] = []
        private var frameFlags: [UInt8] = []
        private var order: [Int32] = []
        private var run: [Int32] = []
        /// The run's gaps, in milliseconds, ascending.
        private var gaps: [Int64] = []

        init(columns: Columns) {
            self.columns = columns
        }

        /// Finds the stacks among `rows`, one folder's.
        mutating func find(_ rows: UnsafeBufferPointer<Int32>) {
            pairs(rows)
            bursts(rows)
            focus(rows)
        }

        // MARK: Pairs

        /// Raw, JPEG and HEIC photos whose names differ only in their extension, as pairs, and the
        /// folder's frames: each pair's first photo, and every photo in none.
        private mutating func pairs(_ rows: UnsafeBufferPointer<Int32>) {
            let count = rows.count
            links.removeAll(keepingCapacity: true)
            links.append(contentsOf: repeatElement(-1, count: count))
            heads.removeAll(keepingCapacity: true)
            heads.append(contentsOf: repeatElement(-1, count: count))
            bases.removeAll(keepingCapacity: true)
            for (place, row) in rows.enumerated() {
                let kind = columns.kinds[Int(row)]
                guard kind >= 1, kind <= 3 else { continue }
                let (base, ext) = NamingJob.split(columns.name(ofRow: Int(row)))
                guard !ext.isEmpty else { continue }
                let key = NamingJob.fold(base)
                if let first = bases[key] {
                    heads[place] = first
                    links[place] = links[Int(first)]
                    links[Int(first)] = Int32(place)
                } else {
                    bases[key] = Int32(place)
                    heads[place] = Int32(place)
                }
            }
            frames.removeAll(keepingCapacity: true)
            frameFlags.removeAll(keepingCapacity: true)
            for place in 0 ..< count {
                let head = heads[place]
                guard head == Int32(place), links[place] >= 0 else {
                    if head < 0 || head == Int32(place) {
                        frames.append(Int32(place))
                        frameFlags.append(columns.flag(ofRow: Int(rows[place])))
                    }
                    continue
                }
                members.removeAll(keepingCapacity: true)
                var next = Int32(place)
                while next >= 0 {
                    members.append(next)
                    next = links[Int(next)]
                }
                let columns = columns
                members.sort { lhs, rhs in
                    let (left, right) = (Int(rows[Int(lhs)]), Int(rows[Int(rhs)]))
                    return (columns.kinds[left], columns.nameRanks[left]) < (
                        columns.kinds[right],
                        columns.nameRanks[right],
                    )
                }
                var choice: UInt8 = 0
                for member in members {
                    let row = Int(rows[Int(member)])
                    found.pairs.add(columns.ids[row])
                    choice = choice == 0 ? columns.flag(ofRow: row) : choice
                }
                found.pairs.end()
                frames.append(members[0])
                frameFlags.append(choice)
            }
        }

        // MARK: Bursts

        /// A camera's frames with one exposure length, each starting at most `burstGap` after the
        /// one before ended; frames in manual stacks are left out.
        private mutating func bursts(_ rows: UnsafeBufferPointer<Int32>) {
            order.removeAll(keepingCapacity: true)
            for (frame, place) in frames.enumerated() {
                let row = Int(rows[Int(place)])
                if columns.cameras[row] != 0, columns.captured[row] != .min,
                   frameFlags[frame] & StackFinder.hasID == 0 {
                    order.append(Int32(frame))
                }
            }
            guard order.count > 1 else { return }
            let columns = columns
            let frames = frames
            func row(_ frame: Int32) -> Int {
                Int(rows[Int(frames[Int(frame)])])
            }
            order.sort { lhs, rhs in
                let (left, right) = (row(lhs), row(rhs))
                return (columns.cameras[left], columns.captured[left], columns.nameRanks[left])
                    < (columns.cameras[right], columns.captured[right], columns.nameRanks[right])
            }
            let gap = Int64(StackFinder.burstGap * 1_000_000)
            func follows(_ earlier: Int, _ later: Int) -> Bool {
                guard columns.cameras[earlier] == columns.cameras[later],
                      columns.shutter[earlier] == columns.shutter[later]
                else { return false }
                let (apart, overflow) = columns.captured[later].subtractingReportingOverflow(columns.captured[earlier])
                return !overflow && apart <= (gap + Int64(columns.shutter[earlier])) / 1000
            }
            var start = 0
            for index in 1 ... order.count {
                guard index == order.count || !follows(row(order[index - 1]), row(order[index])) else { continue }
                if index - start > 1 {
                    let burst = order[start ..< index]
                    let top = burst.first { frameFlags[Int($0)] & StackFinder.isTop != 0 } ?? burst[start]
                    found.bursts.add(columns.ids[row(top)])
                    for frame in burst where frame != top {
                        found.bursts.add(columns.ids[row(frame)])
                    }
                    found.bursts.end()
                }
                start = index
            }
        }

        // MARK: Focus suggestions

        /// `StackDetector.runs` over the folder's frames in name order, other files left out as the app
        /// leaves out stack documents.
        private mutating func focus(_ rows: UnsafeBufferPointer<Int32>) {
            order.removeAll(keepingCapacity: true)
            for (frame, place) in frames.enumerated() where columns.kinds[Int(rows[Int(place)])] != 0 {
                order.append(Int32(frame))
            }
            guard order.count >= StackDetector.minimumFrames else { return }
            let columns = columns
            let frames = frames
            func row(_ frame: Int32) -> Int {
                Int(rows[Int(frames[Int(frame)])])
            }
            order.sort { columns.nameRanks[row($0)] < columns.nameRanks[row($1)] }
            let longest = Int64(StackDetector.maximumGap * 1000)
            run.removeAll(keepingCapacity: true)
            gaps.removeAll(keepingCapacity: true)
            for frame in order {
                let current = row(frame)
                let date = columns.captured[current]
                if let last = run.last {
                    let previous = row(last)
                    let (gap, overflow) = date.subtractingReportingOverflow(columns.captured[previous])
                    let typical = gaps.isEmpty ? gap : gaps[gaps.count / 2]
                    if date != .min, !overflow, gap >= 0, gap <= longest, gap <= max(4 * typical, 2000),
                       columns.sameSettings(current, previous) {
                        var (low, high) = (0, gaps.count)
                        while low < high {
                            let middle = (low + high) / 2
                            (low, high) = gaps[middle] <= gap ? (middle + 1, high) : (low, middle)
                        }
                        gaps.insert(gap, at: low)
                    } else {
                        closeRun(row)
                    }
                }
                if date != .min {
                    run.append(frame)
                }
            }
            closeRun(row)
        }

        private mutating func closeRun(_ row: (Int32) -> Int) {
            if run.count >= StackDetector.minimumFrames {
                for frame in run {
                    found.focus.add(columns.ids[row(frame)])
                }
                found.focus.end()
            }
            run.removeAll(keepingCapacity: true)
            gaps.removeAll(keepingCapacity: true)
        }
    }
}
