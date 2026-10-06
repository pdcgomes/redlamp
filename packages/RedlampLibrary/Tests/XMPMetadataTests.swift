import Foundation
import Testing
@testable import RedlampLibrary

/// Other apps' `.xmp` sidecars give the library their ratings, labels, keywords, captions and places.
struct XMPMetadataTests {
    /// In the form Lightroom Classic and Bridge write: properties as attributes, lists as elements,
    /// with Camera Raw's settings beside them.
    static let lightroom = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
        xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
        xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       tiff:Make="SONY"
       tiff:Model="ILCE-7M3"
       xmp:Rating="3"
       xmp:Label="Red"
       photoshop:City="Lisbon"
       photoshop:State="Lisboa"
       photoshop:Country="Portugal"
       Iptc4xmpCore:Location="Alfama"
       crs:Version="17.0"
       crs:Exposure2012="+0.35">
       <dc:title>
        <rdf:Alt>
         <rdf:li xml:lang="x-default">Tram 28</rdf:li>
        </rdf:Alt>
       </dc:title>
       <dc:description>
        <rdf:Alt>
         <rdf:li xml:lang="x-default">The tram climbing to Graça.</rdf:li>
        </rdf:Alt>
       </dc:description>
       <dc:creator>
        <rdf:Seq>
         <rdf:li>Pedro Gomes</rdf:li>
        </rdf:Seq>
       </dc:creator>
       <dc:rights>
        <rdf:Alt>
         <rdf:li xml:lang="x-default">© 2026 Pedro Gomes</rdf:li>
        </rdf:Alt>
       </dc:rights>
       <dc:subject>
        <rdf:Bag>
         <rdf:li>Lisbon</rdf:li>
         <rdf:li>Portugal</rdf:li>
         <rdf:li>Places</rdf:li>
         <rdf:li>tram</rdf:li>
        </rdf:Bag>
       </dc:subject>
       <lr:hierarchicalSubject>
        <rdf:Bag>
         <rdf:li>Places|Portugal|Lisbon</rdf:li>
         <rdf:li>tram</rdf:li>
        </rdf:Bag>
       </lr:hierarchicalSubject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    /// In the form darktable writes through Exiv2, beside `IMG_1234.ARW` as `IMG_1234.ARW.xmp`, with
    /// its history beside the metadata.
    static let darktable = """
    <?xml version="1.0" encoding="UTF-8"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 4.4.0-Exiv2">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:exif="http://ns.adobe.com/exif/1.0/"
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
        xmlns:darktable="http://darktable.sf.net/"
       exif:DateTimeOriginal="2024:06:01 08:30:00"
       xmp:Rating="5"
       xmpMM:DerivedFrom="IMG_1234.ARW"
       darktable:xmp_version="5"
       darktable:raw_params="0"
       darktable:auto_presets_applied="1"
       darktable:history_end="1">
       <darktable:colorlabels>
        <rdf:Seq>
         <rdf:li>2</rdf:li>
        </rdf:Seq>
       </darktable:colorlabels>
       <dc:title>
        <rdf:Alt>
         <rdf:li xml:lang="x-default">Gulls at dawn</rdf:li>
        </rdf:Alt>
       </dc:title>
       <dc:subject>
        <rdf:Bag>
         <rdf:li>gull</rdf:li>
         <rdf:li>darktable|format|ARW</rdf:li>
        </rdf:Bag>
       </dc:subject>
       <lr:hierarchicalSubject>
        <rdf:Bag>
         <rdf:li>Animals|Birds|Gulls</rdf:li>
         <rdf:li>darktable|format|ARW</rdf:li>
        </rdf:Bag>
       </lr:hierarchicalSubject>
       <darktable:history>
        <rdf:Seq>
         <rdf:li darktable:num="0" darktable:operation="exposure" darktable:enabled="1"
          darktable:modversion="6" darktable:params="00000000" darktable:multi_name=""
          darktable:multi_priority="0"/>
        </rdf:Seq>
       </darktable:history>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    /// One description, with the properties given.
    static func xmp(_ properties: String, namespaces: String = "") -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/" \(namespaces)>
           \(properties)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
    }

    @Test func `a Lightroom sidecar's organising fields read, as LibraryXMP reads them`() throws {
        var metadata = try #require(XMPMetadata.parse(Data(Self.lightroom.utf8)))
        #expect(metadata.xmp == XMPSource(xmp: Data(Self.lightroom.utf8)))
        metadata.xmp = nil
        #expect(metadata == CaptureMetadata(
            rating: 3, label: "Red", keywords: ["Places/Portugal/Lisbon", "tram"], title: "Tram 28",
            caption: "The tram climbing to Graça.", creator: "Pedro Gomes", copyright: "© 2026 Pedro Gomes",
            location: .init(country: "Portugal", state: "Lisboa", city: "Lisbon", sublocation: "Alfama"),
        ))
    }

    @Test func `a darktable sidecar's organising fields read, its labels and flat keywords too, without its bookkeeping tags`(
    ) throws {
        var metadata = try #require(XMPMetadata.parse(Data(Self.darktable.utf8)))
        #expect(metadata.xmp == XMPSource(xmp: Data(Self.darktable.utf8)))
        metadata.xmp = nil
        #expect(metadata == CaptureMetadata(
            captured: cameraClock("2024-06-01 08:30:00"), rating: 5, label: "Green", keywords: [
                "Animals/Birds/Gulls",
                "gull",
            ], title: "Gulls at dawn",
        ))
    }

    @Test func `labels read in every app's names and by Lightroom's colour, as Lightroom names them`() {
        for (properties, label) in [
            ("<xmp:Label>Approved</xmp:Label>", "Green"), ("<xmp:Label>To Delete</xmp:Label>", "Red"),
            ("<xmp:Label>Rot</xmp:Label><xmp:LabelColor>red</xmp:LabelColor>", "Red"),
            ("<xmp:Label>Urgent</xmp:Label>", "Urgent"),
        ] {
            #expect(XMPMetadata.parse(Self.xmp(properties))?.label == label, "\(properties)")
        }
        #expect(XMPMetadata.parse(Self.xmp("<xmp:Rating>-1</xmp:Rating>"))?.xmp?.fields.flag == .reject)
        let picked = Self.xmp(
            "<xmpDM:good>True</xmpDM:good>", namespaces: #"xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/""#,
        )
        #expect(XMPMetadata.parse(picked)?.xmp?.fields.flag == .pick)
    }

    @Test func `a slash inside a Lightroom keyword's name stays in the name, as %2F`() {
        let paths = Self.xmp(
            "<lr:hierarchicalSubject><rdf:Bag><rdf:li>Music|AC/DC</rdf:li></rdf:Bag></lr:hierarchicalSubject>",
            namespaces: #"xmlns:lr="http://ns.adobe.com/lightroom/1.0/""#,
        )
        #expect(XMPMetadata.parse(paths)?.keywords == ["Music/AC%2FDC"])
        #expect(KeywordPath("Music/AC%2FDC")?.names == ["Music", "AC/DC"])
    }

    @Test func `a rejected photo's rating reads as -1, as Bridge writes it`() {
        #expect(XMPMetadata.parse(Self.xmp(#"<xmp:Rating>-1</xmp:Rating>"#))?.rating == -1)
        #expect(XMPMetadata.parse(Self.xmp(#"<xmp:Rating>2.0</xmp:Rating>"#))?.rating == 2)
        #expect(XMPMetadata.parse(Self.xmp(#"<xmp:Rating>7</xmp:Rating>"#))?.rating == nil)
    }

    @Test func `without hierarchical keywords, dc:subject's are the keywords`() {
        let flat = Self.xmp("""
        <dc:subject><rdf:Bag><rdf:li> harbour </rdf:li><rdf:li>dusk</rdf:li><rdf:li>dusk</rdf:li><rdf:li></rdf:li></rdf:Bag></dc:subject>
        """)
        #expect(XMPMetadata.parse(flat)?.keywords == ["harbour", "dusk"])
    }

    @Test func `properties read by namespace, whatever prefix the file gives them`() {
        let renamed = Self.xmp(
            "<lightroom:hierarchicalSubject><rdf:Bag><rdf:li>People | Ana</rdf:li></rdf:Bag></lightroom:hierarchicalSubject>",
            namespaces: #"xmlns:lightroom="http://ns.adobe.com/lightroom/1.0/""#,
        )
        #expect(XMPMetadata.parse(renamed)?.keywords == ["People/Ana"])
    }

    @Test func `a title without a default language reads its first`() {
        let title = Self.xmp("""
        <dc:title><rdf:Alt><rdf:li xml:lang="pt-PT">Eléctrico</rdf:li><rdf:li xml:lang="en-GB">Tram</rdf:li></rdf:Alt></dc:title>
        """)
        #expect(XMPMetadata.parse(title)?.title == "Eléctrico")
    }

    @Test func `data that isn't XMP reads as nothing`() {
        #expect(XMPMetadata.parse(Data("not XMP".utf8)) == nil)
        #expect(XMPMetadata.parse(Data()) == nil)
    }

    @Test func `sidecars are looked for under both apps' names`() {
        let raw = URL(fileURLWithPath: "/Photos/2026/IMG_1234.ARW")
        #expect(XMPMetadata.sidecarURLs(for: raw).map(\.path) == [
            "/Photos/2026/IMG_1234.xmp", "/Photos/2026/IMG_1234.ARW.xmp",
        ])
        let bare = URL(fileURLWithPath: "/Photos/2026/scan")
        #expect(XMPMetadata.sidecarURLs(for: bare).map(\.path) == ["/Photos/2026/scan.xmp"])
    }
}
