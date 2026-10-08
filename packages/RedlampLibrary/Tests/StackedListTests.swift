import Foundation
import Testing
@testable import RedlampLibrary

struct StackedListTests {
    /// A burst of three raw and JPEG frames, a photo between, a pair, and a manual stack of a photo
    /// from another folder with the last photo, in capture order.
    private static func library() -> (library: StackLibrary, choices: StackChoices, ids: [String: Int64]) {
        var library = StackLibrary()
        var ids: [String: Int64] = [:]
        for frame in 0 ..< 3 {
            let (raw, jpeg) = library.addPair("IMG_000\(frame)", at: 1000 + Double(frame) / 8)
            (ids["raw\(frame)"], ids["jpeg\(frame)"]) = (raw, jpeg)
        }
        ids["between"] = library.add("Between.HEIC", at: 1100, camera: 2)
        (ids["pairRaw"], ids["pairJPEG"]) = library.addPair("IMG_0010", at: 1200)
        ids["far"] = library.add("Far.JPG", folder: 2, at: 1300)
        ids["last"] = library.add("Last.JPG", at: 1400, camera: 3)
        var choices = StackChoices()
        choices.stack([ids["far"]!, ids["last"]!], in: library.find())
        return (library, choices, ids)
    }

    @Test func `a closed stack is one cell where its top sits, and opening it inserts its others after it`() {
        let (library, choices, ids) = Self.library()
        let stacks = library.find(choices)
        let id = { (name: String) in ids[name]! }
        var stacked = StackedList(library.list, stacks: stacks)
        #expect(Array(stacked) == [id("raw0"), id("between"), id("pairRaw"), id("far")])
        #expect(stacked.count == 4 && stacked.map(\.self) == Array(stacked))
        #expect(stacked.badges(of: id("raw0")).stack == .init(kind: .burst, count: 3, isOpen: false))
        #expect(stacked.badges(of: id("raw0")).pair == nil)
        #expect(stacked.badges(of: id("pairRaw")).pair == .init(kind: .pair, count: 2, isOpen: false))
        #expect(stacked.badges(of: id("far")).stack == .init(kind: .manual, count: 2, isOpen: false))
        #expect(stacked.cell(for: id("jpeg2")) == id("raw0") && stacked.index(of: id("jpeg2")) == nil)
        #expect(stacked.photos(of: id("raw0")) == ["raw0", "jpeg0", "raw1", "jpeg1", "raw2", "jpeg2"].map(id))
        #expect(stacked.photos(of: id("between")) == [id("between")])

        var before = Array(stacked)
        var diff = stacked.open(id("raw0"))
        #expect(diff == PhotoListDiff(inserted: [1, 2], updated: [0]))
        #expect(Array(stacked) == ["raw0", "raw1", "raw2", "between", "pairRaw", "far"].map(id))
        #expect(stacked.applying(diff, to: before) == Array(stacked))
        #expect(stacked.badges(of: id("raw1")).pair == .init(kind: .pair, count: 2, isOpen: false))

        before = Array(stacked)
        diff = stacked.open(id("raw1"))
        #expect(diff == PhotoListDiff(inserted: [2], updated: [1]))
        #expect(Array(stacked) == ["raw0", "raw1", "jpeg1", "raw2", "between", "pairRaw", "far"].map(id))
        #expect(stacked.applying(diff, to: before) == Array(stacked))
        #expect(stacked.index(of: id("jpeg1")) == 2 && stacked.cell(for: id("jpeg2")) == id("raw2"))

        before = Array(stacked)
        diff = stacked.close(id("jpeg1"))
        #expect(diff == PhotoListDiff(removed: [2], updated: [1]))
        #expect(stacked.applying(diff, to: before) == Array(stacked))
        before = Array(stacked)
        diff = stacked.close(id("raw2"))
        #expect(diff == PhotoListDiff(removed: [1, 2], updated: [0]))
        #expect(Array(stacked) == ["raw0", "between", "pairRaw", "far"].map(id))
        #expect(stacked.open(id("between")).isEmpty && stacked.close(id("between")).isEmpty)
        #expect(stacked.open(id("jpeg0")).isEmpty, "a photo inside a closed stack has no cell")
    }

