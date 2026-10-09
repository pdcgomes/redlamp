import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Groups in lists (LIB-41): a list's photos under its Group By, each group's header and, while it's
/// open, its cells, with stacks closed in their group; opening and closing groups and stacks with
/// diffs; and the list grouped again as it changes.
struct GroupedListTests {
    private typealias Item = GroupedList.Item

    /// Three moments two hours apart and a scan without a capture time: a burst of three raw and JPEG
    /// frames and two photos alone; a raw and its JPEG and two photos alone; and two photos alone.
    private static func library() -> (library: GroupLibrary, id: (String) -> Int64) {
        var library = GroupLibrary()
        var ids: [String: Int64] = [:]
        let ten = GroupLibrary.june14 + 10 * 3600
        for frame in 0 ..< 3 {
            ids["raw\(frame)"] = library.add("BURST_\(frame).NEF", at: ten + Double(frame) / 8)
            ids["jpeg\(frame)"] = library.add("BURST_\(frame).JPG", at: ten + Double(frame) / 8)
        }
        ids["a1"] = library.add("A1.JPG", at: ten + 5)
        ids["a2"] = library.add("A2.JPG", at: ten + 10)
        ids["pRaw"] = library.add("P.NEF", at: ten + 7200)
        ids["pJPEG"] = library.add("P.JPG", at: ten + 7200)
        ids["b1"] = library.add("B1.JPG", at: ten + 7207)
        ids["b2"] = library.add("B2.JPG", at: ten + 7213)
        ids["c1"] = library.add("C1.JPG", at: ten + 14400)
        ids["c2"] = library.add("C2.JPG", at: ten + 14404)
        ids["scan"] = library.add("SCAN.TIF", at: nil, camera: nil)
        let found = ids
        return (library, { found[$0]! })
    }

    @Test func `groups open and close with diffs that turn the items before into those after`() {
        let (library, id) = Self.library()
        let grouping = library.grouping()
        var grouped = grouping.grouped(library.list, by: .moment)
        func photo(_ name: String) -> Item {
            .photo(id(name))
        }
        let a: [Item] = [.header(0), photo("raw0"), photo("a1"), photo("a2")]
        let b: [Item] = [.header(1), photo("pRaw"), photo("b1"), photo("b2")]
        let c: [Item] = [.header(2), photo("c1"), photo("c2")]
        let undated: [Item] = [.header(3), photo("scan")]
        #expect(Array(grouped) == a + b + c + undated)
        #expect(grouped.groups.map(\.count) == [8, 4, 2, 1] && grouped.count == 13)
        #expect((0 ..< 4).map(grouped.index(ofHeader:)) == [0, 4, 8, 11])
        #expect(grouped.index(of: id("b1")) == 6 && grouped.group(at: 6) == 1 && grouped.group(at: 8) == 2)
        #expect(grouped.index(of: id("jpeg0")) == nil, "a photo inside a closed stack has no item")
        #expect(grouped.cellCount(of: 0) == 3 && grouped.isVisible(id("a1")) && !grouped.isVisible(id("jpeg1")))

        var before = Array(grouped)
        var diff = grouped.close(1)
        #expect(diff == PhotoListDiff(removed: [5, 6, 7], updated: [4]))
        #expect(Array(grouped) == a + [.header(1)] + c + undated)
        #expect(grouped.applying(diff, to: before) == Array(grouped))
        #expect(grouped.index(of: id("b1")) == nil && !grouped.isVisible(id("b1")) && grouped.index(ofHeader: 2) == 5)
        #expect(grouped.cellCount(of: 1) == 3 && !grouped.isOpen(1) && grouped.close(1).isEmpty)

        before = Array(grouped)
        diff = grouped.open(1)
        #expect(diff == PhotoListDiff(inserted: [5, 6, 7], updated: [4]))
        #expect(grouped.applying(diff, to: before) == Array(grouped) && grouped.open(1).isEmpty)

        grouped.close(0)
        before = Array(grouped)
        diff = grouped.closeAll()
        #expect(diff == PhotoListDiff(removed: [2, 3, 4, 6, 7, 9], updated: [1, 2, 3]))
        #expect(Array(grouped) == [.header(0), .header(1), .header(2), .header(3)])
        #expect(grouped.applying(diff, to: before) == Array(grouped))

        before = Array(grouped)
        diff = grouped.openAll()
        #expect(diff == PhotoListDiff(inserted: [1, 2, 3, 5, 6, 7, 9, 10, 12], updated: [0, 4, 8, 11]))
        #expect(grouped.applying(diff, to: before) == Array(grouped) && Array(grouped) == a + b + c + undated)

        let closed = grouping.grouped(library.list, by: .moment, open: false)
        #expect(Array(closed) == [.header(0), .header(1), .header(2), .header(3)])
        #expect(grouping.grouped(PhotoList(source: .allPhotographs, ids: []), by: .moment).isEmpty)
    }

