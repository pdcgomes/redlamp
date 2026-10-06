import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

struct NamingEvaluationTests {
    /// A day's `hour`:`minute`:`second` on a camera's clock, read as if it were UTC.
    static func wallClock(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Double,
    ) -> Date {
        Date(timeIntervalSince1970: Double(QueryCalendar.days(year, month, day) * 86400 + hour * 3600 + minute * 60) +
            second)
    }

    /// 5 October 2026 at `hour`:`minute`:`second` on a camera's clock.
    static func wallClock(_ hour: Int, _ minute: Int, _ second: Double) -> Date {
        wallClock(2026, 10, 5, hour, minute, second)
    }

    static let photo = NamingFields(
        name: "DSC_0042.NEF", folder: "/Volumes/Photos/2026/2026-10-05 Wedding",
        captured: wallClock(14, 3, 7.123456), capturedOffset: 3600,
        modified: Date(timeIntervalSince1970: Double(QueryCalendar.days(2026, 10, 6) * 86400 + 8 * 3600)),
        camera: "Nikon Z 6", make: "Nikon", model: "Z 6", lens: "NIKKOR Z 24-70mm f/4 S", iso: 800, aperture: 2.8,
        shutter: 1.0 / 250, focalLength: 35, width: 6048, height: 4024, rating: 4, flag: .pick, label: "Red",
        title: "First dance", caption: "ana and joão", creator: "Pedro", copyright: "© 2026 Pedro",
        location: CaptureMetadata.Location(country: "Portugal", state: "Lisboa", city: "Lisbon", sublocation: "Alfama"),
        keywords: ["People/Ana", "Places/Portugal/Lisbon", "wedding"],
    )

    static let context = NamingContext(
        date: Date(timeIntervalSince1970: Double(QueryCalendar.days(2026, 10, 5) * 86400 + 21 * 3600 + 31 * 60)),
        timeZone: TimeZone(identifier: "America/New_York")!, texts: ["": "Smith Wedding", "shoot": "Lisbon"],
    )

    static func name(
        _ template: String, _ fields: NamingFields = photo, options: NamingOptions = NamingOptions(),
        context: NamingContext = context, counters: NamingCounters = NamingCounters(),
    ) throws -> NamingResult {
        try NamingJob([NamingPhoto(fields)]).names(
            NamingTemplate(parsing: template), options: options, context: context, counters: counters,
        ).results[0]
    }

    static func base(
        _ template: String,
        _ fields: NamingFields = photo,
        options: NamingOptions = NamingOptions(),
    ) throws
        -> String {
        try name(template, fields, options: options).base
    }

    @Test func `each token puts in its field`() throws {
        var renamed = Self.photo
        renamed.originalName = "IMG_1234.NEF"
        var band = Self.photo
        band.keywords = ["Music/AC%2FDC"]
        let cases: [(String, NamingFields, String)] = [
            ("{date}", Self.photo, "20261005"),
            ("{camera}", Self.photo, "Nikon Z 6"),
            ("{make}-{model}", Self.photo, "Nikon-Z 6"),
            ("{lens}", Self.photo, "NIKKOR Z 24-70mm f-4 S"),
            ("{iso} {aperture} {shutter} {focal}", Self.photo, "800 2.8 1-250 35"),
            ("{width}x{height}", Self.photo, "6048x4024"),
            (
                "{title}, {caption}, {creator}, {copyright}",
                Self.photo,
                "First dance, ana and joão, Pedro, © 2026 Pedro",
            ),
            ("{city} {state} {country} {sublocation}", Self.photo, "Lisbon Lisboa Portugal Alfama"),
            ("{keywords}", Self.photo, "Ana Lisbon wedding"),
            ("{keywords:-}", Self.photo, "Ana-Lisbon-wedding"),
            ("{keywords}", band, "AC-DC"),
            ("{rating} {label} {flag}", Self.photo, "4 Red Pick"),
            (
                "{name} {original} {number} {number:6} {number:2} {ext}",
                Self.photo,
                "DSC_0042 DSC_0042 0042 000042 0042 NEF",
            ),
            ("{name} {original} {number}", renamed, "DSC_0042 IMG_1234 1234"),
            ("{folder} {folder:2} {folder:3}", Self.photo, "2026-10-05 Wedding 2026 Photos"),
            ("{sequence} {sequence:4} {total} {total:3}", Self.photo, "1 0001 1 001"),
            ("{text} in {text:shoot}", Self.photo, "Smith Wedding in Lisbon"),
            ("{now:yyyyMMdd-HHmm} {now:HHmm:utc}", Self.photo, "20261005-1731 2131"),
            ("{modified:yyyyMMdd-HHmm} {modified:HHmm:utc}", Self.photo, "20261006-0400 0800"),
        ]
        for (template, fields, expected) in cases {
            #expect(try Self.base(template, fields) == expected, "\(template)")
        }
    }

