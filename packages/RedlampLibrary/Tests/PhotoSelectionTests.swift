import Foundation
import Testing
@testable import RedlampLibrary

struct PhotoSelectionTests {
    /// Photos in an order that isn't their IDs'.
    private static let list = PhotoList(source: .allPhotographs, sort: QuerySort(), ids: [50, 10, 40, 20, 30, 60])

    @Test func `a click selects one photo, ⌘-click toggles one, and ⇧-click extends from the active photo in list order`() {
        let list = Self.list
        var selection = PhotoSelection()
        #expect(selection.isEmpty && selection.active == nil && selection.ids(in: list).isEmpty)

        selection.select(40, in: list)
        #expect(selection.count == 1 && selection.active == 40 && selection.ids(in: list) == [40])
        selection.extend(to: 30, in: list)
        #expect(selection.ids(in: list) == [40, 20, 30] && selection.count == 3 && selection.active == 40)
        selection.extend(to: 50, in: list)
        #expect(selection.ids(in: list) == [50, 10, 40, 20, 30] && selection.count == 5 && selection.active == 40)

        selection.toggle(20, in: list)
        #expect(selection.ids(in: list) == [50, 10, 40, 30] && selection.count == 4 && selection.active == 40)
        selection.toggle(60, in: list)
        #expect(selection.ids(in: list) == [50, 10, 40, 30, 60] && selection.active == 60)
        // Taking out the active photo makes the nearest selected one active: after it, else before.
        selection.toggle(60, in: list)
        #expect(selection.count == 4 && selection.active == 30 && !selection.contains(60))
        selection.toggle(10, in: list)
        selection.toggle(40, in: list)
        #expect(selection.ids(in: list) == [50, 30] && selection.active == 30)

        // Photos the list doesn't hold aren't selected.
        selection.select(99, in: list)
        selection.toggle(99, in: list)
        selection.extend(to: 99, in: list)
        #expect(selection.ids(in: list) == [50, 30] && !selection.contains(99))

        // With no active photo, ⇧-click selects the photo alone.
        selection.selectNone()
        selection.extend(to: 20, in: list)
        #expect(selection.ids(in: list) == [20] && selection.active == 20)
    }

    @Test func `select all, invert and select none follow the list, keeping an active photo while there's one`() {
        let list = Self.list
        var selection = PhotoSelection()
        selection.selectAll(in: list)
        #expect(selection.count == 6 && selection.ids(in: list) == list.ids && selection.active == 50)
        selection.select(10, in: list)
        selection.selectAll(in: list)
        #expect(selection.count == 6 && selection.active == 10)

        selection.select(10, in: list)
        selection.extend(to: 20, in: list)
        selection.invert(in: list)
        #expect(selection.ids(in: list) == [50, 30, 60] && selection.count == 3 && selection.active == 50)
        selection.invert(in: list)
        #expect(selection.ids(in: list) == [10, 40, 20] && selection.active == 10)

        selection.selectNone()
        #expect(selection.isEmpty && selection.active == nil && selection.ids(in: list).isEmpty)
        selection.invert(in: list)
        #expect(selection.ids(in: list) == list.ids && selection.active == 50)
        selection.invert(in: list)
        #expect(selection.isEmpty && selection.active == nil)
    }

    @Test func `photos that leave the list leave the selection, and the active one with them`() {
        let before = Self.list
        var selection = PhotoSelection()
        selection.select(40, in: before)
        selection.extend(to: 60, in: before)
        #expect(selection.ids(in: before) == [40, 20, 30, 60])

        // 40 and 30 left, 70 and 5 arrived, and 60 moved to the front.
        let after = PhotoList(source: .allPhotographs, sort: QuerySort(), ids: [60, 70, 50, 10, 20, 5])
        selection.keep(in: after)
        #expect(selection.ids(in: after) == [60, 20] && selection.count == 2)
        #expect(selection.active == 60 && !selection.contains(40) && !selection.contains(70))

        selection.keep(in: PhotoList(source: .allPhotographs, sort: QuerySort(), ids: [70, 5]))
        #expect(selection.isEmpty && selection.active == nil)
    }

    @Test func `a range from an anchor replaces the selection, and a rubber band's photos are selected alone or added`() {
        let list = Self.list
        var selection = PhotoSelection()
        selection.select(from: 10, through: 20, in: list)
        #expect(selection.ids(in: list) == [10, 40, 20] && selection.active == 20)
        selection.select(from: 10, through: 50, in: list)
        #expect(selection.ids(in: list) == [50, 10] && selection.active == 50, "going back shrinks the range")
        selection.select(from: 99, through: 30, in: list)
        #expect(selection.ids(in: list) == [30] && selection.active == 30, "an anchor not in the list selects one")

        selection.select([60, 40, 99], active: 60, in: list)
        #expect(selection.ids(in: list) == [40, 60] && selection.count == 2 && selection.active == 60)
        selection.select([20, 50], active: 60, in: list)
        #expect(selection.ids(in: list) == [50, 20] && selection.active == 50, "the first in list order is active")
        selection.select([], active: nil, in: list)
        #expect(selection.isEmpty && selection.active == nil)

        var band = PhotoSelection()
        band.select([30, 60], active: nil, in: list)
        selection.select(10, in: list)
        selection.formUnion(band, in: list)
        #expect(selection.ids(in: list) == [10, 30, 60] && selection.count == 3 && selection.active == 10)
        var empty = PhotoSelection()
        empty.formUnion(band, in: list)
        #expect(empty.ids(in: list) == [30, 60] && empty.active == 30)
        let shorter = PhotoList(source: .allPhotographs, ids: [10, 60])
        empty.formUnion(selection, in: shorter)
        #expect(empty.ids(in: shorter) == [10, 60] && empty.count == 2, "only the list's photos stay")

        empty.activate(60)
        #expect(empty.active == 60 && empty.count == 2)
        empty.activate(30)
        #expect(empty.active == 60, "a photo that isn't selected doesn't become active")
    }

    @Test func `selections of the same photos are equal however they were made`() {
        let list = Self.list
        var clicked = PhotoSelection()
        clicked.select(20, in: list)
        clicked.toggle(10, in: list)
        clicked.toggle(20, in: list)
        var inverted = PhotoSelection()
        inverted.select(10, in: list)
        inverted.invert(in: list)
        inverted.invert(in: list)
        #expect(clicked == inverted)
        inverted.toggle(60, in: list)
        #expect(clicked != inverted)
    }
}
