import Foundation
import Testing
@testable import RedlampLibrary

struct NamingTemplateTests {
    private static func parse(_ text: String, asYouType: Bool = false) throws -> NamingTemplate {
        try NamingTemplate(parsing: text, asYouType: asYouType)
    }

    private static func error(_ text: String, asYouType: Bool = false) -> NamingTemplateError? {
        do {
            _ = try NamingTemplate(parsing: text, asYouType: asYouType)
            return nil
        } catch {
            return error
        }
    }

    private static func token(
        _ field: NamingField, _ arguments: [String] = [], _ modifiers: [NamingModifier] = [],
    ) -> NamingTemplate {
        NamingTemplate([.token(NamingToken(field, arguments, modifiers: modifiers))])
    }

    @Test func `every token parses, under its own name and its aliases`() throws {
        let cases: [(String, NamingTemplate)] = [
            ("{date}", Self.token(.date)),
            ("{date:yyyyMMdd-HHmmss.SS}", Self.token(.date, ["yyyyMMdd-HHmmss.SS"])),
            ("{taken:yyyy}", Self.token(.date, ["yyyy"])),
            ("{date:yyyy:utc}", Self.token(.date, ["yyyy", "utc"])),
            ("{date::Europe/Lisbon}", Self.token(.date, ["", "Europe/Lisbon"])),
            ("{date:HHmm:\"+05:30\"}", Self.token(.date, ["HHmm", "+05:30"])),
            ("{modified:yyyy-MM-dd}", Self.token(.modified, ["yyyy-MM-dd"])),
            ("{now:yyyyMMdd:local}", Self.token(.now, ["yyyyMMdd", "local"])),
            ("{camera}", Self.token(.camera)),
            ("{make}", Self.token(.make)),
            ("{model}", Self.token(.model)),
            ("{lens}", Self.token(.lens)),
            ("{iso}", Self.token(.iso)),
            ("{aperture}", Self.token(.aperture)),
            ("{f}", Self.token(.aperture)),
            ("{shutter}", Self.token(.shutter)),
            ("{focal}", Self.token(.focal)),
            ("{width}", Self.token(.width)),
            ("{height}", Self.token(.height)),
            ("{title}", Self.token(.title)),
            ("{caption}", Self.token(.caption)),
            ("{creator}", Self.token(.creator)),
            ("{copyright}", Self.token(.copyright)),
            ("{city}", Self.token(.city)),
            ("{state}", Self.token(.state)),
            ("{country}", Self.token(.country)),
            ("{sublocation}", Self.token(.sublocation)),
            ("{keywords}", Self.token(.keywords)),
            ("{kw:\"-\"}", Self.token(.keywords, ["-"])),
            ("{rating}", Self.token(.rating)),
            ("{stars}", Self.token(.rating)),
            ("{label}", Self.token(.label)),
            ("{flag}", Self.token(.flag)),
            ("{name}", Self.token(.name)),
            ("{filename}", Self.token(.name)),
            ("{original}", Self.token(.original)),
            ("{original:5..8}", Self.token(.original, ["5..8"])),
            ("{original:-4..}", Self.token(.original, ["-4.."])),
            ("{number}", Self.token(.number)),
            ("{number:6}", Self.token(.number, ["6"])),
            ("{ext}", Self.token(.ext)),
            ("{extension}", Self.token(.ext)),
            ("{folder}", Self.token(.folder)),
            ("{folder:2}", Self.token(.folder, ["2"])),
            ("{sequence}", Self.token(.sequence)),
            ("{sequence:4}", Self.token(.sequence, ["4"])),
            ("{seq:3:folder}", Self.token(.sequence, ["3", "folder"])),
            ("{sequence:2:extension}", Self.token(.sequence, ["2", "extension"])),
            ("{total:3}", Self.token(.total, ["3"])),
            ("{counter:shoot}", Self.token(.counter, ["shoot"])),
            ("{counter:name:4}", Self.token(.counter, ["name", "4"])),
            ("{text}", Self.token(.text)),
            ("{text:shoot}", Self.token(.text, ["shoot"])),
            ("{CAMERA}", Self.token(.camera)),
        ]
        for (text, expected) in cases {
            #expect(try Self.parse(text) == expected, "\(text)")
        }
        #expect(try Set(cases.map { try Self.parse($0.0).tokens[0].field }) == Set(NamingField.allCases))
    }

