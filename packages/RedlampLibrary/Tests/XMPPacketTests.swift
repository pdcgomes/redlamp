import Foundation
import Testing
@testable import RedlampLibrary

/// The XMP packet as bytes: properties read in both RDF forms, and edits that leave every byte they
/// don't name as it was.
struct XMPPacketTests {
    /// A sidecar as Lightroom Classic writes it: simple properties as attributes, arrays as elements,
    /// and its develop settings beside them.
    static let lightroom = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
       xmp:Rating="3"
       xmp:Label="Red"
       crs:Version="17.0"
       crs:Exposure2012="+0.35">
       <dc:subject>
        <rdf:Bag>
         <rdf:li>Lisbon</rdf:li>
         <rdf:li>Places</rdf:li>
         <rdf:li>Portugal</rdf:li>
        </rdf:Bag>
       </dc:subject>
       <lr:hierarchicalSubject>
        <rdf:Bag>
         <rdf:li>Places|Portugal|Lisbon</rdf:li>
        </rdf:Bag>
       </lr:hierarchicalSubject>
       <crs:ToneCurvePV2012>
        <rdf:Seq>
         <rdf:li>0, 0</rdf:li>
         <rdf:li>255, 255</rdf:li>
        </rdf:Seq>
       </crs:ToneCurvePV2012>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>

    """

    /// Element form, the old `xap` prefix, two descriptions, Photo Mechanic's own namespace, a
    /// comment and the packet wrapper.
    static let elements = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xap="http://ns.adobe.com/xap/1.0/">
          <xap:Rating>-1</xap:Rating>
          <!-- set in Bridge -->
          <xap:Label>Select</xap:Label>
        </rdf:Description>
        <rdf:Description rdf:about="" xmlns:photomechanic="http://ns.camerabits.com/photomechanic/1.0/">
          <photomechanic:ColorClass>2</photomechanic:ColorClass>
          <photomechanic:Prefs>0:2:0:000123</photomechanic:Prefs>
        </rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    static func packet(_ text: String) throws -> XMPPacket {
        try #require(XMPPacket(Data(text.utf8)))
    }

    static func edited(_ text: String, _ changes: [(XMPProperty, XMPValue?)]) throws -> String {
        let bytes = try #require(packet(text).editing(changes, prefixes: XMPNamespace.prefixes))
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func `properties read in both RDF forms, whatever prefix a file binds their namespace to`() throws {
        let lightroom = try Self.packet(Self.lightroom)
        #expect(lightroom.text(XMPNamespace.rating) == "3" && lightroom.text(XMPNamespace.label) == "Red")
        #expect(lightroom.items(XMPNamespace.subject) == ["Lisbon", "Places", "Portugal"])
        #expect(lightroom.items(XMPNamespace.hierarchicalSubject) == ["Places|Portugal|Lisbon"])
        #expect(lightroom.text(XMPProperty("http://ns.adobe.com/camera-raw-settings/1.0/", "Exposure2012")) == "+0.35")

        let elements = try Self.packet(Self.elements)
        #expect(elements.descriptions.count == 2)
        #expect(elements.text(XMPNamespace.rating) == "-1" && elements.text(XMPNamespace.label) == "Select")
        #expect(elements.text(XMPProperty("http://ns.camerabits.com/photomechanic/1.0/", "ColorClass")) == "2")
    }

    @Test func `an edit changes only the bytes of the properties it names`() throws {
        let edited = try Self.edited(Self.lightroom, [(XMPNamespace.rating, .text("5"))])
        #expect(edited == Self.lightroom.replacingOccurrences(of: "xmp:Rating=\"3\"", with: "xmp:Rating=\"5\""))

        let label = try Self.edited(Self.elements, [(XMPNamespace.label, .text("Second"))])
        #expect(label == Self.elements.replacingOccurrences(of: ">Select<", with: ">Second<"))
    }

    @Test func `a property added goes where its namespace is, declared on the description where it isn't in scope`(
    ) throws {
        let urgency = try Self.edited(Self.lightroom, [
            (XMPNamespace.labelColor, .text("red")), (XMPNamespace.urgency, .text("2")),
        ])
        #expect(urgency == Self.lightroom.replacingOccurrences(
            of: "crs:Exposure2012=\"+0.35\">",
            with: "crs:Exposure2012=\"+0.35\"\n   xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"\n"
                + "   xmp:LabelColor=\"red\"\n   photoshop:Urgency=\"2\">",
        ))

        // The old prefix, already bound in the first description, is the one used.
        let elements = try Self.edited(Self.elements, [(XMPNamespace.metadataDate, .text("2026-10-05T12:00:00Z"))])
        #expect(elements == Self.elements.replacingOccurrences(
            of: "xmlns:xap=\"http://ns.adobe.com/xap/1.0/\">",
            with: "xmlns:xap=\"http://ns.adobe.com/xap/1.0/\" xap:MetadataDate=\"2026-10-05T12:00:00Z\">",
        ))

        let keywords = try Self.edited(Self.elements, [(XMPNamespace.subject, .bag(["Birds", "Fish & Chips"]))])
        #expect(keywords == Self.elements.replacingOccurrences(
            of: "      <xap:Label>Select</xap:Label>\n",
            with: """
                  <xap:Label>Select</xap:Label>
                  <dc:subject>
                   <rdf:Bag>
                    <rdf:li>Birds</rdf:li>
                    <rdf:li>Fish &amp; Chips</rdf:li>
                   </rdf:Bag>
                  </dc:subject>