    @Test func `a closed stack is one cell in its photo's group, and opens and closes there`() {
        let (library, id) = Self.library()
        var grouped = library.grouping().grouped(library.list, by: .moment)
        func photo(_ name: String) -> Item {
            .photo(id(name))
        }
        let burst = ["raw0", "jpeg0", "raw1", "jpeg1", "raw2", "jpeg2"].map(id)
        #expect(grouped.stacked.badges(of: id("raw0")).stack == .init(kind: .burst, count: 3, isOpen: false))
        #expect(grouped.stacked.photos(of: id("raw0")) == burst)
        #expect(grouped.stacked.badges(of: id("pRaw")).pair == .init(kind: .pair, count: 2, isOpen: false))

        var before = Array(grouped)
        var diff = grouped.openStack(id("raw0"))
        #expect(diff == PhotoListDiff(inserted: [2, 3], updated: [1]))
        #expect(Array(grouped.prefix(7)) == [
            .header(0), photo("raw0"), photo("raw1"), photo("raw2"), photo("a1"), photo("a2"), .header(1),
        ])
        #expect(grouped.applying(diff, to: before) == Array(grouped))
        #expect(grouped.cellCount(of: 0) == 5 && grouped.index(ofHeader: 1) == 6 && grouped.index(of: id("raw2")) == 3)

        before = Array(grouped)
        diff = grouped.openStack(id("raw1"))
        #expect(diff == PhotoListDiff(inserted: [3], updated: [2]))
        #expect(grouped[3] == photo("jpeg1") && grouped.applying(diff, to: before) == Array(grouped))

        before = Array(grouped)
        diff = grouped.openStack(id("pRaw"))
        #expect(diff == PhotoListDiff(inserted: [9], updated: [8]))
        #expect(grouped.applying(diff, to: before) == Array(grouped) && grouped[9] == photo("pJPEG"))

        grouped.close(0)
        #expect(grouped.closeStack(id("raw2")).isEmpty, "a closed group's stacks stay as they are")
        before = Array(grouped)
        diff = grouped.open(0)
        #expect(diff == PhotoListDiff(inserted: [1, 2, 3, 4, 5, 6], updated: [0]), "the burst comes back open")
        #expect(grouped.applying(diff, to: before) == Array(grouped))

        before = Array(grouped)
        diff = grouped.closeStack(id("raw2"))
        #expect(diff == PhotoListDiff(removed: [2, 3, 4], updated: [1]))
        #expect(grouped.applying(diff, to: before) == Array(grouped))
        #expect(Array(grouped.prefix(5)) == [.header(0), photo("raw0"), photo("a1"), photo("a2"), .header(1)])
        #expect(grouped.openStack(id("a1")).isEmpty && grouped.openStack(id("jpeg2")).isEmpty)

        let byFolder = library.grouping().grouped(library.list, by: .folder)
        #expect(byFolder.count == library.photos.count - 6 + 1, "every photo in one folder, each stack one cell")
    }

    @Test func `every stack opens and closes in every group, and the stacks open in another list open here`() {
        let (library, id) = Self.library()
        var grouped = library.grouping().grouped(library.list, by: .moment)
        grouped.close(2)
        var before = Array(grouped)
        var diff = grouped.openAllStacks()
        #expect(grouped.applying(diff, to: before) == Array(grouped))
        #expect(grouped.stacked.stacksShown == (open: 5, closed: 0) && grouped.index(of: id("jpeg2")) == 6)
        #expect(diff.updated == [1, 10] && diff.removed.isEmpty, "the burst's and the pair's first cells")

        before = Array(grouped)
        diff = grouped.closeAllStacks()
        #expect(grouped.applying(diff, to: before) == Array(grouped))
        #expect(Array(grouped) == Array(library.grouping().grouped(library.list, by: .moment)).filter { item in
            if case let .photo(photo) = item {
                return grouped.isVisible(photo)
            }
            return true
        })

        var other = StackedList(library.list, stacks: library.grouping().stacks)
        other.open(id("raw0"))
        other.open(id("pRaw"))
        before = Array(grouped)
        diff = grouped.openStacks(as: other)
        #expect(grouped.applying(diff, to: before) == Array(grouped))
        #expect(grouped.index(of: id("raw1")) == 2 && grouped.index(of: id("jpeg1")) == nil)
        #expect(grouped.stacked.badges(of: id("pRaw")).pair?.isOpen == true)
        #expect(grouped.openStacks(as: other).isEmpty, "opened alike, nothing changes")
    }

    @Test func `a list changing under its groups keeps what's open and selected, with a diff from what changed`() {
        var (library, id) = Self.library()
        var grouped = library.grouping().grouped(library.list, by: .moment)
        grouped.close(1)
        grouped.openStack(id("raw0"))
        var selection = StackSelection()
        selection.select(id("c1"), in: grouped)
        func photo(_ name: String) -> Item {
            .photo(id(name))
        }
        let ten = GroupLibrary.june14 + 10 * 3600
        let c3 = library.add("C3.JPG", at: ten + 14408)
        let d1 = library.add("D1.JPG", at: ten + 28800)
        library.setFlag(.pick, of: id("b1"))
        let list = PhotoList(source: .allPhotographs, ids: library.list.ids.filter { $0 != id("a2") })
        let grouping = library.grouping()

        let (updated, diff) = grouped.updated(
            list: list,
            grouping: grouping,
            changed: [id("b1")],
            selection: &selection,
        )
        #expect(Array(updated) == [
            .header(0), photo("raw0"), photo("raw1"), photo("raw2"), photo("a1"), .header(1), .header(2),
            photo("c1"), photo("c2"), .photo(c3), .header(3), .photo(d1), .header(4), photo("scan"),
        ])
        #expect(!updated.isOpen(1) && updated.isOpen(3) && updated.groups[1].picks == 1)
        #expect(diff == PhotoListDiff(removed: [5], inserted: [9, 10, 11], updated: [0, 5, 6]))
        #expect(Self.applying(diff, from: grouped, to: updated))
        #expect(selection.photos(in: updated) == [id("c1")] && selection.active == id("c1"))

        let update = PhotoListUpdate(list: list, diff: PhotoListDiff(reset: true))
        let reset = grouped.updated(update, grouping: grouping, selection: &selection)
        #expect(reset.diff.reset && Array(reset.list) == Array(updated))

        selection.select(id("c2"), in: updated)
        var closing = updated
        closing.closeAll()
        let unchanged = closing.updated(grouping: grouping, selection: &selection)
        #expect(unchanged.diff.isEmpty && Array(unchanged.list) == Array(closing))
        #expect(selection.isEmpty, "a cell of a closed group isn't kept selected")
        let regrouped = unchanged.list.updated(grouping: library.grouping(), selection: &selection)
        #expect(regrouped.list.count == 5 && regrouped.diff.isEmpty)
    }

    @Test func `a stack crossing two moments stays whole in its top's group as the list changes`() {
        var library = GroupLibrary()
        let morning = library.shoot(4, from: GroupLibrary.june14 + 9 * 3600) { _ in 6 }
        let evening = library.shoot(4, from: GroupLibrary.june14 + 18 * 3600) { _ in 6 }
        library.choices.stack([evening[1], morning[2]], top: evening[1], in: library.grouping().stacks)
        let grouping = library.grouping()
        var grouped = grouping.grouped(library.list, by: .moment)
        var expected: [Item] = [.header(0)]
        expected += [morning[0], morning[1], morning[3]].map(Item.photo)
        expected.append(.header(1))
        expected += evening.map(Item.photo)
        #expect(Array(grouped) == expected)
        #expect(grouped.stacked.photos(of: evening[1]) == [evening[1], morning[2]])
        #expect(grouped.groups.allSatisfy { $0.filter == nil })
        let before = Array(grouped)
        let diff = grouped.openStack(evening[1])
        #expect(diff == PhotoListDiff(inserted: [7], updated: [6]) && grouped[7] == .photo(morning[2]))
        #expect(grouped.applying(diff, to: before) == Array(grouped))

        var selection = StackSelection()
        let later = library.add("LATE.NEF", at: GroupLibrary.june14 + 18 * 3600 + 30)
        let changed = grouped.updated(list: library.list, grouping: library.grouping(), selection: &selection)
        #expect(changed.list[7] == .photo(morning[2]) && changed.list.last == .photo(later), "still open")
        #expect(changed.diff == PhotoListDiff(inserted: [10], updated: [4]))
        #expect(Self.applying(changed.diff, from: grouped, to: changed.list))
    }

    @Test func `a selection holds no cell of a closed group, and reaches only the groups on show`() {
        let (library, id) = Self.library()
        var grouped = library.grouping().grouped(library.list, by: .moment)
        var selection = StackSelection()
        selection.select(id("b1"), in: grouped)
        selection.toggle(id("c1"), in: grouped)
        selection.toggle(id("b2"), in: grouped)
        #expect(selection.active == id("b2") && selection.count == 3)
        grouped.close(1, selection: &selection)
        #expect(selection.count == 1 && selection.active == id("c1") && selection.photos(in: grouped) == [id("c1")])

        selection.select(id("a1"), in: grouped)
        selection.extend(to: id("c2"), in: grouped)
        #expect(Array(selection.photos(in: grouped)) == ["a1", "a2", "c1", "c2"].map(id))
        selection.select(id("b1"), in: grouped)
        selection.toggle(id("b2"), in: grouped)
        #expect(selection.active == id("a1") && selection.count == 4, "cells out of sight can't be selected")

        selection.selectAll(in: grouped)
        #expect(selection.count == 6 && selection.active == id("a1"))
        #expect(selection.photos(in: grouped).count == 11, "the burst's six, A2, C1, C2 and the scan")
        selection.toggle(id("scan"), in: grouped)
        selection.invert(in: grouped)
        #expect(Array(selection.photos(in: grouped)) == [id("scan")] && selection.active == id("scan"))

        selection.select(id("raw0"), in: grouped)
        grouped.openStack(id("raw0"), selection: &selection)
        #expect(selection.count == 3 && selection.photos(in: grouped).count == 6)
        grouped.close(0, selection: &selection)
        #expect(selection.isEmpty && selection.active == nil)
        selection.select(id("c2"), in: grouped)
        grouped.closeAll(selection: &selection)
        #expect(selection.isEmpty && selection.active == nil)
    }

    @Test func `the cells on show run group after group, and a step from a photo goes past headers and closed groups`() {
        let (library, id) = Self.library()
        var grouped = library.grouping().grouped(library.list, by: .moment)
        func names(_ cells: some Sequence<Int64>) -> [String] {
            let byID = Dictionary(uniqueKeysWithValues: [
                "raw0",
                "raw1",
                "raw2",
                "jpeg1",
                "a1",
                "a2",
                "pRaw",
                "pJPEG",
                "b1",
                "b2",
                "c1",
                "c2",
                "scan",
            ].map { (id($0), $0) })
            return cells.map { byID[$0] ?? "?" }
        }
        #expect(names(grouped.cells) == ["raw0", "a1", "a2", "pRaw", "b1", "b2", "c1", "c2", "scan"])
        #expect(grouped.cellIndex(of: id("b1")) == 4 && grouped.cellIndex(of: id("scan")) == 8)
        #expect(grouped.cellIndex(of: id("jpeg1")) == nil, "a photo inside a closed stack has no cell of its own")

        grouped.close(1)
        #expect(names(grouped.cells) == ["raw0", "a1", "a2", "c1", "c2", "scan"])
        #expect(grouped.cellIndex(of: id("c1")) == 3 && grouped.cellIndex(of: id("b1")) == nil)
        #expect(grouped.cell(1, from: id("a2")) == id("c1"), "→ passes over a closed group")
        #expect(grouped.cell(-1, from: id("c1")) == id("a2"))
        #expect(grouped.cell(1, from: id("b1")) == id("c1") && grouped.cell(-1, from: id("b1")) == id("a2"))
        #expect(grouped.cell(1, from: id("jpeg1")) == id("a1"), "from inside a closed stack, the cell after it")
        #expect(grouped.cell(-1, from: id("raw0")) == nil && grouped.cell(1, from: id("scan")) == nil)

        #expect(grouped.cell(after: [id("a1"), id("jpeg2")]) == id("a2"), "after the last of them in the grid's order")
        #expect(grouped.cell(after: [id("c2"), id("raw0")]) == id("scan"))
        #expect(grouped.cell(after: [id("a2")]) == id("c1") && grouped.cell(after: [id("b2")]) == id("c1"))
        #expect(grouped.cell(after: [id("scan")]) == nil && grouped.cell(after: []) == nil)

        grouped.open(1)
        grouped.openStack(id("raw0"))
        #expect(names(grouped.cells.prefix(5)) == ["raw0", "raw1", "raw2", "a1", "a2"])
        #expect(grouped.cell(after: [id("raw0")]) == id("raw1") && grouped.cell(1, from: id("jpeg1")) == id("raw2"))
        #expect(grouped.cellIndex(of: id("pRaw")) == 5)
        grouped.closeAll()
        #expect(grouped.cells.isEmpty && grouped.cell(1, from: id("a1")) == nil && grouped
            .cell(after: [id("a1")]) == nil)
    }

    @Test func `groups relabelled with a view's own IDs keep each photo's group, name, picks and filter`() throws {
        var (library, id) = Self.library()
        library.setFlag(.pick, of: id("b1"))
        let list = library.list
        let grouping = library.grouping()
        let groups = grouping.groups(of: list, by: .moment)
        // A view's IDs: the list's photos numbered from 1000 the other way round.
        let own = PhotoList(source: list.source, sort: list.sort, ids: ContiguousArray(list.ids.indices.map {
            Int64(1000 + list.count - $0)
        }))
        let viewID = { (photo: Int64) in own.ids[list.index(of: photo)!] }
        let relabelled = groups.relabelled(as: own)
        #expect(relabelled.list == own && relabelled.count == groups.count)
        #expect(relabelled.photoSets == groups.photoSets.map { $0.map(viewID) })
        #expect(relabelled.map(\.name) == groups.map(\.name) && relabelled.map(\.picks) == [0, 1, 0, 0])
        #expect(relabelled.map(\.filter) == groups.map(\.filter) && relabelled.map(\.value) == groups.map(\.value))
        #expect(relabelled.index(of: viewID(id("b1"))) == 1 && relabelled.index(of: id("b1")) == nil)

        var grouped = GroupedList(relabelled, stacks: Stacks())
        #expect(grouped.count == list.count + groups.count, "without stacks every photo has a cell")
        let b1 = try #require(Array(relabelled[1].photos).firstIndex(of: viewID(id("b1"))))
        #expect(grouped.index(ofHeader: 1) == 9 && grouped.index(of: viewID(id("b1"))) == 10 + b1)
        let diff = grouped.close(0)
        #expect(diff == PhotoListDiff(removed: IndexSet(integersIn: 1 ... 8), updated: [0]))
        #expect(!grouped.isVisible(viewID(id("a1"))) && grouped.isVisible(viewID(id("b1"))))
    }
}