    @Test func `modifiers apply in the order they're written, each with its values`() throws {
        let cases: [(String, [NamingModifier])] = [
            ("{camera|upper}", [.upper]),
            ("{camera|lower|title}", [.lower, .title]),
            ("{camera | Upper }", [.upper]),
            ("{original|range:5..8}", [.range(NamingRange(from: 5, to: 8))]),
            ("{original|range:-4..}", [.range(NamingRange(from: -4, to: nil))]),
            ("{original|range:..3}", [.range(NamingRange(from: nil, to: 3))]),
            ("{original|range:2}", [.range(NamingRange(from: 2, to: 2))]),
            ("{original|range:3..-2}", [.range(NamingRange(from: 3, to: -2))]),
            ("{original|replace:IMG_:Photo-}", [.replace("IMG_", with: "Photo-")]),
            ("{original|replace:_}", [.replace("_", with: "")]),
            ("{original|replace:\" \":\"\"}", [.replace(" ", with: "")]),
            (
                #"{original|regex:"^IMG_(\d+)$":"Photo $1":i}"#,
                [.regex(#"^IMG_(\d+)$"#, with: "Photo $1", ignoringCase: true)],
            ),
            (#"{original|regex:"[aeiou]"}"#, [.regex("[aeiou]", with: "", ignoringCase: false)]),
            (#"{original|regex:"(a|b){2}":x}"#, [.regex("(a|b){2}", with: "x", ignoringCase: false)]),
            ("{title|default:Untitled}", [.defaultText("Untitled")]),
            ("{title|default:No title yet}", [.defaultText("No title yet")]),
            ("{title|default:\"\"}", [.defaultText("")]),
            ("{title|before:\"(\"|after:\")\"}", [.before("("), .after(")")]),
            ("{title|after:\" - \"}", [.after(" - ")]),
            ("{title|default:\"Say \"\"hi\"\"\"|upper}", [.defaultText(#"Say "hi""#), .upper]),
        ]
        for (text, modifiers) in cases {
            let token = try #require(try Self.parse(text).tokens.first, "\(text)")
            #expect(token.modifiers == modifiers, "\(text)")
        }
    }

    @Test func `text is kept as it is, with braces written twice`() throws {
        #expect(try Self.parse("Wedding 2026") == NamingTemplate([.text("Wedding 2026")]))
        #expect(try Self.parse("a{{b}}c") == NamingTemplate([.text("a{b}c")]))
        #expect(try Self.parse("{{{camera}}}") == NamingTemplate([
            .text("{"), .token(NamingToken(.camera)), .text("}"),
        ]))
        #expect(try Self.parse("Café-{name} 東京 \\ \"x\" :") == NamingTemplate([
            .text("Café-"), .token(NamingToken(.name)), .text(" 東京 \\ \"x\" :"),
        ]))
        #expect(try Self.parse("") == NamingTemplate([]))
        #expect(try Self.parse("{name}{name}").parts.count == 2)
        #expect(NamingTemplate([.text("a"), .text(""), .text("b")]).parts == [.text("ab")])
    }

    @Test func `values in quotes keep what they hold, and bare values lose the spaces at their ends`() throws {
        #expect(try Self.parse("{date: yyyyMMdd }").tokens[0].arguments == ["yyyyMMdd"])
        #expect(try Self.parse("{keywords:\" | \"}").tokens[0].arguments == [" | "])
        #expect(try Self.parse("{text:\"a:b{c}\"}").tokens[0].arguments == ["a:b{c}"])
        #expect(try Self.parse("{title|after: \" - \" }").tokens[0].modifiers == [.after(" - ")])
        #expect(try Self.parse(#"{original|regex:"\\d":"\\"}"#).tokens[0].modifiers == [
            .regex(#"\\d"#, with: #"\\"#, ignoringCase: false),
        ])
    }