            """,
        ).replacingOccurrences(
            of: "<rdf:Description rdf:about=\"\" xmlns:xap=\"http://ns.adobe.com/xap/1.0/\">",
            with: "<rdf:Description rdf:about=\"\" xmlns:xap=\"http://ns.adobe.com/xap/1.0/\" "
                + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
        ))
    }

    @Test func `removing a property takes its attribute, or its element's line`() throws {
        let edited = try Self.edited(Self.lightroom, [(XMPNamespace.label, nil), (XMPNamespace.subject, nil)])
        let expected = Self.lightroom.replacingOccurrences(of: "\n   xmp:Label=\"Red\"", with: "")
            .replacingOccurrences(
                of: "\n   <dc:subject>\n    <rdf:Bag>\n     <rdf:li>Lisbon</rdf:li>\n     <rdf:li>Places</rdf:li>\n"
                    + "     <rdf:li>Portugal</rdf:li>\n    </rdf:Bag>\n   </dc:subject>",
                with: "",
            )
        #expect(edited == expected)

        let elements = try Self.edited(Self.elements, [(XMPNamespace.rating, nil)])
        #expect(elements == Self.elements.replacingOccurrences(of: "\n      <xap:Rating>-1</xap:Rating>", with: ""))
    }

    @Test func `an array set again keeps its element and the kind of array it was`() throws {
        let edited = try Self.edited(Self.lightroom, [(XMPNamespace.hierarchicalSubject, .bag(["Birds|Gulls"]))])
        #expect(edited == Self.lightroom.replacingOccurrences(
            of: "<rdf:li>Places|Portugal|Lisbon</rdf:li>", with: "<rdf:li>Birds|Gulls</rdf:li>",
        ))
        let sequence = try Self.edited(
            Self.lightroom, [(
                XMPProperty("http://ns.adobe.com/camera-raw-settings/1.0/", "ToneCurvePV2012"),
                .bag(["1"]),
            )],
        )
        #expect(sequence.contains("<rdf:Seq>\n     <rdf:li>1</rdf:li>\n    </rdf:Seq>"))
    }

    @Test func `a language alternative's default changes in place and its other languages stay`() throws {
        let text = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt>
        <rdf:li xml:lang="pt-PT">Lisboa</rdf:li><rdf:li xml:lang="x-default">Lisbon</rdf:li>
        </rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        #expect(try Self.packet(text).alternative(XMPNamespace.title) == "Lisbon")
        let edited = try Self.edited(text, [(XMPNamespace.title, .alternative("Lisbon at dusk"))])
        #expect(edited == text.replacingOccurrences(of: ">Lisbon<", with: ">Lisbon at dusk<"))
        #expect(try Self.packet(edited).alternative(XMPNamespace.title) == "Lisbon at dusk")
    }

    @Test func `a new packet is a description that opens to take what's added`() throws {
        let empty = XMPPacket.empty(toolkit: "Redlamp")
        let bytes = try #require(empty.editing([
            (XMPNamespace.rating, .text("4")), (XMPNamespace.title, .alternative("Gulls")),
        ], prefixes: XMPNamespace.prefixes))
        #expect(String(decoding: bytes, as: UTF8.self) == """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Redlamp">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description
            rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmp:Rating="4">
           <dc:title>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">Gulls</rdf:li>
            </rdf:Alt>
           </dc:title>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """)
    }

    @Test func `values with markup, quotes and line ends come back as they were`() throws {
        let caption = "Fish & chips <\"best\"> in 'Lisbon'\nsecond line"
        let edited = try Self.edited(Self.lightroom, [
            (XMPNamespace.label, .text(caption)), (XMPNamespace.description, .alternative(caption)),
        ])
        let packet = try Self.packet(edited)
        #expect(packet.text(XMPNamespace.label) == caption && packet.alternative(XMPNamespace.description) == caption)
    }

    @Test func `what isn't XMP in UTF-8 is refused`() throws {
        let doctype = "<!DOCTYPE x [<!ENTITY a \"aaaa\">]><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>"
        #expect(XMPPacket(Data(doctype.utf8)) == nil)
        #expect(try XMPPacket(#require(Self.lightroom.data(using: .utf16))) == nil)
        #expect(XMPPacket(Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"></x:xmpmeta>".utf8)) == nil)
        #expect(XMPPacket(Data(Self.lightroom.dropLast(20).utf8)) == nil)
        #expect(XMPPacket(Data("<a><b></a></b>".utf8)) == nil)
        #expect(XMPPacket(Data("<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><p:x/></rdf:RDF>"
                .utf8)) == nil)
    }
}
