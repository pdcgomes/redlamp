import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct QueryParserTests {
    private static func parse(_ text: String, asYouType: Bool = false) throws -> LibraryQuery {
        try LibraryQuery(parsing: text, asYouType: asYouType)
    }

    private static func error(_ text: String, asYouType: Bool = false) -> LibraryQueryError? {
        do {
            _ = try LibraryQuery(parsing: text, asYouType: asYouType)
            return nil
        } catch {
            return error
        }
    }

    private static func filter(
        _ field: LibraryQuery.Field, _ comparison: LibraryQuery.Comparison = .equal, _ values: LibraryQuery.Value...,
    ) -> LibraryQuery {
        .filter(LibraryQuery.Filter(field, comparison, values))
    }

    @Test func `free text is words and quoted phrases, joined by AND`() throws {
        #expect(try Self.parse("sunset beach") == .and([.text("sunset"), .text("beach")]))
        #expect(try Self.parse("\"tram 28\"  lisbon") == .and([.text("tram 28"), .text("lisbon")]))
        #expect(try Self.parse(#""say \"hi\" \\ there""#) == .text(#"say "hi" \ there"#))
        #expect(try Self.parse("") == .all)
        #expect(try Self.parse("   ") == .all)
        #expect(try Self.parse("Café-0001 東京") == .and([.text("Café-0001"), .text("東京")]))
    }

    @Test func `every field reads its values, under its own name and its aliases`() throws {
        let cases: [(String, LibraryQuery)] = [
            ("rating:3", Self.filter(.rating, .equal, .number(3))),
            ("stars>=4", Self.filter(.rating, .greaterOrEqual, .number(4))),
            ("flag:pick", Self.filter(.flag, .equal, .flag(.pick))),
            ("flag:Reject", Self.filter(.flag, .equal, .flag(.reject))),
            ("flag:none", Self.filter(.flag, .equal, .flag(nil))),
            ("label:red", Self.filter(.label, .equal, .label(.red))),
            ("label:none", Self.filter(.label, .equal, .label(nil))),
            ("label:Client", Self.filter(.label, .equal, .text("Client"))),
            ("marked:yes", Self.filter(.marked, .equal, .bool(true))),
            ("edited=no", Self.filter(.edited, .equal, .bool(false))),
            ("kw:birds", Self.filter(.keyword, .equal, .text("birds"))),
            ("keyword:\"Places/Portugal\"", Self.filter(.keyword, .equal, .text("Places/Portugal"))),
            ("camera:\"X-T5\"", Self.filter(.camera, .equal, .text("X-T5"))),
            ("lens:35", Self.filter(.lens, .equal, .text("35"))),
            ("iso<=800", Self.filter(.iso, .lessOrEqual, .number(800))),
            ("f:1.4..2.8", Self.filter(.aperture, .equal, .numberRange(1.4, 2.8))),
            ("focal:24mm..70mm", Self.filter(.focal, .equal, .numberRange(24, 70))),
            ("shutter:1/250", Self.filter(.shutter, .equal, .number(1.0 / 250))),
            ("shutter>=1s", Self.filter(.shutter, .greaterOrEqual, .number(1))),
            ("date:2024", Self.filter(.date, .equal, .date(.year(2024)))),
            ("taken:2024-06", Self.filter(.date, .equal, .date(.month(2024, 6)))),
            ("date:2024-02-29", Self.filter(.date, .equal, .date(.day(2024, 2, 29)))),
            ("date:today", Self.filter(.date, .equal, .date(.today))),
            ("date:Yesterday", Self.filter(.date, .equal, .date(.yesterday))),
            ("date:last:30d", Self.filter(.date, .equal, .date(.last(30, .days)))),
            ("date:last:2w", Self.filter(.date, .equal, .date(.last(2, .weeks)))),
            ("date:2024-06..2024-08", Self.filter(.date, .equal, .dateRange(.month(2024, 6), .month(2024, 8)))),
            ("date:2019..", Self.filter(.date, .equal, .dateRange(.year(2019), nil))),
            ("date:..today", Self.filter(.date, .equal, .dateRange(nil, .today))),
            ("folder:Trips", Self.filter(.folder, .equal, .text("Trips"))),
            ("in:\"Trips/2024\"", Self.filter(.folder, .equal, .text("Trips/2024"))),
            ("name:DSC_12", Self.filter(.name, .equal, .text("DSC_12"))),
            ("ext:cr3", Self.filter(.ext, .equal, .text("cr3"))),
            ("ext:.NEF", Self.filter(.ext, .equal, .text("nef"))),
            ("type:raw", Self.filter(.ext, .equal, .kind(.raw))),
            ("type:jpg", Self.filter(.ext, .equal, .kind(.jpeg))),
            ("type:HEIF", Self.filter(.ext, .equal, .kind(.heic))),
            ("collection:Portfolio", Self.filter(.collection, .equal, .text("Portfolio"))),
            ("has:gps", Self.filter(.has, .equal, .detail(.gps))),
            ("has:xmp", Self.filter(.has, .equal, .detail(.xmp))),
            ("title:Tram", Self.filter(.title, .equal, .text("Tram"))),
            ("CAPTION:wedding", Self.filter(.caption, .equal, .text("wedding"))),
            ("missing:yes", Self.filter(.missing, .equal, .bool(true))),
            ("offline:No", Self.filter(.offline, .equal, .bool(false))),
            ("unreadable:yes", Self.filter(.unreadable, .equal, .bool(true))),
            ("creator:\"Ana Silva\"", Self.filter(.creator, .equal, .text("Ana Silva"))),
            ("copyright:©", Self.filter(.copyright, .equal, .text("©"))),
            ("sublocation:Alfama", Self.filter(.sublocation, .equal, .text("Alfama"))),
            ("city:Lisboa,Porto", Self.filter(.city, .equal, .text("Lisboa"), .text("Porto"))),
            ("state:Faro", Self.filter(.state, .equal, .text("Faro"))),
            ("province:Québec", Self.filter(.state, .equal, .text("Québec"))),
            ("country:Portugal", Self.filter(.country, .equal, .text("Portugal"))),
            ("countryCode:PT", Self.filter(.countryCode, .equal, .text("PT"))),
            ("has:creator", Self.filter(.has, .equal, .detail(.creator))),
            ("has:Location", Self.filter(.has, .equal, .detail(.location))),
            ("megapixels>=40", Self.filter(.megapixels, .greaterOrEqual, .number(40))),
            ("mp:24mp..45", Self.filter(.megapixels, .equal, .numberRange(24, 45))),
            ("aspect:3:2", Self.filter(.aspect, .equal, .number(1.5))),
            ("aspect:4/3..2:1", Self.filter(.aspect, .equal, .numberRange(4.0 / 3, 2))),
            ("is:long-exposure", Self.filter(.trait, .equal, .trait(.longExposure))),
            ("IS:Panorama,low-light", Self.filter(.trait, .equal, .trait(.panorama), .trait(.lowLight))),
            (
                "orientation:Portrait,square",
                Self.filter(.orientation, .equal, .orientation(.portrait), .orientation(.square)),
            ),
            ("orientation!=none", Self.filter(.orientation, .notEqual, .orientation(nil))),
            ("date:2024-06-01T14:30", Self.filter(.date, .equal, .date(.time(2024, 6, 1, .minute(14, 30))))),
        ]
        for (text, expected) in cases {
            #expect(try Self.parse(text) == expected, "\(text)")
        }
        let named = Set(cases.compactMap { _, query -> LibraryQuery.Field? in
            if case let .filter(filter) = query {
                return filter.field
            }
            return nil
        })
        #expect(named == Set(LibraryQuery.Field.allCases), "every field is tried")
    }

    @Test func `comparisons, open ranges and comma lists`() throws {
        #expect(try Self.parse("rating!=0") == Self.filter(.rating, .notEqual, .number(0)))
        #expect(try Self.parse("iso>3200") == Self.filter(.iso, .greater, .number(3200)))
        #expect(try Self.parse("iso<100") == Self.filter(.iso, .less, .number(100)))
        #expect(try Self.parse("f:..2") == Self.filter(.aperture, .equal, .numberRange(nil, 2)))
        #expect(try Self.parse("iso:3200..") == Self.filter(.iso, .equal, .numberRange(3200, nil)))
        #expect(try Self.parse("rating:3..5") == Self.filter(.rating, .equal, .numberRange(3, 5)))
        #expect(try Self.parse("label:red,blue") == Self.filter(.label, .equal, .label(.red), .label(.blue)))
        #expect(try Self.parse("rating:4,5") == Self.filter(.rating, .equal, .number(4), .number(5)))
        #expect(try Self.parse("camera:\"EOS R5\",iPhone") == Self.filter(
            .camera, .equal, .text("EOS R5"), .text("iPhone"),
        ))
        #expect(try Self.parse("label!=red,none") == Self.filter(.label, .notEqual, .label(.red), .label(nil)))
        #expect(try Self.parse("iso:1e3") == Self.filter(.iso, .equal, .number(1000)))
    }

    @Test func `negation, OR and parentheses group as written`() throws {
        let (a, b, c) = (LibraryQuery.text("aaa"), LibraryQuery.text("bbb"), LibraryQuery.text("ccc"))
        #expect(try Self.parse("-flag:reject") == .not(Self.filter(.flag, .equal, .flag(.reject))))
        #expect(try Self.parse("label:red OR label:blue") == .or([
            Self.filter(.label, .equal, .label(.red)), Self.filter(.label, .equal, .label(.blue)),
        ]))
        #expect(try Self.parse("aaa bbb OR ccc") == .or([.and([a, b]), c]), "AND binds before OR")
        #expect(try Self.parse("aaa AND bbb") == .and([a, b]))
        #expect(try Self.parse("aaa OR (bbb OR ccc)") == .or([a, b, c]))
        #expect(try Self.parse("aaa (bbb ccc)") == .and([a, b, c]))
        #expect(try Self.parse("((aaa))") == a)
        #expect(try Self.parse("-(aaa OR bbb)") == .not(.or([a, b])))
        #expect(try Self.parse("--aaa") == .not(.not(a)))
        #expect(try Self.parse("(rating>=4 OR flag:pick) -label:none") == .and([
            .or([Self.filter(.rating, .greaterOrEqual, .number(4)), Self.filter(.flag, .equal, .flag(.pick))]),
            .not(Self.filter(.label, .equal, .label(nil))),
        ]))
        #expect(try Self.parse("or and -\"OR\"") == .and([.text("or"), .text("and"), .not(.text("OR"))]))
    }

    @Test func `errors name the characters at fault`() {
        let cases: [(String, Range<Int>, String)] = [
            ("ratng:3", 0 ..< 5, "ratng isn't a field"),
            ("café ratng:3", 5 ..< 10, "ratng isn't a field"),
            ("rating:9", 7 ..< 8, "rating is a whole number from 0 to 5"),
            ("rating:2.5", 7 ..< 10, "rating is a whole number from 0 to 5"),
            ("flag:maybe", 5 ..< 10, "flag is pick, reject or none"),
            ("marked:si", 7 ..< 9, "marked is yes or no"),
            ("has:wifi", 4 ..< 8, "has is gps, keywords, caption, title, xmp, creator, copyright or location"),
            (
                "is:sharp",
                3 ..< 8,
                "is takes a trait: long-exposure, panorama, high-resolution, low-light, no-location or unpicked-moment",
            ),
            ("aspect:3:0", 7 ..< 10, "aspect is the long side over the short"),
            ("orientation:sideways", 12 ..< 20, "orientation is landscape, portrait, square or none"),
            ("orientation>portrait", 11 ..< 12, "orientation can't be compared with >"),
            ("is>panorama", 2 ..< 3, "is can't be compared with >"),
            ("camera>3", 6 ..< 7, "camera can't be compared with >"),
            ("rating>=3,4", 8 ..< 11, "a comparison takes one value"),
            ("iso>=100..200", 5 ..< 13, "a comparison takes one value, not a range"),
            ("date:2024-13", 5 ..< 12, "dates are written"),
            ("date:2023-02-29", 5 ..< 15, "dates are written"),
            ("date:last:30d..today", 5 ..< 20, "last: can't start or end a range"),
            ("f:2.8..1.4", 2 ..< 10, "this range runs backwards"),
            ("date:2020..2019", 5 ..< 15, "this range runs backwards"),
            ("iso:..", 4 ..< 6, "a range needs a start or an end"),
            ("\"open", 0 ..< 5, "this quote isn't closed"),
            ("camera:\"X", 7 ..< 9, "this quote isn't closed"),
            ("(aaa bbb", 0 ..< 1, "this ( isn't closed"),
            ("aaa)", 3 ..< 4, "this ) has no ( before it"),
            ("()", 0 ..< 2, "there's nothing between these parentheses"),
            ("\"\"", 0 ..< 2, "there's nothing between these quotes"),
            ("OR aaa", 0 ..< 2, "OR needs a term before it"),
            ("aaa OR", 4 ..< 6, "OR needs a term after it"),
            ("aaa OR AND bbb", 7 ..< 10, "AND needs a term before it"),
            ("aaa - bbb", 4 ..< 5, "- needs a term after it"),
            ("rating:", 0 ..< 7, "rating needs a value"),
            ("label:red,", 9 ..< 10, "a value is missing after this comma"),
            ("label:,red", 6 ..< 7, "a value is missing before this"),
            (":x", 0 ..< 1, "a field's name is missing before :"),
        ]
        for (text, range, message) in cases {
            let error = Self.error(text)
            #expect(error?.range == range, "\(text): \(error?.message ?? "no error")")
            #expect(error?.message.hasPrefix(message) == true, "\(text): \(error?.message ?? "no error")")
        }
    }

    @Test func `as you type, an unfinished trailing term is left out and open quotes and parentheses close`() throws {
        let rating = Self.filter(.rating, .greaterOrEqual, .number(3))
        let cases: [(String, LibraryQuery)] = [
            ("rating>=3 flag:", rating),
            ("rating>=3 flag:pi", rating),
            ("rating>=3 flag:pi  ", rating),
            ("rating>=3 date:2019-0", rating),
            ("rating>=3 -", rating),
            ("rating>=3 OR", rating),
            ("rating>=3 AND ", rating),
            ("rating>=3 (", rating),
            ("rating>=3 \"", rating),
            ("rating>=", .all),
            ("rating: ", .all),
            ("(rating>=3 OR flag:p", rating),
            ("label:red,", Self.filter(.label, .equal, .label(.red))),
            ("label:red,\"", Self.filter(.label, .equal, .label(.red))),
            ("flag:pick,re", Self.filter(.flag, .equal, .flag(.pick))),
            ("camera:\"X-T", Self.filter(.camera, .equal, .text("X-T"))),
            ("\"tram 2", .text("tram 2")),
            ("(aaa", .text("aaa")),
            ("rating>=3 fl", .and([rating, .text("fl")])),
            ("f:1.4..", Self.filter(.aperture, .equal, .numberRange(1.4, nil))),
            ("f:1.4..2.", Self.filter(.aperture, .equal, .numberRange(1.4, 2))),
        ]
        for (text, expected) in cases {
            #expect(try Self.parse(text, asYouType: true) == expected, "\(text)")
        }
        for text in ["ratng:3 aaa", "flag:pi rating:3", "aaa) bbb", "camera>3 aaa"] {
            #expect(Self.error(text, asYouType: true) != nil, "\(text)")
        }
        #expect(Self.error("rating>=3 flag:pi", asYouType: false)?.range == 15 ..< 17)
    }

    @Test func `the description is canonical text that reads back as the same query`() throws {
        let canonical: [(String, String)] = [
            ("stars>=4 in:Trips type:jpg", "rating>=4 folder:Trips ext:jpeg"),
            ("shutter:0.004", "shutter:1/250"),
            ("shutter:2", "shutter:2"),
            ("f:1.40", "f:1.4"),
            ("label:Red flag:PICK", "label:red flag:pick"),
            ("kw:\"Places/Portugal\"", "kw:Places/Portugal"),
            ("camera:\"EOS R5\"", "camera:\"EOS R5\""),
            ("date:2024-6", "date:2024-06"),
            ("date:2019-06..2019-08", "date:2019-06..2019-08"),
            ("aaa AND (bbb OR ccc)", "aaa (bbb OR ccc)"),
            ("aaa OR (bbb ccc)", "aaa OR bbb ccc"),
            ("-(aaa OR bbb)", "-(aaa OR bbb)"),
            ("-(aaa bbb)", "-(aaa bbb)"),
            ("\"tram 28\"", "\"tram 28\""),
            ("\"OR\"", "\"OR\""),
            ("\"-x\"", "\"-x\""),
            ("\"a:b\"", "\"a:b\""),
            ("label!=red,blue", "label!=red,blue"),
            ("province:\"Île-de-France\" countryCode:FR", "state:Île-de-France countrycode:FR"),
            ("mp>=40 aspect:3:2 IS:Low-Light", "megapixels>=40 aspect:1.5 is:low-light"),
            ("orientation:Portrait -orientation:NONE", "orientation:portrait -orientation:none"),
            ("creator:\"Ana Silva; João\"", "creator:\"Ana Silva; João\""),
            ("iso:..800", "iso:..800"),
            ("iso:1e-5", "iso:1e-05"),
            ("", ""),
        ]
        for (text, expected) in canonical {
            let query = try Self.parse(text)
            #expect(query.description == expected, "\(text)")
            #expect(try Self.parse(query.description) == query, "\(text)")
        }
        for query in FixtureQuery.corpus {
            let parsed = try Self.parse(query.text)
            #expect(try Self.parse(parsed.description) == parsed, "\(query.text)")
        }
    }

    @Test func `searching keeps short free text for the small tables, and leaves out short names, titles and captions`(
    ) throws {
        let rating = Self.filter(.rating, .equal, .number(3))
        #expect(try Self.parse("ab rating:3").searchable == .and([.text("ab"), rating]))
        #expect(try Self.parse("ab OR rating:3").searchable == .or([.text("ab"), rating]))
        #expect(try Self.parse("-ab").searchable == .not(.text("ab")))
        #expect(try Self.parse("name:DS").searchable == nil)
        #expect(try Self.parse("name:DS rating:3").searchable == rating, "what's left of the query")
        #expect(try Self.parse("name:DS,DSCF").searchable == Self.filter(.name, .equal, .text("DSCF")))
        #expect(try Self.parse("title:ab caption:cd").searchable == nil)
        #expect(try Self.parse("ext:x").searchable == nil)
        #expect(try Self.parse("ext:cr3").searchable == Self.filter(.ext, .equal, .text("cr3")))
        #expect(try Self.parse("lens:35").searchable == Self.filter(.lens, .equal, .text("35")))
        #expect(try Self.parse("東京").searchable == .text("東京"), "two characters, still matched against folders")
        #expect(try Self.parse("東京駅").searchable == .text("東京駅"))
    }

    @Test func `text is searchable in the text index from three characters as it holds text`() {
        #expect(!QueryText.isSearchable("ab") && QueryText.isSearchable("abc"))
        #expect(!QueryText.isSearchable("東京") && QueryText.isSearchable("東京駅"))
        #expect(QueryText.isSearchable("aß"), "ß is folded to ss")
        #expect(!QueryText.isSearchable("e\u{301}e"), "two characters, one decomposed")
        #expect(!QueryText.isSearchable("한국".decomposedStringWithCanonicalMapping), "two syllables, composed")
    }

    @Test func `dates span the capture times of their days, today and the last days, weeks, months and years`() throws {
        let day = QueryCalendar.millisecondsPerDay
        let today = QueryCalendar.days(2026, 10, 5)
        func span(_ date: QueryDate) -> (Int64, Int64) {
            let interval = date.interval(today: today)
            return (interval.lowerBound / day, interval.upperBound / day)
        }
        let days = { (year: Int, month: Int, day: Int) in Int64(QueryCalendar.days(year, month, day)) }
        #expect(span(.year(2024)) == (days(2024, 1, 1), days(2025, 1, 1)))
        #expect(span(.month(2024, 2)) == (days(2024, 2, 1), days(2024, 3, 1)))
        #expect(span(.day(2024, 12, 31)) == (days(2024, 12, 31), days(2025, 1, 1)))
        #expect(span(.today) == (days(2026, 10, 5), days(2026, 10, 6)))
        #expect(span(.yesterday) == (days(2026, 10, 4), days(2026, 10, 5)))
        #expect(span(.last(30, .days)) == (days(2026, 9, 6), days(2026, 10, 6)))
        #expect(span(.last(1, .weeks)) == (days(2026, 9, 29), days(2026, 10, 6)))
        #expect(span(.last(1, .months)) == (days(2026, 9, 6), days(2026, 10, 6)))
        #expect(span(.last(10, .months)) == (days(2025, 12, 6), days(2026, 10, 6)))
        #expect(span(.last(1, .years)) == (days(2025, 10, 6), days(2026, 10, 6)))
        let march31 = QueryCalendar.days(2026, 3, 31)
        #expect(QueryDate.last(1, .months).interval(today: march31).lowerBound / day == days(2026, 3, 1))

        let lisbon = try #require(TimeZone(identifier: "Europe/Lisbon"))
        let lateEvening = Date(timeIntervalSince1970: Double(today) * 86400 + 23.5 * 3600)
        #expect(QueryCalendar.today(now: lateEvening, timeZone: lisbon) == today + 1, "past midnight in summer time")
        #expect(QueryCalendar.today(now: lateEvening, timeZone: .gmt) == today)
    }
}
