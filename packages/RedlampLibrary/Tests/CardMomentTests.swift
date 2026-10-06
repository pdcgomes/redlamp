import Foundation
import Testing
@testable import RedlampLibrary

/// A card's photos in moments (LIB-41), as the import window shows them before anything is copied.
struct CardMomentTests {
    @Test func `a card's photos are grouped into the moments the index finds for them`() {
        var library = GroupLibrary()
        let start = GroupLibrary.june14 + 14 * 3600
        library.shoot(120, from: start) { Double(3 + $0 % 5) }
        library.shoot(60, from: start + 1500) { Double(2 + $0 % 4) }
        library.shoot(30, from: start + 86400) { 75 + Double($0 * 37 % 206) }
        library.shoot(25, from: start + 86400 + 9000) { 90 + Double($0 * 41 % 150) }
        let index = library.grouping().moments(of: library.list).map { Set($0.photos.map { library.photo($0).name }) }
        #expect(index.count == 4)

        var random = SeededRandom(seed: 27)
        let card = library.photos.shuffled(using: &random).map { photo in
            ImportPhoto(
                id: "/Volumes/CARD/DCIM/100NIKON/" + photo.name, source: "CARD", folder: "/Volumes/CARD/DCIM/100NIKON",
                files: [ImportFile(name: photo.name, role: .photo, size: 25_000_000, modified: Date())],
                metadata: CaptureMetadata(captured: photo.captured.map(Date.init(timeIntervalSince1970:))),
            )
        }
        let moments = ImportPhoto.moments(of: card)
        #expect(moments.map { Set($0.places.map { card[$0].primary.name }) } == index)
        #expect(moments.map(\.name) == library.grouping().moments(of: library.list).map(\.name))
        #expect(moments.allSatisfy { moment in
            zip(moment.places, moment.places.dropFirst()).allSatisfy { card[$0].captured <= card[$1].captured }
        })
        let looser = ImportPhoto.moments(of: card, setting: MomentSetting(looseness: MomentSetting.loosest))
        let indexLooser = library.grouping().moments(
            of: library.list, setting: MomentSetting(looseness: MomentSetting.loosest),
        )
        #expect(looser.count == indexLooser.count && looser.count <= moments.count)
    }

    @Test func `photos given at the same time go by name, then by place, those without a time last`() {
        let time = Date(timeIntervalSince1970: GroupLibrary.june14 + 9 * 3600)
        let names = ["IMG_10.JPG", "IMG_9.JPG", "SCAN_2.TIF", "IMG_9.JPG", "SCAN_1.TIF", "EARLY.JPG"]
        let captured: [Date?] = [time, time, nil, time, nil, time.addingTimeInterval(-2)]
        let moments = MomentFinder.moments(captured: captured, names: names)
        #expect(moments.map(\.places) == [[5, 1, 3, 0], [4, 2]])
        #expect(moments.map(\.name) == ["14 June 2025, 08:59 to 09:00", "No capture time"])
        #expect(moments[0].span == time.addingTimeInterval(-2) ... time && moments[1].span == nil)
        #expect(MomentFinder.moments(captured: [], names: []).isEmpty)
    }

    @Test func `a photo whose head isn't read yet is placed by its file's date, as this Mac's clock shows it`() {
        let modified = Date(timeIntervalSince1970: GroupLibrary.june14 + 12 * 3600)
        let photo = ImportPhoto(
            id: "/Volumes/CARD/DCIM/100CANON/IMG_0001.JPG", source: "CARD", folder: "/Volumes/CARD/DCIM/100CANON",
            files: [ImportFile(name: "IMG_0001.JPG", role: .photo, size: 1, modified: modified)],
        )
        let moments = ImportPhoto.moments(of: [photo])
        #expect(moments.count == 1 && moments[0].places == [0])
        #expect(moments[0].span?.lowerBound == ImportPhoto.wallClock(modified))
    }
}
