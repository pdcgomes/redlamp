import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Library panel's entries and the collections as library views (LIB-10, LIB-23), as folders are: the right
/// panels following the selection, Group By and the Tighter–Looser setting kept with each source's view, and the
/// filter bar narrowing the source with its counts, on a collection, a smart collection, Marked and Rejected.
@MainActor
@Suite(.serialized)
struct LibrarySourceViewsTests {
    /// The sandbox's photos: A, B and C in Shoot, D and E in Other. A and D are marked picks, rated 3 and 5; B and C
    /// are rejected; E is rated 1; A, C and E are in Selects, and Picked, a smart collection, finds the picks.
    @MainActor
    struct Library {
        let sandbox = SourcesSandbox()
        private(set) var model: EditorModel!
        let selects = CollectionPath("Selects")!
        let picked = CollectionPath("Picked")!

        var a: URL {
            sandbox.photo("Shoot/A.JPG")
        }

        var b: URL {
            sandbox.photo("Shoot/B.JPG")
        }

        var c: URL {
            sandbox.photo("Shoot/C.JPG")
        }

        var d: URL {
            sandbox.photo("Other/D.JPG")
        }

        var e: URL {
            sandbox.photo("Other/E.JPG")
        }

        /// Each source with its photos.
        var sources: [(source: LibrarySource, photos: Set<URL>)] {
            [
                (.collection(selects), [a, c, e]), (.collection(picked), [a, d]), (.marked, [a, d]),
                (.rejected, [b, c]),
            ]
        }

        mutating func open() async throws {
            try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/C.JPG", "Other/D.JPG", "Other/E.JPG"])
            model = try await sandbox.open()
            let (sandbox, model) = (sandbox, model!)
            model.showFolder(sandbox.root)
            try await sandbox.eventually { model.items.count == 5 }
            try #require(model.items.count == 5)
            try await sandbox.cull(.toggleMark, [a, d])
            try await sandbox.cull(.flagPick, [a, d])
            try await sandbox.cull(.flagReject, [b, c])
            try await sandbox.cull(.rating3, [a])
            try await sandbox.cull(.rating5, [d])
            try await sandbox.cull(.rating1, [e])
            let sources = model.librarySources
            try await sandbox.counts { $0.isCounted }
            #expect(sources.create(.collection, named: "Selects"))
            #expect(sources.saveSmart("flag:pick", named: "Picked", inside: nil))
            let (selects, picked) = (selects, picked)
            try await sandbox.counts { $0.collections[selects] != nil && $0.count(of: .collection(picked)) == 2 }
            model.select(a)
            model.click(c, toggling: true)
            model.click(e, toggling: true)
            #expect(sources.add(to: selects))
            try await sandbox.eventually { model.libraryPanels.undoCount > 2 }
            await model.libraryPanels.written()
            try await sandbox.counts { $0.count(of: .collection(selects)) == 3 && $0.count(of: .rejected) == 2 }
            try #require(sources.count(of: .collection(selects)) == 3 && sources.count(of: .marked) == 2)
        }

        /// Shows `source`, and waits until its photos are `photos`.
        func show(_ source: LibrarySource, _ photos: Set<URL>) async throws {
            let model = try #require(model)
            #expect(model.librarySources.show(source))
            try await sandbox.eventually {
                !model.librarySources.isListing && Set(model.items.map(\.url)) == photos
            }
            try #require(Set(model.items.map(\.url)) == photos, "\(source)'s photos shown")
            #expect(model.library.shownSource == source && model.library.isShownFromLibrary)
        }
    }

    // MARK: - The panels

    @Test func `the panels follow the selection in a collection, a smart collection, Marked and Rejected`(
    ) async throws {
        var library = Library()
        defer { library.sandbox.remove() }
        try await library.open()
        let model = try #require(library.model)
        let panels = model.libraryPanels
        panels.follow()
        let core = try #require(library.sandbox.service?.core)
        for (number, (source, photos)) in library.sources.enumerated() {
            try await library.show(source, photos)
            model.selectAllPhotos()
            let ids = await LibraryService.indexIDs(of: Array(photos), in: core.index)
            let expected = photos.compactMap { ids[$0] }.sorted()
            try await library.sandbox.eventually { panels.selection.ids == expected }
            #expect(panels.selection.isAvailable && panels.selection.ids == expected, "\(source): the selection")
            let keyword = try #require(KeywordPath("Views/Source \(number)"))
            #expect(panels.add([keyword]), "\(source)")
            await panels.written()
            try await library.sandbox.eventually { panels.selection.hasEverywhere(keyword) == true }
            #expect(panels.selection.hasEverywhere(keyword) == true, "\(source): the keyword on every photo")
            for photo in photos {
                let kept = SidecarStore().load(for: photo)?.metadata?.keywords ?? []
                #expect(kept.contains(keyword.text), "\(source): \(photo.lastPathComponent)'s sidecar")
            }
            let first = try #require(model.items.first?.url)
            model.select(first)
            try await library.sandbox.eventually { panels.selection.ids.count == 1 }
            #expect(panels.selection.count == 1, "\(source): one photo selected")
        }
    }

    // MARK: - Group By

