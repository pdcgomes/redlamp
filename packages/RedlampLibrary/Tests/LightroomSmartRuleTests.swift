import Foundation
import Testing
@testable import RedlampLibrary

/// Smart collections' rules as Lightroom Classic writes them into its catalog (LIB-29): the Lua table read as
/// data, never run, and its rules made the library's queries, all or nothing.
struct LightroomSmartRuleTests {
    // MARK: - The Lua table

    @Test func `a table of rules is read with its groups, comments, escapes and long strings`() throws {
        let table = try LuaTable(parsing: #"""
        s = {
        	-- the first rule
        	{
        		criteria = "rating",
        		operation = ">=",
        		value = 3,
        		value2 = 0,
        	},
        	{
        		combine = "union";
        		{ criteria = "keywords", operation = "any", value = "Lisbon \"old\" town\n\65\u{e9}", },
        		{ ["criteria"] = 'caption', operation = "any", value = [[two
        lines]], },
        	},
        	--[[ a long
        	     comment ]]
        	combine = "intersect",
        	[1.5] = -0x10,
        	flag = true, missing = nil,
        }
        """#)
        #expect(table.text("combine") == "intersect")
        #expect(table.items.count == 2)
        let rating = try #require(table.items[0].table)
        #expect(rating.text("criteria") == "rating" && rating.text("operation") == ">=" && rating.number("value") == 3)
        let group = try #require(table.items[1].table)
        #expect(group.text("combine") == "union" && group.items.count == 2)
        #expect(group.items[0].table?.text("value") == "Lisbon \"old\" town\nAé")
        #expect(group.items[1].table?.text("criteria") == "caption")
        #expect(group.items[1].table?.text("value") == "two\nlines")
        #expect(table["1.5"] == .number(-16))
        #expect(table["flag"] == .bool(true) && table["missing"] == nil)
    }

    @Test func `the text is data: code, unfinished tables and endless nesting are refused`() {
        for text in [
            "s = { criteria = os.execute('rm -rf /') }", "s = { print('hello') }", "s = { value = x }",
            "s = { { criteria = \"rating\" }", "s = { } os.exit()", "s = { \"open", "s = { value = 1 + 2 }",
            String(repeating: "{", count: 200) + String(repeating: "}", count: 200),
        ] {
            #expect(throws: LuaTableError.self, "\(text.prefix(40))") { try LuaTable(parsing: text) }
        }
        #expect((try? LuaTable(parsing: "return { 1, 2, 3 }"))?.items.count == 3)
        #expect((try? LuaTable(parsing: "{ [3] = 'c', 'a', 'b' }"))?.items == [
            .string("a"),
            .string("b"),
            .string("c"),
        ])
    }

    // MARK: - Rules as queries

    static func rules(_ rules: String, combine: String = "intersect") -> String {
        "s = {\n\(rules)\ncombine = \"\(combine)\",\n}"
    }

    static func rule(_ criteria: String, _ operation: String, _ value: String, _ value2: String = "\"\"") -> String {
        "{ criteria = \"\(criteria)\", operation = \"\(operation)\", value = \(value), value2 = \(value2), },"
    }

    @Test(arguments: [
        (rule("rating", ">=", "3"), "rating>=3"),
        (rule("rating", "==", "0"), "rating:0"),
        (rule("rating", "in", "2", "4"), "rating:2..4"),
        (rule("pick", "==", "1"), "flag:pick"),
        (rule("pick", "==", "-1"), "flag:reject"),
        (rule("pick", "!=", "-1"), "-flag:reject"),
        (rule("labelColor", "==", "\"red\""), "label:red"),
        (rule("labelColor", "==", "\"none\""), "label:none"),
        (rule("labelText", "==", "\"To Print\""), "label:\"To Print\""),
        (rule("title", "any", "\"sunset beach\""), "title:sunset OR title:beach"),
        (rule("caption", "all", "\"sunset beach\""), "caption:sunset caption:beach"),
        (rule("creator", "noneOf", "\"Sousa\""), "-creator:Sousa"),
        (rule("title", "empty", "\"\""), "-has:title"),
        (rule("copyright", "notEmpty", "\"\""), "has:copyright"),
        (rule("city", "any", "\"Lisbon\""), "city:Lisbon"),
        (rule("isoCountryCode", "any", "\"PT\""), "countrycode:PT"),
        (rule("camera", "any", "\"X-T5\""), "camera:X-T5"),
        (rule("lens", "any", "\"35mm\""), "lens:35mm"),
        (rule("isoSpeedRating", ">=", "3200"), "iso>=3200"),
        (rule("aperture", "<=", "2.8"), "f<=2.8"),
        (rule("focalLength", "in", "24", "70"), "focal:24..70"),
        (rule("shutterSpeed", ">=", "\"1/2\""), "shutter>=1/2"),
        (rule("captureTime", "inLast", "30", "\"days\""), "date:last:30d"),
        (rule("captureTime", "in", "\"2024-06-01\"", "\"2024-08-31\""), "date:2024-06-01..2024-08-31"),
        (rule("captureTime", "==", "\"2024-06-01T00:00:00\""), "date:2024-06-01"),
        (rule("captureTime", ">", "\"2024-06-01\""), "date>2024-06-01"),
        (rule("captureTime", "today", "\"\""), "date:today"),
        (rule("fileFormat", "==", "\"RAW\""), "ext:raw"),
        (rule("fileFormat", "!=", "\"JPG\""), "-ext:jpeg"),
        (rule("fileFormat", "==", "\"DNG\""), "ext:dng"),
        (rule("aspectRatio", "==", "\"portrait\""), "orientation:portrait"),
        (rule("hasGPSData", "isTrue", "true"), "has:gps"),
        (rule("folder", "any", "\"Trips\""), "folder:Trips"),
        (rule("filename", "any", "\"DSC_\""), "name:DSC_"),
        (rule("all", "all", "\"lisbon tram\""), "lisbon tram"),
    ])
    func `each kind of rule is a term of the query language`(_ rules: String, _ query: String) {
        let mapped = LightroomSmartRules.query(Self.rules(rules))
        #expect(mapped.reasons.isEmpty, "\(mapped.reasons)")
        #expect(mapped.query == query)
    }

    @Test func `groups match all, any or none of their rules, nested as Lightroom nests them`() throws {
        let rules = Self.rules(Self.rule("rating", ">=", "4") + """
        {
          \(Self.rule("labelColor", "==", "\"red\""))
          \(Self.rule("labelColor", "==", "\"blue\""))
          combine = "union",
        },
        {
          \(Self.rule("pick", "==", "-1"))
          \(Self.rule("fileFormat", "==", "\"JPG\""))
          combine = "exclude",
        },
        """)
        let mapped = LightroomSmartRules.query(rules)
        #expect(mapped.query == "rating>=4 (label:red OR label:blue) -(flag:reject OR ext:jpeg)")
        let parsed = try LibraryQuery(parsing: #require(mapped.query))
        #expect(parsed.description == mapped.query)
        #expect(LightroomSmartRules.query(Self.rules(
            Self.rule("rating", "==", "5") + Self.rule("pick", "==", "1"), combine: "union",
        )).query == "rating:5 OR flag:pick")
    }

    @Test func `keywords match whole keywords, which the report says differs from Lightroom's parts of words`() {
        let mapped = LightroomSmartRules.query(Self.rules(Self.rule("keywords", "all", "\"birds, Places/Lisbon\"")))
        #expect(mapped.query == "kw:birds kw:Places/Lisbon")
        #expect(mapped.differences.count == 1)
        #expect(mapped.differences.first?.contains("whole keywords") == true)
        let none = LightroomSmartRules.query(Self.rules(Self.rule("keywords", "empty", "\"\"")))
        #expect(none.query == "-has:keywords" && none.differences.isEmpty)
    }

    @Test func `a smart collection with a rule that doesn't map isn't brought across, and the report says why`() {
        let mapped = LightroomSmartRules.query(Self.rules(
            Self.rule("rating", ">=", "3") + Self.rule("touchTime", "inLast", "7", "\"days\"")
                + Self.rule("title", "beginsWith", "\"The\"") + Self.rule("somethingNew", "==", "1"),
        ))
        #expect(mapped.query == nil)
        #expect(mapped.reasons.count == 3)
        #expect(mapped.reasons[0].contains("Redlamp keeps no edit dates"))
        #expect(mapped.reasons[1].contains("not at its start or end"))
        #expect(mapped.reasons[2].contains("“somethingNew”"))
        #expect(LightroomSmartRules.query("s = { criteria = ").reasons.first?.contains("can't be read") == true)
        #expect(LightroomSmartRules.query(Self.rules(Self.rule("fileFormat", "==", "\"VIDEO\""))).query == nil)
    }
}
