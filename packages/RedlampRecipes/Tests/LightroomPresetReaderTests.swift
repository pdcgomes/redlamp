import Foundation
import Testing
@testable import RedlampRecipes

/// Lightroom presets written in the tests from the Camera Raw schema (XMP Specification Part 2,
/// 3.3, and ExifTool's table of `crs` tags), never copied from Adobe's files.
enum PresetXMP {
    /// Simple settings as attributes of the description, as Lightroom Classic writes them, or
    /// as elements, as other writers do.
    enum Form: String, CaseIterable, Sendable {
        case attributes, elements
    }

    static let namespace = "http://ns.adobe.com/camera-raw-settings/1.0/"

    /// A preset of `settings`, its name and group as language alternatives and `lists` (curves) as
    /// sequences; `body` is more XML inside the description.
    static func preset(
        _ settings: [(String, String)] = [],
        form: Form = .attributes,
        name: String? = "Test Preset",
        group: String? = nil,
        lists: [(String, [String])] = [],
        body: String = "",
        prefix: String = "crs",
    ) -> Data {
        var attributes = ""
        var elements = ""
        for (key, value) in settings {
            switch form {
            case .attributes: attributes += "\n    \(prefix):\(key)=\"\(escaped(value))\""
            case .elements: elements += "\n   <\(prefix):\(key)>\(escaped(value))</\(prefix):\(key)>"
            }
        }
        for (key, text) in [("Name", name), ("Group", group)] {
            guard let text else { continue }
            elements += """

               <\(prefix):\(key)>
                <rdf:Alt>
                 <rdf:li xml:lang="x-default">\(escaped(text))</rdf:li>
                </rdf:Alt>
               </\(prefix):\(key)>
            """
        }
        for (key, items) in lists {
            let lines = items.map { "\n     <rdf:li>\($0)</rdf:li>" }.joined()
            elements += "\n   <\(prefix):\(key)>\n    <rdf:Seq>\(lines)\n    </rdf:Seq>\n   </\(prefix):\(key)>"
        }
        return Data(packet("""
          <rdf:Description rdf:about=""
            xmlns:\(prefix)="\(namespace)"\(attributes)>\(elements)\(body)
          </rdf:Description>
        """).utf8)
    }

    /// An XMP packet around `descriptions`, as Adobe's XMP toolkit writes one.
    static func packet(_ descriptions: String) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Redlamp tests">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        \(descriptions)
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

struct LightroomPresetReaderTests {
    private func read(_ data: Data) throws -> CameraRawSettings {
        try #require(CameraRawSettings(xmp: data))
    }

    @Test func `simple settings read the same as attributes and as elements`() throws {
        let settings = [("Exposure2012", "+0.50"), ("ConvertToGrayscale", "True"), ("Dehaze", "-12.5")]
        let attributes = try read(PresetXMP.preset(settings, form: .attributes))
        let elements = try read(PresetXMP.preset(settings, form: .elements))
        #expect(attributes.values == elements.values)
        #expect(attributes.number("Exposure2012") == 0.5)
        #expect(attributes.number("Dehaze") == -12.5)
        #expect(attributes.flag("ConvertToGrayscale") == true)
        #expect(attributes.text("Name") == "Test Preset")
    }

    @Test func `a language alternative reads as its default text`() throws {
        let settings = try read(PresetXMP.preset(body: """
           <crs:Group>
            <rdf:Alt>
             <rdf:li xml:lang="fr-FR">Couleur</rdf:li>
             <rdf:li xml:lang="x-default">Color</rdf:li>
            </rdf:Alt>
           </crs:Group>
           <crs:ShortName>
            <rdf:Alt>
             <rdf:li xml:lang="de-DE">Warm</rdf:li>
            </rdf:Alt>
           </crs:ShortName>
        """))
        #expect(settings.text("Group") == "Color")
        #expect(settings.text("ShortName") == "Warm")
    }

    @Test func `the namespace reads under any prefix`() throws {
        let settings = try read(PresetXMP.preset([("Texture", "+20")], form: .elements, prefix: "cr"))
        #expect(settings.number("Texture") == 20)
        #expect(settings.text("Name") == "Test Preset")
    }