    @Test func `a template's text reads back as the same template`() throws {
        let canonical = [
            "{date:yyyyMMdd-HHmmss.SS}-{camera|lower}-{sequence:4}",
            "{text} ({sequence} of {total})",
            "{original:-4..}",
            "{original|range:5..8}",
            #"{original|regex:^IMG_(\d+)$:Photo $1:i}"#,
            #"{original|regex:"(a|b)"::i}"#,
            "{title|default:Untitled|upper}",
            "{title|default:\"\"}",
            "{title|after:\" - \"}{sequence:3:folder}",
            "{{braces}} and {name}",
            "{counter:shoot:4}",
            "{keywords:-}",
            "{keywords:\" | \"}",
            "{date:yyyy-MM-dd'T'HH:utc}",
            "{date::\"+05:30\"}",
            "{name|replace:IMG_:Photo-|replace:\" \"}",
            "{text:\"Client \"\"A\"\"\"}",
            "Shoot {text:shoot} {date:EEEE d MMMM yyyy}",
        ]
        for text in canonical {
            let template = try Self.parse(text)
            #expect(template.description == text)
            #expect(try Self.parse(template.description) == template)
        }
        let loose = [
            "{ CAMERA |UPPER}", "{seq:4}", "{date: yyyy :UTC}", "{title|default:}", "{name|replace:a:}",
            #"{original|regex:"^IMG_(\d+)$":"Photo $1"}"#, "{keywords:\"-\"}",
        ]
        for text in loose {
            let template = try Self.parse(text)
            #expect(try Self.parse(template.description) == template, "\(text) → \(template.description)")
        }
        #expect(try Self.parse("{ CAMERA |UPPER}").description == "{camera|upper}")
        #expect(try Self.parse("{keywords:\"-\"}").description == "{keywords:-}")
    }

    @Test func `templates made in code read back from their text, whatever their values hold`() throws {
        let awkward = ["", " leading", "trailing ", "a:b", "a|b", "{x}", "say \"hi\"", "\"", "::", "tab\there"]
        for value in awkward {
            let template = NamingTemplate([
                .text("{x} "),
                .token(NamingToken(.text, [value], modifiers: [
                    .replace(value.isEmpty ? "x" : value, with: value), .defaultText(value), .before(value),
                    .after(value), .regex("a|b", with: value, ignoringCase: true),
                ])),
                .token(NamingToken(.date, ["", value.isEmpty ? "utc" : "local"])),
            ])
            #expect(try Self.parse(template.description) == template, "\(template.description)")
        }
    }

    @Test func `errors say which characters are at fault and what's wrong, in a photographer's words`() {
        let cases: [(String, Range<Int>, String)] = [
            ("{camra}", 1 ..< 6, "camra isn't a token; did you mean camera?"),
            ("{camera|uper}", 8 ..< 12, "uper isn't a modifier; did you mean upper?"),
            ("{café}", 1 ..< 5, "café isn't a token"),
            ("IMG {date", 4 ..< 5, "this { isn't closed: end the token with }"),
            ("a}b", 1 ..< 2, "this } doesn't close a token; write }} for a brace in the name"),
            ("{}", 0 ..< 2, "a token's name is missing between these braces"),
            ("{|upper}", 1 ..< 2, "a token's name is missing before this |"),
            ("{camera||upper}", 8 ..< 9, "a modifier's name is missing before this |"),
            ("{-}", 1 ..< 2, "a token's name is a word, such as camera"),
            ("{camera x}", 8 ..< 9, "after camera comes :, | or }"),
            ("{camera:x}", 7 ..< 9, "{camera} takes no value"),
            ("{sequence:0}", 10 ..< 11, "the digits are a number from 1 to 12, as in {sequence:4} for 0001"),
            (
                "{sequence:4:month}",
                12 ..< 17,
                "a sequence counts in the job, folder or extension, as in {sequence:4:folder}",
            ),
            ("{counter}", 1 ..< 8, "counter needs a name, as in {counter:shoot:4}: each name keeps its own count"),
            ("{counter:a:b}", 11 ..< 12, "the digits are a number from 1 to 12, as in {sequence:4} for 0001"),
            (
                "{date:yyyyQQ}",
                10 ..< 12,
                "Q isn't part of a date: use yyyy, MM, dd, HH, mm, ss or SSS, and put text in 'quotes'",
            ),
            ("{date:\"yyyy  Q\"}", 13 ..< 14, "Q isn't part of a date"),
            ("{date:'T}", 6 ..< 7, "this ' isn't closed: end the text with '"),
            ("{date::Mars/Olympus}", 7 ..< 19, "Mars/Olympus isn't a zone"),
            ("{date:a:b:c}", 9 ..< 11, "date takes a format and a zone"),
            ("{original|range:0..3}", 16 ..< 20, "0..3 isn't a range: write 5..8, 5.., ..3 or -4.."),
            ("{original:5..2}", 10 ..< 14, "5..2 isn't a range"),
            ("{original|range}", 10 ..< 15, "range takes the characters to keep, as in range:-4.."),
            ("{name|regex:\"(abc\"}", 12 ..< 18, "this regular expression isn't valid"),
            ("{name|regex:a:b:x}", 16 ..< 17, "the last value of regex is i, to ignore case"),
            ("{name|replace:\"\"}", 14 ..< 16, "the text to replace is missing"),
            ("{title|default}", 7 ..< 14, "default takes its text, as in default:Untitled"),
            ("{title|after:\"x\" y}", 17 ..< 18, "after a value in quotes comes :, | or }"),
            ("{title|after:a\"b}", 14 ..< 15, "a quote can't be inside a value: put the whole value in quotes"),
            ("{title|after:a{b}", 14 ..< 15, "a { can only be in a value in quotes"),
            ("{title|after:\"x}", 13 ..< 16, "this quote isn't closed"),
            ("{folder:0}", 8 ..< 9, "a folder's level is 1 for its own folder, 2 for its parent, and so on"),
            ("{text:a:b}", 7 ..< 9, "text takes the name of the job's text"),
            ("{upper}", 1 ..< 6, "upper isn't a token"),
        ]
        for (text, range, message) in cases {
            let error = Self.error(text)
            #expect(error?.range == range, "\(text): \(error?.message ?? "no error")")
            #expect(error?.message.hasPrefix(message) == true, "\(text): \(error?.message ?? "no error")")
        }
        let many = String(repeating: "{name}", count: NamingTemplate.maximumTokens + 1)
        #expect(Self.error(many)?.message == "a template holds at most 64 tokens")
        #expect(Self.error(String(repeating: "{name}", count: NamingTemplate.maximumTokens)) == nil)
    }

