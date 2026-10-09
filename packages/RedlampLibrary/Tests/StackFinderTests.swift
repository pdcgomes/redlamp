import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct StackFinderTests {
    // MARK: - Pairs

    @Test func `pairs and triples are a folder's raws, JPEGs and HEICs whose names differ only in their extension`() {
        var library = StackLibrary()
        let (raw, jpeg) = library.addPair("IMG_0001", at: 100)
        let triple = [
            library.add("IMG_0002.ARW", at: 200), library.add("img_0002.jpg", at: 200),
            library.add("IMG_0002.HEIC", at: 200),
        ]
        let heic = library.add("IMG_0003.HEIC", at: 300)
        let jpegBeforeHEIC = library.add("IMG_0003.JPG", at: 300)
        let composed = library.add("Caf\u{E9}.CR3", at: 400)
        let decomposed = library.add("Cafe\u{301}.JPG", at: 400)
        let alone = library.add("IMG_0004.CR3", at: 500)
        // Apart in time, as other files of one shot are a burst of them.
        let tiff = [library.add("IMG_0005.CR3", at: 600), library.add("IMG_0005.TIF", at: 650)]
        let longer = [library.add("IMG_0006.CR3", at: 700), library.add("IMG_0006.CR3.JPG", at: 750)]
        let elsewhere = library.add("IMG_0001.JPG", folder: 2, at: 100)
        library.add("Notes", at: nil)

        let stacks = library.find()
        #expect(Set(stacks.photos(.pair)) == [
            [raw, jpeg], triple, [jpegBeforeHEIC, heic], [composed, decomposed],
        ])
        #expect(stacks.count(of: .pair) == 4 && stacks.count(of: .burst) == 0)
        #expect(stacks.pair(containing: jpeg)?.top == raw && stacks.pair(containing: heic)?.top == jpegBeforeHEIC)
        for id in [alone, elsewhere] + tiff + longer {
            #expect(stacks.pair(containing: id) == nil, "\(library.photo(id).name)")
        }
    }

    // MARK: - Bursts

    @Test func `bursts are a camera's frames in one folder with one exposure length, each within a second of the last one's end`(
    ) throws {
        var library = StackLibrary()
        // Eighths of a second, which the column store's milliseconds hold exactly.
        let first = (0 ..< 3).map { library.add("A\($0).CR3", at: 1000 + Double($0) / 8) }
        // 1.121 s after the last one ended: another burst.
        let second = (0 ..< 2).map { library.add("B\($0).CR3", at: 1001.375 + Double($0) / 8) }
        // Exactly a second after half-second exposures end, then more than a second.
        let edge = [library.add("C0.CR3", at: 2000, shutter: 0.5), library.add("C1.CR3", at: 2001.5, shutter: 0.5)]
        let late = library.add("C2.CR3", at: 2003.125, shutter: 0.5)
        let otherCamera = (0 ..< 3).map { library.add("D\($0).NEF", at: 1000 + Double($0) / 8, camera: 2) }
        let longer = library.add("E0.CR3", at: 3000, shutter: 1.0 / 250)
        let shorter = (1 ..< 3).map { library.add("E\($0).CR3", at: 3000 + Double($0) / 8, shutter: 1.0 / 500) }
        // 30 s exposures shot back to back: 31 s between their capture times.
        let night = (0 ..< 3).map { library.add("F\($0).CR3", at: 4000 + Double($0) * 31, shutter: 30) }
        let elsewhere = library.add("G0.CR3", folder: 2, at: 1000 + 1.0 / 16)
        let unknown = (0 ..< 2).map { library.add("H\($0).JPG", at: 5000 + Double($0) / 8, camera: nil) }
        let undated = library.add("H2.CR3", at: nil)
        let pairs = (0 ..< 2).map { library.addPair("J\($0)", at: 6000 + Double($0) / 8) }

        let stacks = library.find()
        #expect(Set(stacks.photos(.burst)) == [
            first, second, edge, otherCamera, shorter, night, pairs.map(\.raw),
        ])
        for id in [late, longer, elsewhere, undated] + unknown {
            #expect(stacks.stack(containing: id) == nil, "\(library.photo(id).name)")
        }
        let burst = try #require(stacks.stack(containing: pairs[1].jpeg))
        #expect(burst.kind == .burst && burst.top == pairs[0].raw)
        #expect(stacks.allPhotos(of: burst) == [pairs[0].raw, pairs[0].jpeg, pairs[1].raw, pairs[1].jpeg])
    }

    @Test func `an export or an edit taken at its frame's moment and named for it is in no burst`() {
        var library = StackLibrary()
        let original = library.add("_DSC0009.ARW", at: 1000.25)
        let exports = [
            library.add("_DSC0009-redlamp.jpg", at: 1000.25),
            library.add("_DSC0009-redlamp-redlamp.jpg", at: 1000.25),
            // An export that kept the second but not its fraction.
            library.add("_dsc0009 copy.JPG", at: 1000),
        ]
        let edited = [library.add("IMG_1.CR3", at: 2000), library.add("IMG_1-Edit.tif", at: 2000)]
        // A burst, and its second frame exported beside it.
        let burst = (1 ... 3).map { library.add("DSC_000\($0).NEF", at: 3000 + Double($0) / 8) }
        let export = library.add("DSC_0002_edited.JPG", at: 3000.25)

        let stacks = library.find()
        #expect(stacks.photos(.burst) == [burst])
        for id in [original, export] + exports + edited {
            #expect(stacks.stack(containing: id) == nil, "\(library.photo(id).name)")
        }
    }

    @Test func `another format of a frame is in no burst, beside a pair or alone`() {
        var library = StackLibrary()
        let (raw, jpeg) = library.addPair("IMG_7", at: 1000)
        let tiff = library.add("IMG_7.TIF", at: 1000)
        let formats = [
            library.add("Bitmap.jpg", at: 2000.5), library.add("Bitmap.png", at: 2000.5),
            library.add("Bitmap.tif", at: 2000.5),
        ]

        let stacks = library.find()
        #expect(stacks.photos(.pair) == [[raw, jpeg]] && stacks.count(of: .burst) == 0)
        for id in [tiff] + formats {
            #expect(stacks.stack(containing: id) == nil, "\(library.photo(id).name)")
        }
    }

    @Test func `frames with their own names stay a burst, with sub-seconds or without`() {
        var library = StackLibrary()
        let fractions = (1 ... 3).map { library.add("DSC_000\($0).NEF", at: 1000 + Double($0) / 10) }
        // Named like another, but taken a fraction of a second later.
        let alike = [library.add("P_1.NEF", at: 2000.125), library.add("P_1_1.NEF", at: 2000.375)]
        // A camera that writes whole seconds: several frames in each.
        let whole = [
            library.add("DSC_0101.JPG", at: 3000), library.add("DSC_0102.JPG", at: 3000),
            library.add("DSC_0103.JPG", at: 3000), library.add("DSC_0104.JPG", at: 3001),
        ]

        let stacks = library.find()
        #expect(Set(stacks.photos(.burst)) == [fractions, alike, whole])
    }

    @Test func `a copy's name is its frame's stem and a separator, or the same stem`() {
        #expect(StackFinder.copy("_dsc0009", "_dsc0009-redlamp") == .right)
        #expect(StackFinder.copy("img_1-edit", "img_1") == .left)
        for separated in ["img_1_2", "img_1 copy", "img_1.cr3"] {
            #expect(StackFinder.copy("img_1", separated) == .right, "\(separated)")
        }
        #expect(StackFinder.copy("bitmap", "bitmap") == .alike)
        for other in ["img_10", "img_2", "img1", "dsc_0001"] {
            #expect(StackFinder.copy("img_1", other) == nil, "\(other)")
        }
        #expect(StackFinder.sameMoment(1_000_250, 1_000_000) && StackFinder.sameMoment(-1500, -2000))
        #expect(!StackFinder.sameMoment(1_000_250, 1_000_375) && !StackFinder.sameMoment(1_000_000, 1_001_000))
    }

    @Test func `a burst shows its first frame on top unless the user chose another`() {
        var library = StackLibrary()
        let frames = (0 ..< 3).map { library.addPair("IMG_000\($0)", at: 1000 + Double($0) / 8) }
        let raws = frames.map(\.raw)
        let stacks = library.find()
        #expect(stacks.photos(.burst) == [raws])

        var choices = StackChoices()
        #expect(Set(choices.setTop(frames[1].jpeg, in: stacks)) == [frames[1].raw, frames[1].jpeg])
        #expect(library.find(choices).photos(.burst) == [[raws[1], raws[0], raws[2]]])
        let changed = choices.setTop(raws[2], in: library.find(choices))
        #expect(Set(changed) == Set([frames[1], frames[2]].flatMap { [$0.raw, $0.jpeg] }))
        #expect(library.find(choices).photos(.burst) == [[raws[2], raws[0], raws[1]]])
        #expect(choices.setTop(frames[0].raw, in: library.find(choices)).count == 4)
        #expect(choices.choices.values.count { $0.top } == 2 && choices.choices.values.allSatisfy { $0.id == nil })
    }

    // MARK: - Focus suggestions

    @Test(arguments: 1 ... 30)
    func `focus suggestions are StackDetector's runs, found from the index's settings`(seed: Int) throws {
        var random = SeededRandom(seed: UInt64(seed))
        var library = StackLibrary()
        var captures: [(URL, StackDetector.Capture)] = []
        var byURL: [URL: Int64] = [:]
        var time = 1_600_000_000.0
        func usually<T>(_ common: T, _ others: [T]) -> T {
            random.int(below: 8) == 0 ? others[random.int(below: others.count)] : common
        }
        for number in 0 ..< random.int(in: 0 ... 90) {
            let roll = random.int(below: 100)
            // Eighths of a second: short steps, long ones, some backwards and some none.
            time += roll < 50 ? Double(random.int(in: 1 ... 24)) / 8
                : roll < 75 ? Double(random.int(in: 1 ... 320)) / 8
                : roll < 85 ? -Double(random.int(in: 1 ... 16)) / 8 : 0
            let dated = random.int(below: 20) != 0
            let camera = usually(Int64(1), [2])
            let lens = usually(Int64(1), [2])
            let focal = usually(35.0, [24, 50.5])
            let aperture = usually(2.8, [1.4, 5.6])
            let iso = usually(100.0, [400])
            let shutter = usually(1.0 / 250, [1.0 / 3, 2])
            let name = String(format: "IMG_%04d.CR3", number)
            let id = library.add(
                name, at: dated ? time : nil, camera: camera, lens: lens, iso: iso, aperture: aperture,
                shutter: shutter, focal: focal,
            )
            let url = URL(fileURLWithPath: "/Shoot/" + name)
            byURL[url] = id
            captures.append((url, StackDetector.Capture(
                model: "Camera \(camera)", lens: "Lens \(lens)", focalLength: focal, aperture: aperture, iso: iso,
                exposureTime: shutter, date: dated ? Date(timeIntervalSince1970: time) : nil,
            )))
        }
        let expected = try StackDetector.runs(captures).map { run in try run.map { try #require(byURL[$0]) } }
        #expect(library.find().photos(.focus) == expected)
    }

    @Test func `a raw and its JPEG are one frame of a focus suggestion, which a stack document doesn't break`() {
        var library = StackLibrary()
        let frames = (0 ..< 5).map { library.addPair("IMG_010\($0)", at: 1000 + Double($0) * 5) }
        library.add("IMG_0100-IMG_0104.redlampstack", at: nil)
        let stacks = library.find()
        #expect(stacks.photos(.focus) == [frames.map(\.raw)])
        #expect(stacks.suggestion(containing: frames[3].raw)?.top == frames[0].raw)
        #expect(stacks.photos(.burst).isEmpty)
    }

    // MARK: - Manual stacks

    @Test func `manual stacks gather photos from any folders and keep them out of bursts`() {
        var library = StackLibrary()
        let burst = (0 ..< 4).map { library.add("IMG_000\($0).CR3", at: 1000 + Double($0) / 8) }
        let (raw, jpeg) = library.addPair("DSC_0100", folder: 2, at: 2000)
        let other = library.add("P1000001.RW2", folder: 3, at: 500)
        var choices = StackChoices()
        var stacks = library.find(choices)
        #expect(stacks.photos(.burst) == [burst] && stacks.photos(.manual).isEmpty)

        let changed = choices.stack([burst[1], jpeg, other], in: stacks)
        #expect(Set(changed) == [burst[1], raw, jpeg, other])
        stacks = library.find(choices)
        #expect(stacks.photos(.manual) == [[other, burst[1], raw]])
        #expect(stacks.photos(.burst) == [[burst[0], burst[2], burst[3]]])
        let id = choices[raw]?.id
        #expect(id != nil && choices[jpeg]?.id == id && stacks.stack(containing: jpeg)?.id == id)
        #expect(stacks.stack(containing: jpeg)?.kind == .manual)

        choices.setTop(jpeg, in: stacks)
        stacks = library.find(choices)
        #expect(stacks.photos(.manual) == [[raw, other, burst[1]]])
        #expect(choices[raw] == .init(id: id, top: true) && choices[other] == .init(id: id))

        choices.remove([other], in: stacks)
        stacks = library.find(choices)
        #expect(stacks.photos(.manual) == [[raw, burst[1]]])
        choices.remove([raw], in: stacks)
        stacks = library.find(choices)
        #expect(stacks.photos(.manual).isEmpty)
        #expect(stacks.photos(.burst) == [[burst[0], burst[2], burst[3]]], "a photo left alone stays out of bursts")

        #expect(choices.reset([burst[1]], in: stacks) == [burst[1]])
        stacks = library.find(choices)
        #expect(stacks.photos(.burst) == [burst])
        choices.remove(burst[1 ... 2], in: stacks)
        #expect(library.find(choices).photos(.burst) == [[burst[0], burst[3]]])
    }

    @Test func `a manual stack is made with the top photo chosen, and takes its photos from the stacks they were in`() {
        var library = StackLibrary()
        let first = (0 ..< 3).map { library.add("A\($0).CR3", at: 1000 + Double($0) / 8) }
        let second = (0 ..< 3).map { library.add("B\($0).CR3", folder: 2, at: 5000 + Double($0) / 8) }
        var choices = StackChoices()
        choices.stack(second, top: second[2], in: library.find(choices))
        #expect(library.find(choices).photos(.manual) == [[second[2], second[0], second[1]]])
        choices.stack([first[0], second[0]], in: library.find(choices))
        let stacks = library.find(choices)
        #expect(Set(stacks.photos(.manual)) == [[second[2], second[1]], [first[0], second[0]]])
        #expect(stacks.photos(.burst) == [[first[1], first[2]]])
    }

    // MARK: - The index

    @Test func `choices are kept in the index's columns as the sidecar's stack field holds them`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["Shoot"])["Shoot"])
        let ids = try await sandbox.upsert((7 ... 10).map { PhotoRecord(folder: folder, name: "IMG_\($0).JPG") })
        let id = UUID()
        let choices = StackChoices([
            ids[0]: .init(id: id, top: true, position: 0), ids[1]: .init(id: id, position: 1), ids[2]: .init(top: true),
        ])
        try await sandbox.index.write { try choices.save(ids, in: $0) }
        #expect(try await sandbox.index.read { try StackChoices($0) } == choices)
        let row = try await sandbox.index.read { try $0.photo(id: ids[1]) }
        #expect(row?.stack == PhotoStack(id: id, position: 1))
        try await sandbox.index.write { try StackChoices().save([ids[0], ids[2]], in: $0) }
        #expect(
            try await sandbox.index.read { try StackChoices($0) } == StackChoices([ids[1]: .init(id: id, position: 1)]),
        )
        let decoded = try JSONDecoder().decode(
            StackChoices.Choice.self, from: Data("{\"id\":\"\(id.uuidString.lowercased())\"}".utf8),
        )
        #expect(decoded == .init(id: id))
    }

    @Test func `an index whose settings kept the choices moves them to its columns`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-stacks-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Index.sqlite")
        let id = UUID()
        let older = try await LibraryIndex.open(at: url, migrations: Array(LibraryIndex.migrations.prefix(3)))
        let ids = try await older.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "STACKS", kind: .ssd))
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Test/Photos"))
            let folder = try writer.upsertFolder(FolderRecord(root: root, path: "/Volumes/Test/Photos/Shoot"))
            let statement = try writer.database
                .prepare("INSERT INTO photos (folder, name, kind, size, modified) VALUES (?, ?, 2, 0, 0) RETURNING id")
            var ids: [Int64] = []
            for name in ["A.JPG", "B.JPG", "C.JPG"] {
                try statement.bind(folder, at: 1)
                try statement.bind(name, at: 2)
                try ids.append(#require(try statement.first { $0.int64(at: 0) }))
            }
            try writer.setSetting("{\"id\":\"\(id.uuidString)\",\"top\":true}", for: "library.stack.\(ids[0])")
            try writer.setSetting("{\"id\":\"\(id.uuidString)\"}", for: "library.stack.\(ids[1])")
            try writer.setSetting("{\"top\":true}", for: "library.stack.\(ids[2])")
            try writer.setSetting("1", for: "library.stacks")
            return ids
        }
        await older.close()

        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }
        #expect(try await index.read { try StackChoices($0) } == StackChoices([
            ids[0]: .init(id: id, top: true), ids[1]: .init(id: id), ids[2]: .init(top: true),
        ]))
        let settings = try await index.read { reader in
            try ids.map { try reader.setting("library.stack.\($0)") } + [reader.setting("library.stacks")]
        }
        #expect(settings == [nil, nil, nil, "1"])
    }

    @Test func `stacks are found from an index, with the choices it keeps`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["Shoot", "Phone"])
        let shoot = try #require(folders["Shoot"])
        let phone = try #require(folders["Phone"])
        let ids = try await sandbox.index.write { writer in
            let nikon = try writer.cameraID(for: "Nikon Z 6")
            let iphone = try writer.cameraID(for: "Apple iPhone 15 Pro")
            func photo(_ name: String, in folder: Int64, at seconds: Double, camera: Int64) -> PhotoRecord {
                PhotoRecord(
                    folder: folder, name: name, captured: Date(timeIntervalSince1970: seconds), camera: camera,
                    iso: 100, aperture: 4, shutter: 1.0 / 500, focal: 50,
                )
            }
            return try writer.upsertPhotos([
                photo("DSC_0001.NEF", in: shoot, at: 1000, camera: nikon),
                photo("DSC_0001.JPG", in: shoot, at: 1000, camera: nikon),
                photo("DSC_0002.NEF", in: shoot, at: 1000.125, camera: nikon),
                photo("DSC_0002.JPG", in: shoot, at: 1000.125, camera: nikon),
                photo("IMG_0001.HEIC", in: phone, at: 5000, camera: iphone),
            ])
        }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let store = try #require(engine.store)
        var stacks = try await StackFinder.find(in: sandbox.index, store: store)
        #expect(Set(stacks.photos(.pair)) == [[ids[0], ids[1]], [ids[2], ids[3]]])
        #expect(stacks.photos(.burst) == [[ids[0], ids[2]]])

        var choices = StackChoices()
        let changed = choices.stack([ids[3], ids[4]], in: stacks)
        let chosen = choices
        try await sandbox.index.write { try chosen.save(changed, in: $0) }
        stacks = try await StackFinder.find(in: sandbox.index, store: store)
        #expect(stacks.photos(.manual) == [[ids[2], ids[4]]])
        #expect(stacks.photos(.burst).isEmpty && stacks.count(of: .pair) == 2)
    }
}