    @Test func `Group By groups each source's photos, and each keeps its grouping and setting in its view`(
    ) async throws {
        var library = Library()
        defer { library.sandbox.remove() }
        try await library.open()
        let model = try #require(library.model)
        let groupings: [LibrarySource: (key: GroupKey, looseness: Int, groups: Int)] = [
            .collection(library.selects): (.folder, 0, 2), .collection(library.picked): (.moment, 2, 1),
            .marked: (.folder, 0, 2), .rejected: (.orientation, 0, 1),
        ]
        for (source, photos) in library.sources {
            try await library.show(source, photos)
            #expect(model.canGroupPhotos, "\(source)")
            let grouping = try #require(groupings[source])
            model.setGroupKey(grouping.key)
            model.setLooseness(grouping.looseness)
            try await library.sandbox.eventually {
                model.gridGroups.list?.groups.key == grouping.key
                    && model.gridGroups.list?.groups.setting == MomentSetting(looseness: grouping.looseness)
            }
            let list = try #require(model.gridGroups.list, "\(source) grouped")
            #expect(list.groups.key == grouping.key && list.groups.count == grouping.groups, "\(source)")
            #expect(list.groups.photos.count == photos.count, "\(source): every photo in a group")
            #expect(Set(list.groups.photos.compactMap(model.library.url(ofPhoto:))) == photos, "\(source)")
        }
        // The last one shown, Rejected, with one photo active.
        model.select(library.c)

        // Each again, with its own grouping and setting, and Rejected's photo active again.
        for (source, photos) in library.sources.reversed() {
            try await library.show(source, photos)
            let grouping = try #require(groupings[source])
            try await library.sandbox.eventually {
                model.gridGroups.list?.groups.key == grouping.key
                    && model.gridGroups.list?.groups.setting == MomentSetting(looseness: grouping.looseness)
            }
            #expect(model.libraryViews.groupKey == grouping.key, "\(source) kept its Group By")
            #expect(model.libraryViews.looseness == grouping.looseness, "\(source) kept its setting")
            #expect(model.gridGroups.list?.groups.count == grouping.groups, "\(source)")
            if source == .rejected {
                #expect(model.selection == library.c, "Rejected's active photo kept")
            }
        }
        model.showFolder(library.sandbox.root)
        try await library.sandbox.eventually { model.folder != nil && model.items.count == 5 }
        try await library.sandbox.eventually { model.libraryViews.groupKey == .ungrouped }
        #expect(model.libraryViews.groupKey == .ungrouped && model.gridGroups.list == nil, "the folder's own view")
    }

    // MARK: - The filter bar

    @Test func `the filter bar narrows each source with its counts, and each keeps its own filter`() async throws {
        var library = Library()
        defer { library.sandbox.remove() }
        try await library.open()
        let model = try #require(library.model)
        let filters = try #require(model.libraryFilters)
        filters.setBarShown(true)
        let found: [LibrarySource: Set<URL>] = [
            .collection(library.selects): [library.a], .collection(library.picked): [library.a, library.d],
            .marked: [library.a, library.d], .rejected: [],
        ]
        for (source, photos) in library.sources {
            try await library.show(source, photos)
            #expect(filters.source == source.key && filters.listed == nil, "the bar follows \(source)")
            filters.setFilter(LibraryFilter(text: "rating>=3", sections: [.text, .metadata], columns: [.folder]))
            let wanted = try LibraryListFilterSummary(
                query: LibraryQuery(parsing: "rating>=3"), sort: nil, reversed: false,
            )
            // The last source's list had the same filter: this one's is in once the bar counts it.
            try await library.sandbox.eventually { filters.listed != nil && filters.lastListed == wanted }
            let expected = try #require(found[source])
            try await library.sandbox.eventually { Set(model.items.map(\.url)) == expected }
            #expect(Set(model.items.map(\.url)) == expected, "\(source): the photos rated 3 or more")
            #expect(model.library.isFiltered, "\(source)")
            #expect(filters.listed?.shown == expected.count && filters.listed?.total == photos.count, "\(source)")
            filters.countColumns()
            try await library.sandbox.eventually { filters.columns[0]?.total == expected.count }
            #expect(filters.columns[0]?.total == expected.count, "\(source): the folder column counts its photos")
            if expected.isEmpty {
                try await library.sandbox.eventually { filters.removal != nil }
                #expect(filters.removal?.term == "rating>=3" && filters.removal?.count == photos.count, "\(source)")
            }
        }

        // Each source's filter kept: Marked's taken off, the others' kept.
        try await library.show(.marked, [library.a, library.d])
        filters.clear()
        try await library.sandbox.eventually { model.items.count == 2 && !model.library.isFiltered }
        #expect(filters.listed?.shown == 2 && filters.listed?.total == 2)
        try await library.sandbox.eventually { filters.lastListed?.query == nil }
        #expect(filters.lastListed?.query == nil, "the list without a filter handed over")
        try await library.show(.collection(library.selects), [library.a])
        #expect(filters.filter.text == "rating>=3", "Selects kept its filter")
        try await library.show(.marked, [library.a, library.d])
        #expect(filters.filter.text.isEmpty, "Marked kept none")

        // Sorted, a source's photos come in the sort's order, both ways.
        try await library.show(.collection(library.selects), [library.a])
        filters.clear()
        filters.setSort(LibrarySort(.rating, ascending: false))
        try await library.sandbox.eventually { model.items.map(\.url) == [library.a, library.e, library.c] }
        #expect(model.items.map(\.url) == [library.a, library.e, library.c], "the best rated first")
        filters.setSort(LibrarySort(.rating, ascending: true))
        try await library.sandbox.eventually { model.items.map(\.url) == [library.c, library.e, library.a] }
        #expect(model.items.map(\.url) == [library.c, library.e, library.a])
        filters.setSort(LibrarySort())
    }
}