extension GroupedListTests {
    // MARK: - Against a model

    /// Shoots of photos alone, bursts and raw and JPEG pairs from two cameras into two folders, hours
    /// apart, scans without a capture time, and manual stacks across them, from a seed.
    private static func randomLibrary(_ random: inout SeededRandom) -> GroupLibrary {
        var library = GroupLibrary()
        library.folders[2] = "/Volumes/Test/Photos/Other"
        var time = GroupLibrary.june14 + 8 * 3600
        for _ in 0 ..< random.int(in: 1 ... 6) {
            for _ in 0 ..< random.int(in: 1 ... 12) {
                let (folder, camera) = (Int64(1 + random.int(below: 2)), Int64(1 + random.int(below: 2)))
                let frames = random.int(below: 4) == 0 ? random.int(in: 2 ... 4) : 1
                for frame in 0 ..< frames {
                    let base = "F\(library.photos.count)"
                    let at = time + Double(frame) / 8
                    if random.int(below: 3) == 0 {
                        library.add(base + ".NEF", at: at, folder: folder, camera: camera)
                    }
                    library.add(base + ".JPG", at: at, folder: folder, camera: camera)
                }
                time += Double(random.int(in: 3 ... 20))
            }
            time += Double(random.int(in: 2 ... 30) * 3600)
        }
        for _ in 0 ..< random.int(in: 0 ... 2) {
            library.add("SCAN_\(library.photos.count).TIF", at: nil, camera: nil)
        }
        for _ in 0 ..< random.int(in: 0 ... 2) {
            let picked = (0 ..< random.int(in: 2 ... 3)).map { _ in Int64(1 + random.int(below: library.photos.count)) }
            library.choices.stack(picked, in: library.grouping().stacks)
        }
        return library
    }

