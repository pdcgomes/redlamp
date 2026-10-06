import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Group By (LIB-41) over a source's photos or a search's: each key's groups, their names, picks and
/// filters.
struct GroupByTests {
    private static let june14 = GroupLibrary.june14

    @Test func `each key's groups and filters find exactly their photos`() async throws {
        let library = try await GroupIndexLibrary.make()
        defer { library.sandbox.remove() }
        let grouping = try await library.engine.grouping(
            stacks: StackFinder.find(in: library.index, store: #require(library.engine.store)),
            orientations: PhotoOrientations.read(from: library.index),
        )
        let trips = PhotoSource.folder(
            URL(fileURLWithPath: IndexSandbox.rootPath + "/Trips", isDirectory: true), includingSubfolders: true,
        )
        for source in [PhotoSource.allPhotographs, trips] {
            let list = try await library.engine.list(source)
            #expect(list.count == (source == trips ? 7 : 9))
            for key in GroupKey.allCases {
                let groups = grouping.groups(of: list, by: key)
                #expect(groups.photos.sorted() == list.ids.sorted(), "\(key)")
                #expect(groups.reduce(0) { $0 + $1.count } == list.count, "\(key)")
                for group in groups {
                    #expect(group.photos.allSatisfy { groups.index(of: $0) == groups.firstIndex(of: group) })
                    let filtered = [.day, .folder, .camera, .lens].contains(key) && !group.name.hasPrefix("No ")
                    #expect((group.filter != nil) == filtered, "\(key) \(group.name)")
                    guard let filter = group.filter else { continue }
                    #expect(try LibraryQuery(parsing: filter.description) == filter, "\(filter)")
                    let found = try await library.engine.list(source, matching: filter)
                    #expect(Set(found.ids) == Set(group.photos), "\(key) \(group.name): \(filter)")
                }
            }
        }

        let all = try await library.engine.list(.allPhotographs)
        let names = { (key: GroupKey) in grouping.groups(of: all, by: key).map(\.name) }
        let root = IndexSandbox.rootPath
        #expect(names(.ungrouped) == ["All photos"])
        #expect(names(.day) == ["14 June 2025", "15 June 2025", "16 June 2025", "No capture time"])
        #expect(names(.folder) == ["Studio", "Trips", "Trips-old", "Trips/Day 1", "Trips/Day 2"]
            .map { root + "/" + $0 })
        #expect(names(.camera) == ["Canon EOS R5", "Canon EOS R50", "No camera"])
        #expect(names(.lens) == ["XF35mmF1.4 R", "XF35mmF1.4 R WR", "No lens"])
        #expect(names(.orientation) == ["Landscape", "Portrait", "Square", "No orientation"])
        #expect(names(.moment).count == 5 && names(.moment).last == "No capture time")
        #expect(names(.moment).first == "14 June 2025, 10:00")

        let cameras = grouping.groups(of: all, by: .camera)
        #expect(cameras[0].filter?.description == #"camera:"Canon EOS R5" -camera:"Canon EOS R50""#)
        #expect(cameras[1].filter?.description == #"camera:"Canon EOS R50""#)
        #expect(cameras.map(\.value) == [.camera("Canon EOS R5"), .camera("Canon EOS R50"), .camera(nil)])
        let folders = grouping.groups(of: all, by: .folder)
        #expect(folders[1].filter?
            .description == "folder:\(root)/Trips -folder:\(root)/Trips/ -folder:\(root)/Trips-old")
        let inTrips = try await grouping.groups(of: library.engine.list(trips), by: .folder)
        #expect(inTrips[0].filter?.description == "folder:\(root)/Trips -folder:\(root)/Trips/")
        let days = grouping.groups(of: all, by: .day)
        #expect(days.map(\.picks) == [1, 1, 0, 0] && days[0].filter?.description == "date:2025-06-14")
        #expect(days.map(\.value) == [
            .day(.day(2025, 6, 14)), .day(.day(2025, 6, 15)), .day(.day(2025, 6, 16)), .day(nil),
        ])
        #expect(grouping.groups(of: all, by: .orientation).map(\.count) == [5, 2, 1, 1])
    }

    @Test func `two cameras whose clocks disagree come apart by moment, then camera`() {
        var library = GroupLibrary()
        let (ceremony, reception) = (Self.june14 + 14 * 3600, Self.june14 + 15 * 3600)
        let behind = 40.0 * 60
        let a1 = library.shoot(200, from: ceremony, camera: 1) { _ in 6 }
        let b1 = library.shoot(170, from: ceremony - behind, camera: 2) { _ in 7 }
        let a2 = library.shoot(300, from: reception, camera: 1) { _ in 6 }
        let b2 = library.shoot(250, from: reception - behind, camera: 2) { _ in 7 }
        let grouping = library.grouping()
        let moments = grouping.moments(of: library.list)
        #expect(moments.map { Set($0.photos) } == [Set(b1), Set(a1 + b2), Set(a2)])
        let split = grouping.groups(of: library.list, by: .momentCamera)
        #expect(split.photoSets == [b1, b2, a1, a2])
        #expect(split.map(\.value) == [
            .momentCamera(0, camera: "Fujifilm X-T5"), .momentCamera(1, camera: "Fujifilm X-T5"),
            .momentCamera(1, camera: "Nikon Z 6"), .momentCamera(2, camera: "Nikon Z 6"),
        ])
        #expect(split[2].name == "14 June 2025, 14:00 to 14:19 — Nikon Z 6")
        #expect(split.allSatisfy { $0.filter == nil })

        var agreeing = GroupLibrary()
        let a = agreeing.shoot(100, from: ceremony, camera: 1) { _ in 4 }
        let b = agreeing.shoot(80, from: ceremony + 2, camera: 2) { _ in 5 }
        let undated = agreeing.add("SCAN.TIF", at: nil, camera: nil)
        let together = agreeing.grouping().groups(of: agreeing.list, by: .momentCamera)
        #expect(together.photoSets == [b, a, [undated]])
        #expect(together.map(\.value) == [
            .momentCamera(0, camera: "Fujifilm X-T5"), .momentCamera(0, camera: "Nikon Z 6"),
            .momentCamera(nil, camera: nil),
        ])
        #expect(together.last?.name == "No capture time — No camera")
    }

    @Test func `a stack crossing a key's values goes whole to its top's group, which then has no filter`() {
        var library = GroupLibrary()
        library.folders[2] = "/Volumes/Test/Photos/Studio"
        let day = library.shoot(10, from: Self.june14 + 9 * 3600) { _ in 5 }
        let studio = library.shoot(4, from: Self.june14 + 86400 + 9 * 3600) { _ in 5 }
        let moved = library.add("STUDIO_TOP.NEF", at: Self.june14 + 86400 + 10 * 3600, folder: 2, camera: 2)
        library.choices.stack([day[2], moved], top: moved, in: library.grouping().stacks)
        let grouping = library.grouping()
        let folders = grouping.groups(of: library.list, by: .folder)
        #expect(folders.photoSets == [day.filter { $0 != day[2] } + studio, [day[2], moved]])
        #expect(folders.allSatisfy { $0.filter == nil })
        let cameras = grouping.groups(of: library.list, by: .camera)
        #expect(cameras.map(\.value) == [.camera("Fujifilm X-T5"), .camera("Nikon Z 6")])
        #expect(cameras[0].photos.elementsEqual([day[2], moved]) && cameras.allSatisfy { $0.filter == nil })
        let days = grouping.groups(of: library.list, by: .day)
        #expect(days.photoSets == [day.filter { $0 != day[2] }, [day[2]] + studio + [moved]])
        #expect(days.map { $0.filter == nil } == [true, true])
        let lenses = grouping.groups(of: library.list, by: .lens)
        #expect(lenses.count == 1 && lenses[0].filter?.description == #"lens:"NIKKOR Z 24-70mm f/4 S""#)
    }

    @Test func `groups count their picks, and the list's order holds within each`() {
        var library = GroupLibrary()
        var ids: [Int64] = []
        for shot in 0 ..< 12 {
            ids.append(library.add(
                "PICK_\(shot).NEF", at: Self.june14 + Double(shot) * 7200, camera: Int64(1 + shot % 2),
                flag: shot % 3 == 0 ? .pick : shot % 3 == 1 ? .reject : nil,
            ))
        }
        let grouping = library.grouping()
        let byName = PhotoList(
            source: .allPhotographs, sort: QuerySort(.name, ascending: false),
            ids: library.store.ids(sortedBy: QuerySort(.name, ascending: false)),
        )
        let cameras = grouping.groups(of: byName, by: .camera)
        #expect(cameras.map(\.picks) == [2, 2])
        #expect(cameras[1].photos.elementsEqual(byName.ids.filter { library.photo($0).camera == 1 }))
        let moments = grouping.moments(of: byName)
        #expect(moments.count == 12 && moments.map(\.picks) == ids.map { library.photo($0).flag == .pick ? 1 : 0 })
        let all = grouping.groups(of: byName, by: .ungrouped)
        #expect(all.count == 1 && all[0].picks == 4 && all[0].photos.elementsEqual(byName.ids))
        #expect(all[0].value == .all && all[0].filter == nil)
        #expect(grouping.groups(of: PhotoList(source: .allPhotographs, ids: []), by: .moment).isEmpty)
    }

    @Test func `a folder's filter leaves out its subfolders in one term, and a name differing only in case has none`() {
        let paths = ["/P/Trips", "/P/Trips/Day 1", "/P/Trips/Day 1/Raw", "/P/Trips/Day 2", "/P/Trips 2", "/Q/P/Trips"]
        let folders = GroupFilters(field: .folder, values: paths)
        #expect(folders.filter(for: "/P/Trips")?.description
            == #"folder:/P/Trips -folder:/P/Trips/ -folder:"/P/Trips 2" -folder:/Q/P/Trips"#)
        #expect(folders.filter(for: "/P/Trips/Day 1")?.description
            == #"folder:"/P/Trips/Day 1" -folder:"/P/Trips/Day 1/""#)
        #expect(folders.filter(for: "/P/Trips/Day 2")?.description == #"folder:"/P/Trips/Day 2""#)
        let cameras = GroupFilters(field: .camera, values: ["Canon", "CANON EOS", "canon"])
        #expect(cameras.filter(for: "Canon") == nil && cameras.filter(for: "CANON EOS") != nil)
        let accents = GroupFilters(field: .folder, values: ["/P/Été", "/P/ÉTÉ 2", "/P/Ete"])
        #expect(accents.filter(for: "/P/Été")?.description == #"folder:/P/Été -folder:"/P/ÉTÉ 2""#)
    }

    @Test func `orientations come from the index's upright sizes`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["Shoot"])["Shoot"])
        let ids = try await sandbox.upsert([
            PhotoRecord(folder: folder, name: "WIDE.JPG", width: 6000, height: 4000),
            PhotoRecord(folder: folder, name: "TALL.JPG", width: 4000, height: 6000),
            PhotoRecord(folder: folder, name: "SQUARE.JPG", width: 3000, height: 3000),
            PhotoRecord(folder: folder, name: "UNKNOWN.JPG"),
        ])
        let orientations = try await PhotoOrientations.read(from: sandbox.index)
        #expect(ids.map { orientations[$0] } == [.landscape, .portrait, .square, nil])
        #expect(orientations[-1] == nil && orientations[1_000_000] == nil)
        #expect(PhotoOrientation(width: 0, height: 10) == nil && PhotoOrientation(width: 3, height: 2) == .landscape)
    }
}

