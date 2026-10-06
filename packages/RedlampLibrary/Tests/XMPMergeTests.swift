import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Which side each field takes when a photo's `.redlamp` and other apps' XMP disagree.
struct XMPMergeTests {
    static func record(other: XMPFields, redlamp: XMPFields) -> XMPMergeRecord {
        XMPMergeRecord(other: other, redlampFields: redlamp)
    }

    @Test func `the first time, the .redlamp's fields stay and other apps' fill in those it lacks`() {
        let outcome = XMPMerge.merge(
            redlamp: XMPFields(rating: 5), other: XMPFields(rating: 2, flag: .reject, label: .red), record: nil,
            otherIsLater: true,
        )
        #expect(outcome.fields == XMPFields(rating: 5, flag: .reject, label: .red))
        #expect(outcome.taken == [.flag, .label] && outcome.decided == [.rating] && outcome.kept.isEmpty)
    }

    @Test func `another app's later change is taken, field by field, and what only the .redlamp has stays`() {
        let recorded = Self.record(other: XMPFields(rating: 2), redlamp: XMPFields(rating: 2, flag: .pick))
        let outcome = XMPMerge.merge(
            redlamp: XMPFields(rating: 2, flag: .pick), other: XMPFields(rating: 4, label: .green), record: recorded,
            otherIsLater: true,
        )
        #expect(outcome.fields == XMPFields(rating: 4, flag: .pick, label: .green))
        #expect(outcome.taken == [.rating, .label] && outcome.decided == [.flag])
    }

    @Test func `a change once taken isn't taken again, and the .redlamp's own change after it stands`() {
        let first = XMPMerge.merge(
            redlamp: XMPFields(rating: 2), other: XMPFields(rating: 4),
            record: Self.record(other: XMPFields(rating: 2), redlamp: XMPFields(rating: 2)), otherIsLater: true,
        )
        #expect(first.taken == [.rating])
        // Recorded as taken; then the photo is rated 1 in Redlamp while the .xmp still says 4.
        let recorded = Self.record(other: XMPFields(rating: 4), redlamp: first.fields)
        let again = XMPMerge.merge(
            redlamp: XMPFields(rating: 1),
            other: XMPFields(rating: 4),
            record: recorded,
            otherIsLater: true,
        )
        #expect(again.fields.rating == 1 && again.taken.isEmpty && again.decided == [.rating])
    }

    @Test func `a field both sides changed goes to the later change`() {
        let recorded = Self.record(other: XMPFields(label: .red), redlamp: XMPFields(label: .red))
        let later = XMPMerge.merge(
            redlamp: XMPFields(label: .blue), other: XMPFields(label: .green), record: recorded, otherIsLater: true,
        )
        #expect(later.fields.label == .green && later.taken == [.label] && later.kept.isEmpty)
        let earlier = XMPMerge.merge(
            redlamp: XMPFields(label: .blue), other: XMPFields(label: .green), record: recorded, otherIsLater: false,
        )
        #expect(earlier.fields.label == .blue && earlier.kept == [.label] && earlier.decided == [.label])
        // Both arriving at the same value is no conflict.
        let same = XMPMerge.merge(
            redlamp: XMPFields(label: .green), other: XMPFields(label: .green), record: recorded, otherIsLater: false,
        )
        #expect(same.taken.isEmpty && same.kept.isEmpty)
    }

    @Test func `clearing is a change like any other, on either side`() {
        let recorded = Self.record(other: XMPFields(rating: 3, label: .red), redlamp: XMPFields(rating: 3, label: .red))
        let theirs = XMPMerge.merge(
            redlamp: XMPFields(rating: 3, label: .red), other: XMPFields(rating: 3), record: recorded,
            otherIsLater: true,
        )
        #expect(theirs.fields == XMPFields(rating: 3) && theirs.taken == [.label])
        let ours = XMPMerge.merge(
            redlamp: XMPFields(rating: 3), other: XMPFields(rating: 3, label: .red), record: recorded,
            otherIsLater: true,
        )
        #expect(ours.fields == XMPFields(rating: 3) && ours.taken.isEmpty && ours.decided == [.label, .rating].sorted())
    }

    @Test func `every field the sidecar holds merges, and only the fields asked about`() {
        let other = XMPFields(
            customLabel: "Urgent", keywords: ["Gulls"], title: "Tagus", caption: "Ferries", creator: "Ana Sousa",
            copyright: "© 2026 Ana Sousa", location: PhotoLocation(city: "Lisbon"),
        )
        let all = XMPMerge.merge(redlamp: XMPFields(), other: other, record: nil, otherIsLater: true)
        #expect(all.fields == other && all.taken == [
            .label,
            .keywords,
            .title,
            .caption,
            .creator,
            .copyright,
            .location,
        ])
        let some = XMPMerge.merge(
            redlamp: XMPFields(), other: other, record: nil, fields: [.keywords, .title], otherIsLater: true,
        )
        #expect(some.fields == XMPFields(keywords: ["Gulls"], title: "Tagus") && some.taken == [.keywords, .title])
        // Keywords compare as a set.
        let recorded = Self.record(other: XMPFields(keywords: ["A", "B"]), redlamp: XMPFields(keywords: ["A", "B"]))
        let reordered = XMPMerge.merge(
            redlamp: XMPFields(keywords: ["A", "B"]), other: XMPFields(keywords: ["B", "A"]), record: recorded,
            fields: [.keywords], otherIsLater: true,
        )
        #expect(reordered.taken.isEmpty)
    }
}