    @Test func `as you type, a token still open at the end is left out, and other errors still show`() throws {
        #expect(try Self.parse("IMG-{dat", asYouType: true) == NamingTemplate([.text("IMG-")]))
        #expect(try Self.parse("{date:yyyy", asYouType: true) == NamingTemplate([]))
        #expect(try Self.parse("{name}-{camera|lo", asYouType: true).parts == [.token(NamingToken(.name)), .text("-")])
        #expect(try Self.parse("{title|after:\" -", asYouType: true) == NamingTemplate([]))
        #expect(try Self.parse("{", asYouType: true) == NamingTemplate([]))
        #expect(try Self.parse("{{", asYouType: true) == NamingTemplate([.text("{")]))
        #expect(Self.error("{camra:", asYouType: true)?.message.hasPrefix("camra isn't a token") == true)
        #expect(Self.error("{camera|uper|", asYouType: true)?.message.hasPrefix("uper isn't a modifier") == true)
        #expect(Self.error("{date:QQ}x", asYouType: true)?.range == 6 ..< 8)
        #expect(Self.error("a}{name", asYouType: true)?.range == 1 ..< 2)
        let typed = "{date:yyyyMMdd}-{camera|lower}-{sequence:4}"
        for length in 0 ... typed.count {
            #expect(throws: Never.self) { try Self.parse(String(typed.prefix(length)), asYouType: true) }
        }
    }

    @Test func `a template codes as its text`() throws {
        let template = try Self.parse("{date:yyyyMMdd}-{title|after:\" \"|default:\"No title\"}")
        let data = try JSONEncoder().encode(template)
        #expect(String(decoding: data, as: UTF8.self) == #""{date:yyyyMMdd}-{title|after:\" \"|default:No title}""#)
        #expect(try JSONDecoder().decode(NamingTemplate.self, from: data) == template)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(
            NamingTemplate.self,
            from: Data(#""{camra}""#.utf8),
        ) }
    }

    @Test func `the editor finds the job's texts, the counters and where each part is`() throws {
        let template = try Self.parse("{text}-{text:shoot}-{counter:a}-{text}-{counter:b:3}-{{x}}")
        #expect(template.textNames == ["", "shoot"])
        #expect(template.counterNames == ["a", "b"])
        let ranges = try Self.parse("IMG-{name}-{{x}}").partRanges
        #expect(ranges == [0 ..< 4, 4 ..< 10, 10 ..< 16])
        #expect(NamingField.allCases.allSatisfy { (try? Self.parse($0.example)) != nil })
    }
}