/// A library in an index: Trips with two day folders below it and Trips-old beside it, whose path
/// holds Trips's, and Studio; two cameras and two lenses whose names hold one another; photos on three
/// days and one without a capture time, a raw beside its JPEG, two picks, and photos of every
/// orientation.
struct GroupIndexLibrary {
    let sandbox: IndexSandbox
    let engine: QueryEngine

    var index: LibraryIndex {
        sandbox.index
    }

    static func make() async throws -> GroupIndexLibrary {
        let sandbox = try await IndexSandbox.make()
        let folders = try await sandbox.addFolders(["Trips", "Trips/Day 1", "Trips/Day 2", "Trips-old", "Studio"])
        @Sendable func time(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
            Date(timeIntervalSince1970: GroupLibrary.june14 + Double(day * 86400 + hour * 3600 + minute * 60 + second))
        }
        try await sandbox.index.write { writer in
            let (r5, r50) = try (writer.cameraID(for: "Canon EOS R5"), writer.cameraID(for: "Canon EOS R50"))
            let (lens, sealed) = try (writer.lensID(for: "XF35mmF1.4 R"), writer.lensID(for: "XF35mmF1.4 R WR"))
            let trips = folders["Trips"] ?? 0
            let (day1, day2) = (folders["Trips/Day 1"] ?? 0, folders["Trips/Day 2"] ?? 0)
            _ = try writer.upsertPhotos([
                PhotoRecord(
                    folder: trips, name: "T1.JPG", captured: time(0, 10), camera: r5, lens: lens, width: 6000,
                    height: 4000, flag: .pick,
                ),
                PhotoRecord(
                    folder: trips, name: "T2.JPG", captured: time(0, 10, 0, 5), camera: r50, lens: sealed,
                    width: 4000, height: 6000,
                ),
                PhotoRecord(
                    folder: day1, name: "D1A.CR3", captured: time(1, 9), camera: r5, lens: lens, width: 6000,
                    height: 4000,
                ),
                PhotoRecord(
                    folder: day1, name: "D1A.JPG", captured: time(1, 9), camera: r5, lens: lens, width: 6000,
                    height: 4000,
                ),
                PhotoRecord(
                    folder: day1, name: "D1B.JPG", captured: time(1, 9, 0, 4), camera: r50, lens: lens, width: 3000,
                    height: 3000, flag: .pick,
                ),
                PhotoRecord(
                    folder: day2, name: "D2A.JPG", captured: time(2, 18), camera: r5, lens: sealed, width: 4000,
                    height: 6000,
                ),
                PhotoRecord(folder: day2, name: "D2B.JPG"),
                PhotoRecord(
                    folder: folders["Trips-old"] ?? 0, name: "OLD.JPG", captured: time(0, 23, 59, 59), camera: r50,
                    width: 6000, height: 4000,
                ),
                PhotoRecord(
                    folder: folders["Studio"] ?? 0, name: "S1.JPG", captured: time(2, 18, 0, 3), lens: lens,
                    width: 6000, height: 4000,
                ),
            ])
        }
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await engine.load()
        return GroupIndexLibrary(sandbox: sandbox, engine: engine)
    }
}
