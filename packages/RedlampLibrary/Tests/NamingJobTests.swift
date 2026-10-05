import Foundation
import Testing
@testable import RedlampLibrary

struct NamingJobTests {
    /// A photo in `folder`, taken `minute` minutes after 9:00 on 5 October 2026.
    static func photo(_ name: String, in folder: String = "/Photos/A", minute: Int = 0, camera: String = "Nikon Z 6")
        -> NamingFields {
        NamingFields(
            name: name, folder: folder, captured: NamingEvaluationTests.wallClock(9, minute, 0), capturedOffset: 0,
            camera: camera,
        )
    }

    static func names(
        _ template: String, _ photos: [NamingFields], existing: [String: Set<String>] = [:],
        options: NamingOptions = NamingOptions(), counters: NamingCounters = NamingCounters(),
        destination: String? = nil,
    ) throws -> NamingBatch {
        try NamingJob(photos.map { NamingPhoto($0, destination: destination) }, existing: existing).names(
            NamingTemplate(parsing: template), options: options, context: NamingContext(texts: ["": "Wedding"]),
            counters: counters,
        )
    }

    @Test func `sequences number the photos in the job, in each folder they go to, or by extension`() throws {
        let photos = [
            Self.photo("a1.NEF"), Self.photo("a2.JPG"), Self.photo("a3.NEF"),
            Self.photo("b1.NEF", in: "/Photos/B"), Self.photo("b2.JPG", in: "/Photos/B"),
        ]
        #expect(try Self.names("{sequence:2}", photos).results.map(\.name) == [
            "01.NEF", "02.JPG", "03.NEF", "04.NEF", "05.JPG",
        ])
        #expect(try Self.names("{sequence:2:folder}", photos).results.map(\.name) == [
            "01.NEF", "02.JPG", "03.NEF", "01.NEF", "02.JPG",
        ])
        #expect(try Self.names("{ext}-{sequence:2:extension}", photos).results.map(\.name) == [
            "NEF-01.NEF", "JPG-01.JPG", "NEF-02.NEF", "NEF-03.NEF", "JPG-02.JPG",
        ])
        #expect(try Self.names("{sequence:3}", photos, options: NamingOptions(sequenceStart: 98)).results
            .map(\.base) == [
                "098",
                "099",
                "100",
                "101",
                "102",
            ])
        let imported = try Self.names("{sequence:2:folder}", photos, destination: "/Imports/2026-10-05")
        #expect(imported.results.map(\.base) == ["01", "02", "03", "04", "05"])
    }

    @Test func `photos with different extensions never share a name, unless they're a raw and its JPEG`() throws {
        let batch = try Self.names("{sequence:2:extension}", [Self.photo("a1.NEF"), Self.photo("a2.JPG", minute: 1)])
        #expect(batch.results.map(\.name) == ["01.NEF", "01-2.JPG"])
        #expect(batch.results[1].collision == NamingCollision(suffix: 2, holder: .photo(0)))
    }

    @Test func `named counters carry on from one job and session to the next`() throws {
        let first = try Self.names(
            "{counter:shoot:3}", [Self.photo("a.NEF"), Self.photo("b.NEF"), Self.photo("c.NEF")],
            counters: NamingCounters(["other": 7]),
        )
        #expect(first.results.map(\.base) == ["001", "002", "003"])
        #expect(first.counters == NamingCounters(["shoot": 3, "other": 7]))
        let encoded = try JSONEncoder().encode(first.counters)
        let kept = try JSONDecoder().decode(NamingCounters.self, from: encoded)
        let second = try Self.names(
            "{counter:shoot:3}-{counter:other}-{counter:shoot}", [Self.photo("d.NEF"), Self.photo("e.NEF")],
            counters: kept,
        )
        #expect(second.results.map(\.base) == ["004-8-4", "005-9-5"])
        #expect(second.counters == NamingCounters(["shoot": 5, "other": 9]))
        let pair = try Self.names(
            "{counter:shoot}",
            [Self.photo("f.ARW"), Self.photo("f.JPG")],
            counters: second.counters,
        )
        #expect(pair.results.map(\.name) == ["6.ARW", "6.JPG"])
        #expect(pair.counters["shoot"] == 6)
    }

    @Test func `collisions between the job's photos are numbered in the order they were taken`() throws {
        let photos = [
            Self.photo("c.NEF", minute: 30), Self.photo("a.NEF", minute: 10), Self.photo("b.NEF", minute: 20),
            Self.photo("undated.NEF", minute: 0),
        ]
        var fields = photos
        fields[3].captured = nil
        let batch = try Self.names("{text}", fields)
        #expect(batch.results.map(\.name) == ["Wedding-3.NEF", "Wedding.NEF", "Wedding-2.NEF", "Wedding-4.NEF"])
        #expect(batch.results[0].collision == NamingCollision(suffix: 3, holder: .photo(1)))
        #expect(batch.results[1].collision == nil)
        #expect(batch.collisions == 3 && batch.unchanged == 0)
    }

    @Test func `names files in the folder already have are skipped, whatever their case, form or sidecar`() throws {
        let existing: [String: Set<String>] = ["/Photos/A": [
            "Wedding.jpg", "Wedding-2.NEF", "wedding-3.tif", "Wedding-4.xmp", "Wedding-5.ARW.redlamp", "Notes.txt",
        ]]
        let batch = try Self.names(
            "{text}", [Self.photo("b.NEF", minute: 2), Self.photo("a.NEF", minute: 1), Self.photo("c.NEF", minute: 3)],
            existing: existing,
        )
        #expect(batch.results.map(\.name) == ["Wedding-7.NEF", "Wedding-6.NEF", "Wedding-8.NEF"])
        #expect(batch.results.allSatisfy { $0.collision?.holder == .file("Wedding.jpg") })
        let decomposed = try Self.names(
            "Cafe\u{301}", [Self.photo("a.NEF")], existing: ["/Photos/A": ["CAF\u{C9}.jpg"]],
        )
        #expect(decomposed.results[0].name == "Caf\u{E9}-2.NEF")
        let elsewhere = try Self.names("{text}", [Self.photo("a.NEF")], existing: ["/Photos/B": ["Wedding.NEF"]])
        #expect(elsewhere.results[0].name == "Wedding.NEF")
    }

    @Test func `a photo that keeps its name keeps it, and its own files don't stand in its way`() throws {
        let photos = [Self.photo("Wedding.NEF", minute: 5), Self.photo("IMG_1.NEF", minute: 1)]
        let existing: [String: Set<String>] = ["/Photos/A": [
            "Wedding.NEF", "Wedding.NEF.redlamp", "Wedding.xmp", "IMG_1.NEF", "IMG_1.NEF.redlamp",
        ]]
        let batch = try Self.names("Wedding", photos, existing: existing)
        #expect(batch.results.map(\.name) == ["Wedding.NEF", "Wedding-2.NEF"])
        #expect(batch.results[0].isUnchanged && !batch.results[1].isUnchanged)
        #expect(batch.results[1].collision == NamingCollision(suffix: 2, holder: .photo(0)))
        #expect(batch.unchanged == 1)
        let lowered = try Self.names("wedding", [Self.photo("Wedding.NEF")], existing: existing)
        #expect(lowered.results[0].name == "wedding.NEF" && lowered.results[0].collision == nil)
    }

    @Test func `the job's photos leave their names free for each other`() throws {
        let photos = [Self.photo("A.jpg"), Self.photo("B.jpg")]
        let swap = "{name|regex:^A$:X|regex:^B$:A|regex:^X$:B}"
        let batch = try Self.names(swap, photos, existing: ["/Photos/A": ["A.jpg", "B.jpg", "A.jpg.redlamp", "C.jpg"]])
        #expect(batch.results.map(\.name) == ["B.jpg", "A.jpg"])
        #expect(batch.collisions == 0)
        let blocked = try Self.names("C", [Self.photo("A.jpg")], existing: ["/Photos/A": ["A.jpg", "C.jpg"]])
        #expect(blocked.results[0].name == "C-2.jpg")
    }

    @Test func `a raw and its JPEG share a new name and a number, made from the raw's fields`() throws {
        let photos = [
            Self.photo("IMG_1.JPG", minute: 1, camera: "JPEG camera"), Self.photo("IMG_1.ARW", minute: 1),
            Self.photo("IMG_2.JPG", minute: 2), Self.photo("IMG_3.NEF", minute: 3), Self.photo("img_3.jpg", minute: 3),
            Self.photo("IMG_1.JPG", in: "/Photos/B", minute: 4),
        ]
        let batch = try Self.names("{text}-{sequence:3}-{camera}", photos)
        #expect(batch.results.map(\.name) == [
            "Wedding-001-Nikon Z 6.JPG", "Wedding-001-Nikon Z 6.ARW", "Wedding-002-Nikon Z 6.JPG",
            "Wedding-003-Nikon Z 6.NEF", "Wedding-003-Nikon Z 6.jpg", "Wedding-004-Nikon Z 6.JPG",
        ])
        let taken = try Self.names(
            "{text}", Array(photos.prefix(2)), existing: ["/Photos/A": ["Wedding.JPG", "IMG_1.JPG", "IMG_1.ARW"]],
        )
        #expect(taken.results.map(\.name) == ["Wedding-2.JPG", "Wedding-2.ARW"])
        #expect(taken.collisions == 2)
        let total = try Self.names("{sequence} of {total}", photos)
        #expect(total.results.map(\.base) == ["1 of 4", "1 of 4", "2 of 4", "3 of 4", "3 of 4", "4 of 4"])
    }

    @Test func `photos in different folders may share a name, and photos going to one folder may not`() throws {
        let photos = [Self.photo("a.NEF", in: "/Photos/A", minute: 2), Self.photo("a.NEF", in: "/Photos/B", minute: 1)]
        #expect(try Self.names("{text}", photos).results.map(\.name) == ["Wedding.NEF", "Wedding.NEF"])
        let imported = try Self.names("{text}", photos, destination: "/Imports")
        #expect(imported.results.map(\.name) == ["Wedding-2.NEF", "Wedding.NEF"])
    }

    @Test func `a numbered name still fits the byte limit`() throws {
        let long = String(repeating: "a", count: 300)
        let batch = try Self.names(long, [Self.photo("x.NEF"), Self.photo("y.NEF")])
        #expect(batch.results[0].base == String(repeating: "a", count: 243))
        #expect(batch.results[1].base == String(repeating: "a", count: 241) + "-2")
        #expect(batch.results.allSatisfy { $0.name.utf8.count + NamingJob.sidecarBytes <= 255 })
        let spaced = try Self.names("{text}", [Self.photo("x.NEF"), Self.photo("y.NEF")], options: NamingOptions(
            collisionSeparator: " / ",
        ))
        #expect(spaced.results[1].base == "Wedding - 2")
    }

    @Test func `a template typed a character at a time names every photo at every step`() throws {
        let photos = (0 ..< 50).map { Self.photo(String(format: "IMG_%04d.NEF", $0), minute: $0 % 7) }
        let job = NamingJob(photos.map { NamingPhoto($0) })
        let typed = "{date:yyyyMMdd}-{camera|lower|replace:\" \"}-{sequence:3:folder}"
        for length in 0 ... typed.count {
            let template = try NamingTemplate(parsing: String(typed.prefix(length)), asYouType: true)
            let batch = job.names(template)
            #expect(batch.results.count == photos.count)
            #expect(Set(batch.results.map { $0.name.lowercased() }).count == photos.count)
        }
    }

    @Test func `a large job names its photos on every core, as one would in order`() throws {
        let photos = (0 ..< 20000).map { index in
            Self.photo(
                String(format: "IMG_%05d.%@", index / 2, index % 2 == 0 ? "ARW" : "JPG"),
                in: "/Photos/\(index / 2 % 3)",
                minute: index / 2 % 50,
            )
        }
        let job = NamingJob(photos.map { NamingPhoto($0) })
        let template = try NamingTemplate(parsing: "{date:HHmm}-{sequence:4:folder}")
        let batch = job.names(template)
        #expect(batch.results.map(\.name) == job.names(template).results.map(\.name))
        for folder in 0 ..< 3 {
            let names = batch.results.indices.filter { photos[$0].folder == "/Photos/\(folder)" }
                .map { batch.results[$0].name }
            #expect(Set(names.map { $0.lowercased() }).count == names.count)
        }
        #expect(batch.results[0].base == batch.results[1].base)
    }
}