    /// The items a grouped list should show: its groups' headers, and each open group's cells, the
    /// photos in it of a stacked list of every group's photos, its stacks opened alike.
    private struct Model {
        let groups: PhotoGroups
        var stacked: StackedList
        var open: Set<Int>

        init(groups: PhotoGroups, stacked: StackedList, open: Set<Int>) {
            self.groups = groups
            self.stacked = stacked
            self.open = open
        }

        /// `grouped`'s groups and their state, every stack closed.
        init(_ grouped: GroupedList) {
            self.init(
                groups: grouped.groups,
                stacked: StackedList(GroupedList.cells(of: grouped.groups), stacks: grouped.stacked.stacks),
                open: Set(grouped.groups.indices.filter(grouped.isOpen)),
            )
        }

        var items: [Item] {
            var cells = [[Item]](repeating: [], count: groups.count)
            for cell in stacked {
                cells[groups.index(of: cell) ?? 0].append(.photo(cell))
            }
            return groups.indices.flatMap { [Item.header($0)] + (open.contains($0) ? cells[$0] : []) }
        }
    }

    @Test(arguments: 1 ... 30)
    func `items, their indexes and the diffs of opening and closing groups and stacks match a model`(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed))
        let library = Self.randomLibrary(&random)
        let keys: [GroupKey] = [.moment, .momentCamera, .day, .folder, .camera, .ungrouped]
        let key = keys[random.int(below: keys.count)]
        var ids = library.list.ids.filter { _ in random.int(below: 6) != 0 }
        if random.int(below: 2) == 0 {
            ids.shuffle(using: &random)
        }
        let list = PhotoList(source: .allPhotographs, ids: ContiguousArray(ids))
        var grouped = library.grouping().grouped(list, by: key, open: random.int(below: 3) != 0)
        var model = Model(grouped)
        var selection = StackSelection()

        func check(_ step: String) {
            let items = model.items
            #expect(Array(grouped) == items, "\(key) \(step)")
            #expect(grouped.count == items.count && grouped.reduce(0) { count, _ in count + 1 } == items.count)
            for (index, item) in items.enumerated() {
                switch item {
                case let .header(group):
                    #expect(grouped.index(ofHeader: group) == index && grouped.group(at: index) == group, "\(step)")
                case let .photo(cell):
                    #expect(grouped.index(of: cell) == index && grouped.isVisible(cell), "\(step)")
                    #expect(grouped.group(at: index) == grouped.groups.index(of: cell), "\(step)")
                }
            }
            #expect(selection.photos(in: grouped)
                .allSatisfy { grouped.stacked.cell(for: $0).map(grouped.isVisible) == true })
            #expect(selection.active.map { selection.contains($0) && grouped.isVisible($0) } ?? selection.isEmpty)
        }
        check("start")
        for step in 0 ..< 60 where !grouped.isEmpty {
            let item = grouped[random.int(below: grouped.count)]
            let before = Array(grouped)
            var diff = PhotoListDiff()
            switch (random.int(below: 10), item) {
            case let (0 ... 4, .header(group)):
                if model.open.contains(group) {
                    diff = grouped.close(group, selection: &selection)
                    model.open.remove(group)
                } else {
                    diff = grouped.open(group)
                    model.open.insert(group)
                }
            case let (0 ... 3, .photo(cell)):
                diff = grouped.openStack(cell, selection: &selection)
                model.stacked.open(cell)
            case let (4 ... 5, .photo(cell)):
                diff = grouped.closeStack(cell, selection: &selection)
                model.stacked.close(cell)
            case (6, _):
                diff = grouped.openAll()
                model.open = Set(grouped.groups.indices)
            case (7, _):
                diff = grouped.closeAll(selection: &selection)
                model.open = []
            case let (8, .photo(cell)):
                selection.extend(to: cell, in: grouped)
            case let (_, .photo(cell)):
                selection.toggle(cell, in: grouped)
            default:
                selection.selectAll(in: grouped)
            }
            #expect(grouped.applying(diff, to: before) == Array(grouped), "\(key) step \(step)")
            check("step \(step)")
        }
    }

    @Test(arguments: 1 ... 20)
    func `a list grouped again as it changes is the list grouped afresh, with what was open open`(seed: Int) {
        var random = SeededRandom(seed: UInt64(100 + seed))
        var library = Self.randomLibrary(&random)
        let keys: [GroupKey] = [.moment, .momentCamera, .day, .folder, .camera]
        let key = keys[random.int(below: keys.count)]
        var grouped = library.grouping().grouped(library.list, by: key)
        for group in grouped.groups.indices where random.int(below: 3) == 0 {
            grouped.close(group)
        }
        for item in Array(grouped) where random.int(below: 3) == 0 {
            if case let .photo(cell) = item {
                grouped.openStack(cell)
            }
        }
        var changed: [Int64] = []
        for _ in 0 ..< random.int(in: 1 ... 6) {
            let photo = Int64(1 + random.int(below: library.photos.count))
            library.setFlag(random.int(below: 2) == 0 ? .pick : nil, of: photo)
            changed.append(photo)
        }
        let time = GroupLibrary.june14 + Double(random.int(in: 0 ... 200)) * 3600
        for _ in 0 ..< random.int(in: 0 ... 4) {
            library.add("NEW_\(library.photos.count).JPG", at: time + Double(random.int(below: 100)))
        }
        let list = PhotoList(source: .allPhotographs, ids: library.list.ids.filter { _ in random.int(below: 8) != 0 })
        var selection = StackSelection()
        let grouping = library.grouping()
        let (updated, diff) = grouped.updated(list: list, grouping: grouping, changed: changed, selection: &selection)

        let afresh = grouping.groups(of: list, by: key)
        #expect(updated.groups.map(\.name) == afresh.map(\.name) && updated.groups.photos == afresh.photos)
        let (same, state) = GroupedList.match(grouped.groups, afresh)
        let open = Set(afresh.indices.filter { state[$0] < 0 || grouped.isOpen(state[$0]) })
        #expect(Set(afresh.indices.filter(updated.isOpen)) == open, "\(key)")
        #expect(same.indices.allSatisfy { same[$0] < 0 || same[$0] == state[$0] })
        #expect(Array(updated) == Model(groups: afresh, stacked: updated.stacked, open: open).items, "\(key)")
        #expect(Self.applying(diff, from: grouped, to: updated), "\(key)")
    }

    /// Whether `diff` turns `old`'s items into `new`'s, compared as the diff compares them: photos by ID
    /// and headers by the group of `old` they are.
    private static func applying(_ diff: PhotoListDiff, from old: GroupedList, to new: GroupedList) -> Bool {
        let (same, _) = GroupedList.match(old.groups, new.groups)
        let numbers = GroupedList.headerNumbers(same, after: old.groups.count)
        let base = GroupedList.headerBase(old, new)
        var items = Array(GroupedList.itemIDs(of: old, base: base) { $0 }.ids)
        let after = GroupedList.itemIDs(of: new, base: base) { numbers[$0] }.ids
        diff.apply(to: &items) { after[$0] }
        return items == Array(after)
    }
}