    @Test func `a structure's fields stay inside it in every form`() throws {
        let settings = try read(PresetXMP.preset([("ProcessVersion", "15.4")], body: """
           <crs:Look rdf:parseType="Resource">
            <crs:Name>Adobe Color</crs:Name>
            <crs:Amount>1</crs:Amount>
            <crs:Parameters>
             <rdf:Description crs:ProcessVersion="5.7" crs:ConvertToGrayscale="True">
              <crs:ToneCurvePV2012>
               <rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq>
              </crs:ToneCurvePV2012>
             </rdf:Description>
            </crs:Parameters>
           </crs:Look>
           <crs:RangeMaskMapInfo>
            <rdf:Description crs:RangeMaskMapInfo="x"><crs:Version>2</crs:Version></rdf:Description>
           </crs:RangeMaskMapInfo>
           <crs:DepthMapInfo crs:BaseHighlightGuideInputDigest="abc" crs:DepthSource="Embedded"/>
        """))
        #expect(settings["Look"] == .structure(["Name": "Adobe Color", "Amount": "1"]))
        #expect(settings["RangeMaskMapInfo"] == .structure(["RangeMaskMapInfo": "x", "Version": "2"]))
        #expect(settings["DepthMapInfo"] == .structure([
            "BaseHighlightGuideInputDigest": "abc",
            "DepthSource": "Embedded",
        ]))
        #expect(settings.text("Name") == "Test Preset")
        #expect(settings.text("ProcessVersion") == "15.4")
        #expect(settings["ConvertToGrayscale"] == nil)
        #expect(settings["ToneCurvePV2012"] == nil)
    }

    @Test func `lists keep their order and arrays of structures are counted`() throws {
        let settings = try read(PresetXMP.preset(
            lists: [("ToneCurvePV2012", ["0, 10", "128, 120", "255, 245"])],
            body: """
               <crs:MaskGroupBasedCorrections>
                <rdf:Seq>
                 <rdf:li rdf:parseType="Resource"><crs:What>Correction</crs:What></rdf:li>
                 <rdf:li><rdf:Description crs:What="Correction"/></rdf:li>
                </rdf:Seq>
               </crs:MaskGroupBasedCorrections>
               <crs:PointColors>
                <rdf:Bag/>
               </crs:PointColors>
            """,
        ))
        #expect(settings["ToneCurvePV2012"] == .list(["0, 10", "128, 120", "255, 245"]))
        #expect(settings["MaskGroupBasedCorrections"] == .structures(2))
        #expect(settings["PointColors"] == .list([]))
    }

    @Test func `settings spread over several descriptions are merged, the first value kept`() throws {
        let settings = try read(Data(PresetXMP.packet("""
          <rdf:Description rdf:about="" xmlns:crs="\(PresetXMP.namespace)" crs:Exposure2012="+1.00"/>
          <rdf:Description rdf:about="" xmlns:crs="\(PresetXMP.namespace)" xmlns:dc="http://purl.org/dc/elements/1.1/"
            crs:Contrast2012="+10" crs:Exposure2012="-1.00" dc:format="image/x-sony-arw"/>
        """).utf8))
        #expect(settings.number("Exposure2012") == 1)
        #expect(settings.number("Contrast2012") == 10)
        #expect(settings["format"] == nil)
    }

    @Test func `a qualified value, an entity and a CDATA section read as their text`() throws {
        let settings = try read(PresetXMP.preset(body: """
           <crs:Description rdf:parseType="Resource">
            <rdf:value>Warm &amp; soft</rdf:value>
            <crs:Note>a qualifier</crs:Note>
           </crs:Description>
           <crs:Copyright><![CDATA[© Someone <studio>]]></crs:Copyright>
        """))
        #expect(settings.text("Description") == "Warm & soft")
        #expect(settings.text("Copyright") == "© Someone <studio>")
    }

    @Test func `XML that isn't XMP, or declares a document type, isn't read`() {
        #expect(CameraRawSettings(xmp: Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)) == nil)
        #expect(CameraRawSettings(xmp: Data("<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf".utf8)) == nil)
        #expect(CameraRawSettings(xmp: Data("{\"format\": 1}".utf8)) == nil)
        let entity = "<!DOCTYPE x [<!ENTITY a \"aaaaaaaaaa\">]>\n" + String(decoding: PresetXMP.preset(), as: UTF8.self)
        #expect(CameraRawSettings(xmp: Data(entity.utf8)) == nil)
    }

    @Test func `isPreset recognises a preset and nothing else`() {
        #expect(LightroomPreset.isPreset(PresetXMP.preset([("Exposure2012", "+0.50")])))
        let dublinCore = PresetXMP.packet("""
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" dc:format="image/jpeg"/>
        """)
        #expect(!LightroomPreset.isPreset(Data(dublinCore.utf8)))
        #expect(!LightroomPreset.isPreset(Data()))
        #expect(!LightroomPreset.isPreset(Data("{\"format\": 1, \"id\": \"local/x\"}".utf8)))
        #expect(!LightroomPreset.isPreset(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])))
    }

    @Test func `a preset whose first 64 KB ends inside a character is still recognised`() throws {
        let preset = PresetXMP.preset(
            [("Exposure2012", "+0.50")], body: "\n   <crs:Description>MARK</crs:Description>",
        )
        let parts = String(decoding: preset, as: UTF8.self).components(separatedBy: "MARK")
        // "é" is two bytes in UTF-8: the first is the sniffed prefix's last byte.
        let filler = String(repeating: "a", count: 64 * 1024 - 1 - parts[0].utf8.count)
        let data = Data((parts[0] + filler + String(repeating: "é", count: 10) + parts[1]).utf8)
        #expect(data[64 * 1024 - 1] == 0xC3)
        #expect(LightroomPreset.isPreset(data))
        let imported = try LightroomPreset.convert(data)
        #expect(imported.recipe.name == "Test Preset")
    }
}