    @Test func `stacks relabelled with a view's own IDs show its list as the library's IDs show the library's`() throws {
        let (library, choices, ids) = Self.library()
        let id = { (name: String) in ids[name]! }
        let stacks = library.find(choices)
        let shown = ["raw0", "raw1", "jpeg1", "jpeg2", "between", "pairJPEG", "pairRaw", "last"].map(id)
        let own = Dictionary(uniqueKeysWithValues: shown.enumerated().map { ($1, Int64($0) * 3 + 10) })
        let largest = try #require(own.values.max())
        let relabelled = stacks.relabelled(above: largest) { own[$0] }
        #expect(relabelled.count(of: .pair) == 4 && relabelled.count(of: .burst) == 1)
        #expect(relabelled.count(of: .manual) == 1, "the manual stack keeps its photo from the other folder")
        #expect(relabelled.allSatisfy { stack in stack.photos.allSatisfy { photo in
            own.values.contains(photo) || photo > largest
        } })

        let list = PhotoList(source: .allPhotographs, ids: ContiguousArray(library.list.ids.filter(own.keys.contains)))
        let ownList = PhotoList(source: .allPhotographs, ids: ContiguousArray(list.ids.map { own[$0]! }))
        var theirs = StackedList(list, stacks: stacks)
        var mine = StackedList(ownList, stacks: relabelled)
        #expect(Array(mine) == Array(theirs).map { own[$0]! })
        #expect(try mine.badges(of: #require(own[id("raw0")])) == theirs.badges(of: id("raw0")))
        #expect(try mine.photos(of: #require(own[id("raw0")])) == theirs.photos(of: id("raw0")).map { own[$0]! })
        theirs.openAll()
        mine.openAll()
        #expect(Array(mine) == Array(theirs).map { own[$0]! })
        #expect(stacks.relabelled(above: 0) { _ in nil }.isEmpty, "stacks none of whose photos are shown go")
    }

    @Test func `the stacks shown are counted open and closed, a pair inside a closed burst not counted`() {
        let (library, choices, ids) = Self.library()
        let id = { (name: String) in ids[name]! }
        var stacked = StackedList(library.list, stacks: library.find(choices))
        #expect(stacked.stacksShown == (open: 0, closed: 3))
        stacked.open(id("raw0"))
        #expect(stacked.stacksShown == (open: 1, closed: 5), "the burst's three pairs are shown, closed")
        stacked.openAll()
        #expect(stacked.stacksShown == (open: 6, closed: 0))
    }

    @Test func `a selection of cells covers each closed stack's photos, and only those whose cell is selected`() {
        let (library, choices, ids) = Self.library()
        let id = { (name: String) in ids[name]! }
        let list = library.list
        var stacked = StackedList(list, stacks: library.find(choices))
        let burst = ["raw0", "jpeg0", "raw1", "jpeg1", "raw2", "jpeg2"].map(id)

        var selection = PhotoSelection()
        selection.select(id("raw0"), in: list)
        var covered = selection.covering(stacked, active: id("raw0"))
        #expect(covered.map { Set($0.ids(in: list)) } == Set(burst) && covered?.active == id("raw0"))
        #expect(covered?.covering(stacked, active: id("raw0")) == nil, "covered once, it's covered")

        selection.select([id("jpeg1"), id("between")], active: id("between"), in: list)
        covered = selection.covering(stacked, active: id("between"))
        #expect(covered.map { $0.ids(in: list) } == [id("between")], "a photo out of sight isn't selected alone")

        selection.select(id("jpeg2"), in: list)
        covered = selection.covering(stacked, active: id("jpeg2"))
        #expect(covered.map { Set($0.ids(in: list)) } == Set(burst) && covered?.active == id("raw0"))

        selection = PhotoSelection()
        covered = selection.covering(stacked, active: id("pairJPEG"))
        #expect(covered.map { $0.ids(in: list) } == [id("pairRaw"), id("pairJPEG")] && covered?.active == id("pairRaw"))
        #expect(selection.covering(stacked, active: id("between")) == nil)

        stacked.open(id("raw0"))
        selection.select(id("raw1"), in: list)
        covered = selection.covering(stacked, active: id("raw1"))
        #expect(covered.map { $0.ids(in: list) } == [id("raw1"), id("jpeg1")], "an open burst's pair is closed")
    }

    @Test func `a list holding only some of a stack's photos shows the first it has, and a lone one as itself`() {
        let (library, choices, ids) = Self.library()
        let id = { (name: String) in ids[name]! }
        let stacks = library.find(choices)
        let kept: Set<Int64> = Set(["jpeg0", "raw1", "jpeg1", "between", "pairJPEG", "last"].map(id))
        let list = PhotoList(
            source: .allPhotographs, sort: QuerySort(.rating),
            ids: ContiguousArray(library.list.ids.reversed().filter(kept.contains)),
        )
        let stacked = StackedList(list, stacks: stacks)
        #expect(Array(stacked) == ["last", "pairJPEG", "between", "jpeg0"].map(id))
        #expect(stacked.badges(of: id("jpeg0")).stack == .init(kind: .burst, count: 2, isOpen: false))
        #expect(stacked.badges(of: id("pairJPEG")) == (nil, nil) && stacked.badges(of: id("last")) == (nil, nil))
        #expect(stacked.photos(of: id("jpeg0")) == ["jpeg0", "raw1", "jpeg1"].map(id))
    }

    // MARK: - Selections

    @Test func `a closed stack's cell selects all of it, through opening and closing`() {
        let (library, choices, ids) = Self.library()
        let id = { (name: String) in ids[name]! }
        var stacked = StackedList(library.list, stacks: library.find(choices))
        let burst = ["raw0", "jpeg0", "raw1", "jpeg1", "raw2", "jpeg2"].map(id)
        var selection = StackSelection()
        selection.select(id("raw0"), in: stacked)
        #expect(selection.photos(in: stacked) == ContiguousArray(burst))
        #expect(selection.contains(photo: id("jpeg2"), in: stacked) && !selection.contains(
            photo: id("last"),
            in: stacked,
        ))

        stacked.open(id("raw0"), selection: &selection)
        #expect(selection.count == 3 && selection.active == id("raw0"))
        #expect(selection.photos(in: stacked) == ContiguousArray(burst))
        selection.select(id("raw2"), in: stacked)
        #expect(Array(selection.photos(in: stacked)) == [id("raw2"), id("jpeg2")])
        stacked.close(id("raw1"), selection: &selection)
        #expect(selection.count == 1 && selection.active == id("raw0"))
        #expect(selection.photos(in: stacked) == ContiguousArray(burst), "one frame selected closes as all of it")

        selection.invert(in: stacked)
        #expect(Array(selection.photos(in: stacked)) == ["between", "pairRaw", "pairJPEG", "far", "last"].map(id))
        #expect(selection.active == id("between") && selection.count == 3)
        selection.toggle(id("between"), in: stacked)
        #expect(selection.active == id("pairRaw") && selection.count == 2)
        selection.selectAll(in: stacked)
        #expect(selection.count == 4 && selection.photos(in: stacked).count == library.photos.count)
        selection.select(id("between"), in: stacked)
        selection.extend(to: id("far"), in: stacked)
        #expect(Array(selection.photos(in: stacked)) == ["between", "pairRaw", "pairJPEG", "far", "last"].map(id))
        selection.selectNone()
        stacked.open(id("raw0"), selection: &selection)
        #expect(selection.isEmpty && selection.active == nil)
    }

    @Test func `a list made again after photos change and stacks are found again keeps what's open and selected`() {
        let (made, chosen, ids) = Self.library()
        var (library, choices) = (made, chosen)
        let id = { (name: String) in ids[name]! }
        var stacked = StackedList(library.list, stacks: library.find(choices))
        stacked.open(id("raw0"))
        var selection = StackSelection()
        selection.select(id("pairRaw"), in: stacked)
        selection.toggle(id("raw1"), in: stacked)

        let (raw, jpeg) = library.addPair("IMG_0003", at: 1000 + 3.0 / 8)
        let old = Array(stacked)
        var (updated, diff) = stacked.updated(
            list: library.list, stacks: library.find(choices), changed: [raw, jpeg], selection: &selection,
        )
        #expect(Array(updated) == ["raw0", "raw1", "raw2"].map(id) + [raw] + ["between", "pairRaw", "far"].map(id))
        #expect(updated.applying(diff, to: old) == Array(updated))
        #expect(diff.inserted == [3] && diff.updated == [0], "the burst's badge counts four")
        #expect(Array(selection.photos(in: updated)) == ["raw1", "jpeg1", "pairRaw", "pairJPEG"].map(id))
        #expect(selection.active == id("raw1"))

        choices.unstack([id("raw1")], in: updated.stacks)
        let unstacked = Array(updated)
        (updated, diff) = updated.updated(stacks: library.find(choices), selection: &selection)
        #expect(Array(updated) == [id("raw0"), id("raw2"), raw, id("raw1"), id("between"), id("pairRaw"), id("far")])
        #expect(updated.applying(diff, to: unstacked) == Array(updated))
        #expect(Array(selection.photos(in: updated)) == ["raw1", "jpeg1", "pairRaw", "pairJPEG"].map(id))

        let update = PhotoListUpdate(
            list: library.list, diff: PhotoListDiff(from: updated.list, to: library.list, changed: [id("between")]),
        )
        let again = updated.updated(update, selection: &selection)
        #expect(again.diff == PhotoListDiff(updated: [4]) && Array(again.list) == Array(updated))
        let reset = updated.updated(
            PhotoListUpdate(list: library.list, diff: PhotoListDiff(reset: true)), selection: &selection,
        )
        #expect(reset.diff.reset && Array(reset.list) == Array(updated))
        #expect(Array(selection.photos(in: reset.list)) == ["raw1", "jpeg1", "pairRaw", "pairJPEG"].map(id))
    }

    // MARK: - Against a model

    /// A library of bursts, pairs, photos alone and manual stacks across folders, from a seed.
    private static func randomLibrary(_ random: inout SeededRandom) -> (StackLibrary, StackChoices) {
        var library = StackLibrary()
        var time = 1000.0
        for _ in 0 ..< random.int(in: 1 ... 40) {
            let folder = Int64(1 + random.int(below: 3))
            let frames = random.int(below: 3) == 0 ? random.int(in: 2 ... 5) : 1
            for frame in 0 ..< frames {
                let name = "F\(folder)-\(library.photos.count)"
                if random.int(below: 3) == 0 {
                    library.addPair(name, folder: folder, at: time + Double(frame) / 8)
                } else {
                    library.add(name + ".JPG", folder: folder, at: time + Double(frame) / 8)
                }
            }
            time += 10
        }
        var choices = StackChoices()
        for _ in 0 ..< random.int(in: 0 ... 3) {
            let picked = (0 ..< random.int(in: 1 ... 4)).map { _ in Int64(1 + random.int(below: library.photos.count)) }
            choices.stack(picked, in: library.find(choices))
        }
        return (library, choices)
    }

    /// The stacks a list shows as one: bursts and manual stacks with two frames or more in it, by
    /// their frames' photos in it, and pairs with two photos or more in it.
    private struct Model {
        let list: PhotoList
        let stacks: Stacks
        var open: Set<Int> = []
        var groups: [Int: [[Int64]]] = [:]
        var pairs: [Int: [Int64]] = [:]

        init(_ list: PhotoList, _ stacks: Stacks) {
            self.list = list
            self.stacks = stacks
            for group in stacks.groups {
                let frames = stacks.members(of: group).map { stacks.frame(of: $0).filter { list.contains($0) } }
                    .filter { !$0.isEmpty }
                if frames.count > 1 {
                    groups[group] = frames
                }
            }
            for pair in stacks.pairs {
                let present = stacks.members(of: pair).filter { list.contains($0) }
                if present.count > 1 {
                    pairs[pair] = present
                }
            }
        }

        func group(of id: Int64) -> Int? {
            stacks.groupIndex(of: id).flatMap { groups[$0] == nil ? nil : $0 }
        }

        func pair(of id: Int64) -> Int? {
            stacks.pairIndex(of: id).flatMap { pairs[$0] == nil ? nil : $0 }
        }

        func isVisible(_ pair: Int) -> Bool {
            group(of: pairs[pair]![0]).map(open.contains) ?? true
        }

        /// Each cell, with the photos it stands for.
        var cells: [(cell: Int64, photos: [Int64])] {
            var cells: [(Int64, [Int64])] = []
            for id in list.ids {
                if let group = group(of: id) {
                    let frames = groups[group]!
                    guard id == frames[0][0] else { continue }
                    guard open.contains(group) else {
                        cells.append((id, frames.flatMap(\.self)))
                        continue
                    }
                    for frame in frames {
                        if let pair = pair(of: frame[0]), open.contains(pair) {
                            cells += frame.map { ($0, [$0]) }
                        } else {
                            cells.append((frame[0], frame))
                        }
                    }
                } else if let pair = pair(of: id) {
                    let photos = pairs[pair]!
                    guard id == photos[0] else { continue }
                    cells += open.contains(pair) ? photos.map { ($0, [$0]) } : [(id, photos)]
                } else {
                    cells.append((id, [id]))
                }
            }
            return cells
        }

        /// What opening cell `id` does: a closed stack of frames it's first of opens, else such a pair.
        mutating func open(_ id: Int64) {
            if let group = group(of: id), groups[group]![0][0] == id, !open.contains(group) {
                open.insert(group)
            } else if let pair = pair(of: id), pairs[pair]![0] == id, !open.contains(pair), isVisible(pair) {
                open.insert(pair)
            }
        }

        /// What closing cell `id` does: the open pair it's in closes, else the open stack of frames.
        mutating func close(_ id: Int64) {
            if let pair = pair(of: id), open.contains(pair), isVisible(pair) {
                open.remove(pair)
            } else if let group = group(of: id), open.contains(group) {
                open.remove(group)
            }
        }

        /// The photos of the stack closing cell `cell` closes: none when nothing closes.
        func photos(closingAt cell: Int64) -> Set<Int64> {
            var model = self
            model.close(cell)
            guard model.open != open, let closed = model.cells.first(where: { $0.photos.contains(cell) }) else {
                return []
            }
            return Set(closed.photos)
        }
    }

    @Test(arguments: 1 ... 40)
    func `cells, their photos and the diffs of opening and closing stacks match a model`(seed: Int) throws {
        var random = SeededRandom(seed: UInt64(seed))
        let (library, choices) = Self.randomLibrary(&random)
        let stacks = library.find(choices)
        var ids = library.list.ids.filter { _ in random.int(below: 6) != 0 }
        if random.int(below: 2) == 0 {
            ids.shuffle(using: &random)
        }
        let list = PhotoList(source: .allPhotographs, sort: QuerySort(), ids: ContiguousArray(ids))
        var model = Model(list, stacks)
        var stacked = StackedList(list, stacks: stacks)
        var selection = StackSelection()
        var selected = Set<Int64>()

        func check(_ step: String) {
            let cells = model.cells
            #expect(Array(stacked) == cells.map(\.cell), "\(step)")
            #expect(stacked.count == cells.count && (0 ..< stacked.count).map { stacked[$0] } == cells.map(\.cell))
            for (index, cell) in cells.enumerated() {
                #expect(
                    stacked.index(of: cell.cell) == index && stacked.photos(of: cell.cell) == cell.photos,
                    "\(step)",
                )
                for photo in cell.photos {
                    #expect(stacked.cell(for: photo) == cell.cell, "\(step): \(photo)")
                }
            }
            #expect(Set(selection.photos(in: stacked)) == selected, "\(step)")
            #expect(selection.count == cells.count { !selected.isDisjoint(with: $0.photos) }, "\(step)")
            #expect(selection.active.map { selection.contains($0) && stacked.isShown($0) } ?? selection.isEmpty)
        }
        check("closed")
        for step in 0 ..< 60 where !stacked.isEmpty {
            let cell = stacked[random.int(below: stacked.count)]
            let before = Array(stacked)
            let diff: PhotoListDiff
            switch random.int(below: 10) {
            case 0 ... 3:
                diff = stacked.open(cell, selection: &selection)
                model.open(cell)
            case 4 ... 6:
                let closing = model.photos(closingAt: cell)
                if !selected.isDisjoint(with: closing) {
                    selected.formUnion(closing)
                }
                diff = stacked.close(cell, selection: &selection)
                model.close(cell)
            case 7:
                selection.toggle(cell, in: stacked)
                let photos = Set(stacked.photos(of: cell))
                if photos.isSubset(of: selected) {
                    selected.subtract(photos)
                } else {
                    selected.formUnion(photos)
                }
                diff = PhotoListDiff()
            case 8:
                let anchor = selection.active.flatMap { stacked.index(of: $0) }
                selection.extend(to: cell, in: stacked)
                let target = try #require(stacked.index(of: cell))
                let range = anchor.map { min($0, target) ... max($0, target) } ?? target ... target
                if anchor == nil {
                    selected = []
                }
                for index in range {
                    selected.formUnion(stacked.photos(of: stacked[index]))
                }
                diff = PhotoListDiff()
            default:
                selection.select(cell, in: stacked)
                selected = Set(stacked.photos(of: cell))
                diff = PhotoListDiff()
            }
            #expect(stacked.applying(diff, to: before) == Array(stacked), "step \(step)")
            check("step \(step)")
        }

        let before = Array(stacked)
        let opened = stacked.openAll(selection: &selection)
        model.open = Set(stacks.indices)
        #expect(stacked.applying(opened, to: before) == Array(stacked) && opened.removed.isEmpty)
        check("all open")
        let closing = Array(stacked)
        let closed = stacked.closeAll(selection: &selection)
        model.open = []
        for cell in model.cells where !selected.isDisjoint(with: cell.photos) {
            selected.formUnion(cell.photos)
        }
        #expect(stacked.applying(closed, to: closing) == Array(stacked) && closed.inserted.isEmpty)
        check("all closed")
    }
}

extension StackedList {
    /// `diff` applied to `old`'s cells, its inserted cells taken from this list's.
    func applying(_ diff: PhotoListDiff, to old: [Int64]) -> [Int64] {
        var cells = old
        diff.apply(to: &cells) { self[$0] }
        return cells
    }
}