    @Test func `dates are the camera's clock to the microsecond, in any format`() throws {
        let cases = [
            ("{date:yyyyMMdd-HHmmss.SS}", "20261005-140307.12"),
            ("{date:yyyy-MM-dd HH.mm.ss.SSS}", "2026-10-05 14.03.07.123"),
            ("{date:S SSSSSS SSSSSSS}", "1 123456 1234560"),
            ("{date:yy M d}", "26 10 5"),
            ("{date:MMM MMMM EEE EEEE}", "Oct October Mon Monday"),
            ("{date:D DDD}", "278 278"),
            ("{date:h hh a H}", "2 02 PM 14"),
            ("{date:'Day' d, ''yy}", "Day 5, '26"),
            ("{date:yyyyMMdd-HHmmssZ}", "20261005-140307+0100"),
        ]
        for (template, expected) in cases {
            #expect(try Self.base(template) == expected, "\(template)")
        }
        var midnight = Self.photo
        midnight.captured = Self.wallClock(2026, 1, 1, 0, 0, 0.000_999)
        #expect(try Self.base("{date:\"yyyy-MM-dd HH:mm:ss.SSS EEE D h a\"}", midnight)
            == "2026-01-01 00-00-00.000 Thu 1 12 AM")
        midnight.captured = Self.wallClock(1969, 12, 31, 23, 59, 59.5)
        #expect(try Self.base("{date:yyyyMMdd-HHmmss.S}", midnight) == "19691231-235959.5")
    }

    @Test func `dates move to another zone from the offset the camera recorded`() throws {
        let cases = [
            ("{date:HHmm:utc}", "1303"),
            ("{date:HHmm:+0530}", "1833"),
            ("{date:HHmmZ:\"+05:30\"}", "1833+0530"),
            ("{date:HHmm:Asia/Tokyo}", "2203"),
            ("{date:HHmm:local}", "0903"),
            ("{date:HHmmZ:local}", "0903-0400"),
            ("{date:HHmmZ:camera}", "1403+0100"),
        ]
        for (template, expected) in cases {
            #expect(try Self.base(template) == expected, "\(template)")
        }
        var early = Self.photo
        early.captured = Self.wallClock(0, 30, 0)
        early.capturedOffset = 7200
        #expect(try Self.base("{date:yyyyMMdd-HHmm:utc}", early) == "20261004-2230")
        early.captured = Self.wallClock(23, 30, 0)
        early.capturedOffset = -8 * 3600
        #expect(try Self.base("{date:yyyyMMdd-HHmm:utc}", early) == "20261006-0730")
    }

    @Test func `a date needing the camera's zone is empty, and flagged, when the camera didn't record it`() throws {
        var unzoned = Self.photo
        unzoned.capturedOffset = nil
        #expect(try Self.base("{date:HHmm}", unzoned) == "1403")
        let converted = try Self.name("{date:HHmm:utc}-{name}", unzoned)
        #expect(converted.base == "-DSC_0042")
        #expect(Array(converted.emptyTokens) == [0])
        #expect(try Self.name("{date:HHmmZ}", unzoned).emptyTokens.contains(0))
        #expect(try Self.base("{date:HHmm:utc|default:undated}", unzoned) == "undated")
        var undated = Self.photo
        undated.captured = nil
        #expect(try Self.name("{date}-{name}", undated).emptyTokens.contains(0))
    }

    @Test func `months and weekdays are in the job's language`() throws {
        let template = try NamingTemplate(parsing: "{date:EEEE d MMMM}")
        for (locale, expected) in [
            ("fr_FR", "lundi 5 octobre"),
            ("de_DE", "Montag 5 Oktober"),
            ("en_GB", "Monday 5 October"),
        ] {
            let context = NamingContext(locale: Locale(identifier: locale))
            #expect(NamingJob([NamingPhoto(Self.photo)]).names(template, context: context).results[0].base == expected)
        }
    }

    @Test func `exposure reads as photographers write it`() throws {
        var fields = Self.photo
        let shutters: [(Double, String)] = [
            (1.0 / 8000, "1-8000"), (1.0 / 4, "1-4"), (0.3, "0.3"), (0.5, "0.5"), (1, "1"), (1.3, "1.3"), (30, "30"),
        ]
        for (shutter, expected) in shutters {
            fields.shutter = shutter
            #expect(try Self.base("{shutter}", fields) == expected)
        }
        for (aperture, expected) in [(1.4, "1.4"), (8.0, "8"), (11.0, "11"), (5.6, "5.6")] {
            fields.aperture = aperture
            #expect(try Self.base("{aperture}", fields) == expected)
        }
        for (focal, expected) in [(4.3, "4.3"), (200.0, "200"), (6.86, "6.9")] {
            fields.focalLength = focal
            #expect(try Self.base("{focal}", fields) == expected)
        }
    }

    @Test func `modifiers change case, keep some characters, replace text and match patterns, left to right`() throws {
        let cases = [
            ("{camera|upper}", "NIKON Z 6"),
            ("{camera|lower}", "nikon z 6"),
            ("{caption|title}", "Ana And João"),
            ("{original|range:5..8}", "0042"),
            ("{original:-4..}", "0042"),
            ("{original:..3}", "DSC"),
            ("{original:2}", "S"),
            ("{original:3..-2}", "C_004"),
            ("{name|replace:DSC_:Wedding-}", "Wedding-0042"),
            ("{name|replace:_}", "DSC0042"),
            (#"{name|regex:"^DSC_(\d+)$":"Photo $1"}"#, "Photo 0042"),
            ("{name|regex:dsc::i}", "_0042"),
            ("{name|regex:[0-9]}", "DSC_"),
            ("{title|default:Untitled}", "First dance"),
            ("{title|after:\" - \"}{sequence:3}", "First dance - 001"),
            ("{title|before:\"(\"|after:\")\"}", "(First dance)"),
            ("{camera|replace:\" \"|lower}-{iso}", "nikonz6-800"),
        ]
        for (template, expected) in cases {
            #expect(try Self.base(template) == expected, "\(template)")
        }
        var untitled = Self.photo
        untitled.title = nil
        #expect(try Self.base("{title|default:Untitled}", untitled) == "Untitled")
        #expect(try Self.base("{title|after:\" - \"}{sequence:3}", untitled) == "001")
        #expect(try Self.base("{title|default:none|upper}", untitled) == "NONE")
        #expect(try Self.base("{title|upper|default:none}", untitled) == "none")
        #expect(try Self.base("{original:20..}{name}", untitled) == "DSC_0042")
    }

    @Test func `tokens that come out empty are flagged, unless a default fills them, and an empty name keeps the photo's`(
    ) throws {
        var bare = Self.photo
        bare.title = nil
        bare.label = nil
        var other = Self.photo
        other.name = "DSC_0043.NEF"
        let job = NamingJob([NamingPhoto(bare), NamingPhoto(other)])
        let batch = try job.names(NamingTemplate(parsing: "{title}-{label|default:\"\"}-{name}"))
        #expect(batch.results[0].base == "--DSC_0042")
        #expect(Array(batch.results[0].emptyTokens) == [0])
        #expect(batch.results[1].emptyTokens.isEmpty)
        #expect(batch.emptyCounts == [1, 0, 0])
        let kept = try Self.name("{title}", bare)
        #expect(kept.name == "DSC_0042.NEF" && kept.isUnchanged)
        #expect(kept.adjustments == NamingAdjustments.keptName && kept.emptyTokens.contains(0))
        #expect(try Self.name("{folder:9}-{name}").emptyTokens.contains(0))
    }

    @Test func `names hold no character macOS, network shares or Windows refuse, and no direction marks`() throws {
        var fields = Self.photo
        fields.title = "AC/DC: Live? <2026> \"best\" | *wow*\\"
        let replaced = try Self.name("{title}", fields)
        #expect(replaced.base == "AC-DC- Live- -2026- -best- - -wow--")
        #expect(replaced.adjustments.contains(.replaced))
        #expect(try Self.base("{title}", fields, options: NamingOptions(illegalCharacters: .underscore))
            == "AC_DC_ Live_ _2026_ _best_ _ _wow__")
        fields.title = "a\tb\nc\u{7}d\u{85}e\u{2028}"
        #expect(try Self.base("{title}", fields) == "a-b-c-d-e-")
        fields.title = "photo\u{202E}gpj.exe\u{FEFF}"
        #expect(try Self.base("{title}", fields) == "photogpj.exe")
        #expect(try Self.base("{text:shoot}/{name}") == "Lisbon-DSC_0042")
        #expect(try Self.name("{name}").adjustments.isEmpty)
    }

    @Test func `names never start with a dot or a space, and never end with a space`() throws {
        #expect(try Self.base("..{name}") == "DSC_0042")
        #expect(try Self.base("  {name}  ") == "DSC_0042")
        #expect(try Self.name(". {name}").adjustments == .trimmed)
        #expect(try Self.name(".").adjustments == .keptName)
        #expect(try Self.base("{name} .") == "DSC_0042 .")
    }

    @Test func `spaces are kept or replaced, as the options say`() throws {
        #expect(try Self.base("{title}") == "First dance")
        #expect(try Self.base("{title} {iso}", options: NamingOptions(spaces: .dash)) == "First-dance-800")
        #expect(try Self.base("{title}", options: NamingOptions(spaces: .underscore)) == "First_dance")
    }

    @Test func `names are in Unicode's composed form, as APFS compares them`() throws {
        var fields = Self.photo
        fields.title = "Cafe\u{301} Montre\u{301}al"
        let composed = try Self.name("{title}", fields)
        #expect(Array(composed.name.unicodeScalars) == Array("Caf\u{E9} Montr\u{E9}al.NEF".unicodeScalars))
        fields.title = "\u{301}x"
        #expect(try Array(Self.name("e{title}", fields).base.unicodeScalars) == ["\u{E9}", "x"])
    }

    @Test func `a long name is cut to its UTF-8 limit, its longest text first, never inside a character`() throws {
        var fields = Self.photo
        fields.title = String(repeating: "é", count: 300)
        let accented = try Self.name("{title}-{sequence:4}", fields)
        #expect(accented.base == String(repeating: "é", count: 119) + "-0001")
        #expect(accented.name.utf8.count + NamingJob.sidecarBytes <= 255)
        #expect(accented.adjustments.contains(.shortened))

        fields.title = String(repeating: "a", count: 200)
        fields.caption = String(repeating: "b", count: 200)
        #expect(try Self.base("{title}-{caption}-{sequence:4}", fields)
            == String(repeating: "a", count: 118) + "-" + String(repeating: "b", count: 118) + "-0001")

        fields.title = String(repeating: "👩‍👩‍👧", count: 100)
        let family = try Self.name("{title}", fields)
        #expect(family.base == String(repeating: "👩‍👩‍👧", count: 13))

        fields.title = String(repeating: "a", count: 100)
        let small = try Self.name("{title}", fields, options: NamingOptions(maximumBytes: 64))
        #expect(small.base.utf8.count == 64 - NamingJob.sidecarBytes - 4)
        #expect(try Self.base(String(repeating: "x", count: 300)).utf8.count == 243)
    }

    @Test func `names Windows keeps for devices are given an ending`() throws {
        for (text, expected) in [
            ("CON", "CON-"),
            ("nul", "nul-"),
            ("COM1", "COM1-"),
            ("LPT9", "LPT9-"),
            ("CONSOLE", "CONSOLE"),
        ] {
            let context = NamingContext(texts: ["": text])
            let result = try NamingJob([NamingPhoto(Self.photo)]).names(
                NamingTemplate(parsing: "{text}"),
                context: context,
            )
            .results[0]
            #expect(result.base == expected)
            #expect(result.adjustments.contains(.reserved) == (expected != text))
        }
    }

    @Test func `extensions are kept, or put in small or capital letters`() throws {
        #expect(try Self.name("{name}").name == "DSC_0042.NEF")
        #expect(try Self.name("{name}", options: NamingOptions(extensionCase: .lowercase)).name == "DSC_0042.nef")
        var jpeg = Self.photo
        jpeg.name = "IMG_1.jpeg"
        #expect(try Self.name("{name}", jpeg, options: NamingOptions(extensionCase: .uppercase)).name == "IMG_1.JPEG")
        jpeg.name = "README"
        let bare = try Self.name("{name}-x", jpeg)
        #expect(bare.name == "README-x" && bare.base == "README-x")
        jpeg.name = ".hidden"
        #expect(try Self.name("{name}", jpeg).name == "hidden")
    }

    @Test func `fields come from a file's metadata, the index and a sidecar`() {
        let metadata = CaptureMetadata(
            make: "NIKON CORPORATION", model: "NIKON Z 6", lens: "NIKKOR Z 35mm f/1.8 S", iso: 100, aperture: 1.8,
            shutter: 1.0 / 1000, focalLength: 35, captured: Self.wallClock(9, 0, 0), capturedOffset: 3600,
            pixelSize: PixelSize(width: 6048, height: 4024), rating: 3, label: "Green", keywords: ["birds"],
            title: "Heron", location: CaptureMetadata.Location(city: "Porto"),
        )
        let fields = NamingFields(name: "DSC_1.NEF", folder: "/Photos", metadata: metadata)
        #expect(fields.camera == "Nikon Z 6" && fields.make == "Nikon" && fields.model == "Z 6")
        #expect(fields.width == 6048 && fields.rating == 3 && fields.label == "Green" && fields.location?
            .city == "Porto")
        #expect(NamingFields.makeAndModel(make: "Canon", model: "Canon EOS R6") == ("Canon", "EOS R6"))
        #expect(NamingFields.makeAndModel(make: "SONY", model: "ILCE-7M3") == ("Sony", "ILCE-7M3"))
        #expect(NamingFields.makeAndModel(make: "RICOH IMAGING COMPANY, LTD.", model: "RICOHFLEX") == (
            "Ricoh",
            "RICOHFLEX",
        ))

        let record = PhotoRecord(
            folder: 1, name: "IMG_1.CR3", captured: Self.wallClock(9, 0, 0), capturedOffset: -18000, iso: 400,
            rating: 2,
            flag: .pick, label: .purple, title: "Tram",
        )
        var indexed = NamingFields(
            photo: record, folder: "/Photos/Lisbon", camera: "Canon EOS R6", cameraMake: "Canon",
            cameraModel: "Canon EOS R6", lens: "RF24-105mm F4 L IS USM", keywords: ["Places/Lisbon"],
        )
        #expect(indexed.label == "Purple" && indexed.flag == .pick && indexed.model == "EOS R6")
        #expect(indexed.capturedOffset == -18000 && indexed.title == "Tram" && indexed.keywords == ["Places/Lisbon"])
        indexed.apply(PhotoMetadata(rating: 5, flag: .reject, label: .blue))
        #expect(indexed.rating == 5 && indexed.flag == .reject && indexed.label == "Blue")
    }

    @Test func `the metadata tokens read the fields the index merged, a custom label's name included`() throws {
        let record = PhotoRecord(
            folder: 1, name: "IMG_1.CR3", title: "Tram 28", caption: "Graça", customLabel: "Second Look",
            creator: "Ana Sousa", copyright: "© 2026 Ana Sousa",
            location: PhotoLocation(country: "Portugal", state: "Lisboa", city: "Lisbon", sublocation: "Graça"),
        )
        var fields = NamingFields(photo: record, folder: "/Photos", camera: nil, lens: nil)
        let template = "{title}-{caption}-{creator}-{copyright}-{city}-{state}-{country}-{sublocation}-{label}"
        #expect(try Self.base(template, fields)
            == "Tram 28-Graça-Ana Sousa-© 2026 Ana Sousa-Lisbon-Lisboa-Portugal-Graça-Second Look")
        fields.apply(PhotoMetadata(title: "", creator: "Rui Lopes", location: PhotoLocation(city: "Porto")))
        #expect(try Self.base("{title|default:none}-{creator}-{city}-{country|default:none}", fields)
            == "none-Rui Lopes-Porto-none")
    }
}
