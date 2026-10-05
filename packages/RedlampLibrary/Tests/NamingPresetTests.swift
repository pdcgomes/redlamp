import Foundation
import Testing
@testable import RedlampLibrary

struct NamingPresetTests {
    static let fixture = LibraryFixture(spec: .init(photos: 12, seed: 3))
    static let photos = (0 ..< 12).map { fixture.photo(at: $0) }
    static let context = NamingContext(texts: ["": "Wedding", "shoot": "Lisbon"])

    static func names(_ id: String, counters: NamingCounters = NamingCounters()) throws -> NamingBatch {
        let preset = try #require(NamingPreset.builtIn.first { $0.id == id })
        let job = NamingJob(photos.map { NamingPhoto(NamingFields(fixture: $0, root: "/Fixture")) })
        return job.names(preset.template, options: preset.options, context: context, counters: counters)
    }

    static func base(_ photo: FixturePhoto) -> String {
        (photo.name as NSString).deletingPathExtension
    }

    static func ext(_ photo: FixturePhoto) -> String {
        (photo.name as NSString).pathExtension
    }

    static func number(_ photo: FixturePhoto) -> String {
        String(base(photo).reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
    }

    static func day(_ date: FixtureDate, separator: String = "") -> String {
        [digits(date.year, 4), digits(date.month), digits(date.day)].joined(separator: separator)
    }

    @Test func `Lightroom's templates name the fixture's photos as Lightroom does`() throws {
        let expectations: [(String, (Int, FixturePhoto) -> String)] = [
            ("lightroom-custom-name-sequence", { index, _ in "Wedding-\(index + 1)" }),
            ("lightroom-custom-name-x-of-y", { index, _ in "Wedding (\(index + 1) of 12)" }),
            ("lightroom-custom-name-original-number", { _, photo in "Wedding-\(Self.number(photo))" }),
            ("lightroom-date-filename", { _, photo in "\(Self.day(photo.captured))-\(Self.base(photo))" }),
            ("lightroom-filename", { _, photo in Self.base(photo) }),
            ("lightroom-filename-sequence", { index, photo in "\(Self.base(photo))-\(index + 1)" }),
            ("lightroom-shoot-name-original-number", { _, photo in "Lisbon-\(Self.number(photo))" }),
            ("lightroom-shoot-name-sequence", { index, _ in "Lisbon-\(index + 1)" }),
        ]
        for (id, expected) in expectations {
            let names = try Self.names(id).results.map(\.name)
            #expect(names == Self.photos.enumerated().map { expected($0, $1) + "." + Self.ext($1) }, "\(id)")
        }
        #expect(try Self.names("lightroom-filename").unchanged == 12)

        var custom = [String](repeating: "", count: Self.photos.count)
        for folder in Set(Self.photos.map(\.folder)) {
            let taken = Self.photos.indices.filter { Self.photos[$0].folder == folder }.sorted { a, b in
                Self.photos[a].captured == Self.photos[b].captured ? a < b : Self.photos[a].captured < Self.photos[b]
                    .captured
            }
            for (place, index) in taken.enumerated() {
                custom[index] = (place == 0 ? "Wedding" : "Wedding-\(place + 1)") + "." + Self.ext(Self.photos[index])
            }
        }
        #expect(try Self.names("lightroom-custom-name").results.map(\.name) == custom)
    }

    @Test func `Redlamp's own presets show the time to the millisecond, carry a counter on and number each folder`(
    ) throws {
        for (photo, result) in try zip(Self.photos, Self.names("redlamp-capture-time").results) {
            let time = [photo.captured.hour, photo.captured.minute, photo.captured.second].map { digits($0) }.joined()
            #expect(result.name.hasPrefix("\(Self.day(photo.captured))-\(time)-000"))
        }
        let counted = try Self.names("redlamp-shoot-counter", counters: NamingCounters(["shoot": 100]))
        #expect(counted.results.map(\.base) == (101 ... 112).map { "Lisbon-00\($0)" })
        #expect(counted.counters["shoot"] == 112)

        var places: [String: Int] = [:]
        for (photo, result) in try zip(Self.photos, Self.names("redlamp-date-folder-sequence").results) {
            places[photo.folder, default: 0] += 1
            let folder = (photo.folder as NSString).lastPathComponent
            #expect(result
                .base == "\(Self.day(photo.captured, separator: "-"))-\(folder)-\(digits(places[photo.folder]!, 4))")
        }
    }

    @Test func `presets are saved as JSON and read back, and options a newer Redlamp added take their defaults`(
    ) throws {
        let data = try JSONEncoder().encode(NamingPreset.builtIn)
        #expect(try JSONDecoder().decode([NamingPreset].self, from: data) == NamingPreset.builtIn)
        let saved = try NamingPreset(
            id: "mine", name: "Mine", template: NamingTemplate(parsing: "{date:yyyyMMdd}-{counter:shoot:4}"),
            options: NamingOptions(extensionCase: .lowercase, sequenceStart: 5, spaces: .underscore, maximumBytes: 128),
        )
        #expect(try JSONDecoder().decode(NamingPreset.self, from: JSONEncoder().encode(saved)) == saved)

        let bare = #"{"id": "old", "name": "Old", "template": "{name}"}"#
        let old = try JSONDecoder().decode(NamingPreset.self, from: Data(bare.utf8))
        #expect(old.options == NamingOptions() && old.template.tokens == [NamingToken(.name)])
        let partial = #"{"extensionCase": "uppercase", "maximumBytes": 1000}"#
        let options = try JSONDecoder().decode(NamingOptions.self, from: Data(partial.utf8))
        #expect(options == NamingOptions(extensionCase: .uppercase))
        #expect(NamingOptions(maximumBytes: 10).maximumBytes == 32)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                NamingPreset.self,
                from: Data(#"{"id": "x", "name": "X", "template": "{camra}"}"#.utf8),
            )
        }
    }

    @Test func `built-in presets have their own IDs and name Lightroom's templates as Lightroom does`() {
        #expect(Set(NamingPreset.builtIn.map(\.id)).count == NamingPreset.builtIn.count)
        #expect(NamingPreset.lightroom.map(\.name) == [
            "Custom Name - Sequence", "Custom Name", "Custom Name (x of y)", "Custom Name - Original File Number",
            "Date - Filename", "Filename", "Filename - Sequence", "Shoot Name - Original File Number",
            "Shoot Name - Sequence",
        ])
    }
}