struct LightroomPresetRefusalTests {
    @Test(arguments: ["5.7", "5.0"])
    func `presets before Process 2012 are refused`(version: String) {
        let preset = PresetXMP.preset([("ProcessVersion", version), ("Exposure", "+0.50"), ("FillLight", "20")])
        #expect(throws: LightroomPresetError.unsupportedProcessVersion(version)) {
            try LightroomPreset.convert(preset)
        }
    }

    @Test(arguments: ["6.7", "10.0", "11.0", "15.4"])
    func `Process 2012 and its successors convert`(version: String) throws {
        let imported = try LightroomPreset.convert(PresetXMP.preset([("ProcessVersion", version), ("Texture", "+5")]))
        #expect(imported.report.processVersion == version)
        #expect(imported.recipe.settings.values == [.texture: 5])
    }

    @Test func `XMP that isn't a develop preset is refused`() {
        let dublinCore = PresetXMP.packet("""
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" dc:format="image/jpeg"/>
        """)
        let noSettings = PresetXMP.preset([("HasSettings", "False"), ("AlreadyApplied", "False")])
        let profile = PresetXMP.preset([("PresetType", "Look"), ("Contrast2012", "+20")])
        let malformed = Data(String(decoding: PresetXMP.preset([("Exposure2012", "+1")]), as: UTF8.self)
            .replacingOccurrences(of: "</rdf:RDF>", with: "").utf8)
        for data in [Data(dublinCore.utf8), noSettings, profile, malformed, Data("not xml".utf8)] {
            #expect(throws: LightroomPresetError.notAPreset) {
                try LightroomPreset.convert(data)
            }
        }
    }

    /// A photo's sidecar as Lightroom writes one beside a raw: the photo's TIFF and Exif metadata,
    /// the raw's file name and its develop settings, in one description or one per namespace.
    static func sidecar(form: PresetXMP.Form, split: Bool = false) -> Data {
        let photo = [
            ("tiff", "Make", "Example"),
            ("tiff", "Model", "Example X1"),
            ("exif", "ExposureTime", "1/250"),
            ("exif", "FNumber", "56/10"),
            ("aux", "Lens", "Example 35mm F1.8"),
            ("exifEX", "LensModel", "Example 35mm F1.8"),
        ]
        let develop = [
            ("crs", "Version", "15.4"),
            ("crs", "ProcessVersion", "11.0"),
            ("crs", "RawFileName", "IMG_0001.CR3"),
            ("crs", "WhiteBalance", "As Shot"),
            ("crs", "Exposure2012", "+0.40"),
            ("crs", "HasSettings", "True"),
        ]
        let namespaces = """
        xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/" \
        xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" xmlns:exifEX="http://cipa.jp/exif/1.0/" \
        xmlns:crs="\(PresetXMP.namespace)"
        """
        func description(_ properties: [(String, String, String)]) -> String {
            switch form {
            case .attributes:
                let attributes = properties.map { "\n    \($0.0):\($0.1)=\"\($0.2)\"" }.joined()
                return "  <rdf:Description rdf:about=\"\" \(namespaces)\(attributes)/>\n"
            case .elements:
                let elements = properties.map { "\n   <\($0.0):\($0.1)>\($0.2)</\($0.0):\($0.1)>" }.joined()
                return "  <rdf:Description rdf:about=\"\" \(namespaces)>\(elements)\n  </rdf:Description>\n"
            }
        }
        let descriptions = split ? description(photo) + description(develop) : description(photo + develop)
        return Data(PresetXMP.packet(descriptions).utf8)
    }

    @Test(arguments: PresetXMP.Form.allCases, [false, true])
    func `a photo's sidecar isn't a preset`(form: PresetXMP.Form, split: Bool) {
        let sidecar = Self.sidecar(form: form, split: split)
        #expect(CameraRawSettings(xmp: sidecar)?.text("Exposure2012") == "+0.40")
        #expect(!LightroomPreset.isPreset(sidecar))
        #expect(throws: LightroomPresetError.notAPreset) {
            try LightroomPreset.convert(sidecar)
        }
    }

    @Test(arguments: PresetXMP.Form.allCases)
    func `a preset is recognised by its type, or else by its own name, group or UUID`(form: PresetXMP.Form) {
        let typed = PresetXMP.preset([("PresetType", "Normal"), ("Exposure2012", "+0.50")], form: form, name: nil)
        let named = PresetXMP.preset([("Exposure2012", "+0.50")], form: form)
        let grouped = PresetXMP.preset([("Exposure2012", "+0.50")], form: form, name: nil, group: "Portraits")
        let identified = PresetXMP.preset([("UUID", "6F1C"), ("Exposure2012", "+0.50")], form: form, name: nil)
        for preset in [typed, named, grouped, identified] {
            #expect(LightroomPreset.isPreset(preset))
        }
        let anonymous = PresetXMP.preset([("Exposure2012", "+0.50")], form: form, name: nil)
        let blankName = PresetXMP.preset([("Exposure2012", "+0.50")], form: form, name: " ")
        let rawFile = PresetXMP.preset([("RawFileName", "IMG_0001.CR3"), ("Exposure2012", "+0.50")], form: form)
        let profile = PresetXMP.preset([("PresetType", "Look"), ("Exposure2012", "+0.50")], form: form)
        for data in [anonymous, blankName, rawFile, profile] {
            #expect(!LightroomPreset.isPreset(data))
        }
    }

    @Test func `a preset without a process version converts, and Process 2010 sliders are reported`() throws {
        let imported = try LightroomPreset.convert(PresetXMP.preset([
            ("Exposure", "+0.50"), ("FillLight", "20"), ("Shadows", "5"), ("Exposure2012", "+0.30"),
        ]))
        #expect(imported.report.processVersion == nil)
        #expect(imported.recipe.settings.values == [.exposure: 0.3])
        let ignored = imported.report.entries(.ignored)
        #expect(ignored.map(\.setting) == ["Exposure", "FillLight", "Shadows"])
        #expect(ignored.first?.note == "Process 2010's Exposure, which Process 2012 replaced with Exposure2012.")
        #expect(ignored.last?.note == "Process 2010's Blacks, which Process 2012 replaced with Blacks2012.")
    }
}
