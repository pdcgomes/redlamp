import Foundation
import ImageIO
import RedlampDocument
import Testing
import UniformTypeIdentifiers
@testable import RedlampLibrary

/// Each field both ways, in each app's conventions: what other apps' XMP reads as, and what
/// Redlamp's fields write.
struct XMPFieldMappingTests {
    static let now = Date(timeIntervalSince1970: 1_791_200_000)

    /// A packet of one description holding `body`'s attributes and elements.
    static func packet(_ attributes: String, _ elements: String = "") throws -> XMPPacket {
        try #require(XMPPacket(Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
            xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/" xmlns:darktable="http://darktable.sf.net/"
           \(attributes)>
           \(elements)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """.utf8)))
    }

    static func read(_ packet: XMPPacket, _ conventions: XMPConventions = XMPConventions()) -> XMPFields {
        XMPSource(packet: packet, conventions: conventions).fields
    }

    /// `fields` written for `written` into `packet` (a new one when nil), and the packet that makes.
    static func write(
        _ fields: XMPFields, _ written: Set<XMPField>, into packet: XMPPacket? = nil,
        _ conventions: XMPConventions = XMPConventions(),
    ) throws -> XMPPacket {
        let changes = fields.changes(written, to: packet, conventions: conventions, now: now)
        let bytes = try #require(fields.written(into: packet, changes, fields: written, conventions: conventions))
        return try #require(XMPPacket(bytes: bytes))
    }

    @Test func `a Lightroom sidecar reads as its rating, pick, label, keyword paths, title and caption, and writes back`(
    ) throws {
        let lightroom = try Self.packet(
            "xmp:Rating=\"4\" xmp:Label=\"Green\" xmpDM:good=\"True\"",
            """
            <dc:subject><rdf:Bag><rdf:li>Lisbon</rdf:li><rdf:li>Places</rdf:li><rdf:li>Portugal</rdf:li>
              <rdf:li>Gulls</rdf:li></rdf:Bag></dc:subject>
            <lr:hierarchicalSubject><rdf:Bag><rdf:li>Places|Portugal|Lisbon</rdf:li></rdf:Bag></lr:hierarchicalSubject>
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Tagus</rdf:li></rdf:Alt></dc:title>
            <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Ferries at dusk</rdf:li></rdf:Alt></dc:description>
            """,
        )
        let fields = Self.read(lightroom)
        #expect(fields == XMPFields(
            rating: 4, flag: .pick, label: .green, keywords: ["Places/Portugal/Lisbon", "Gulls"], title: "Tagus",
            caption: "Ferries at dusk",
        ))

        let written = try Self.write(fields, Set(XMPField.allCases))
        #expect(Self.read(written) == fields)
        #expect(written.text(XMPNamespace.rating) == "4" && written.text(XMPNamespace.good) == "True")
        #expect(written.text(XMPNamespace.label) == "Green" && written.text(XMPNamespace.labelColor) == "green")
        #expect(written.items(XMPNamespace.hierarchicalSubject) == ["Places|Portugal|Lisbon", "Gulls"])
        #expect(written.items(XMPNamespace.subject) == ["Places", "Portugal", "Lisbon", "Gulls"])
        #expect(written.text(XMPNamespace.metadataDate) == XMPFields.date(Self.now))
        // Writing the same fields again changes nothing, the date included.
        #expect(fields.changes(Set(XMPField.allCases), to: written, conventions: XMPConventions(), now: Self.now)
            .isEmpty)
    }

    @Test(arguments: XMPLabelNames.allCases)
    func `labels read in every app's names and are written in the chosen set's`(_ set: XMPLabelNames) throws {
        let names: [XMPLabelNames: [String]] = [
            .lightroom: ["Red", "Yellow", "Green", "Blue", "Purple"],
            .lightroomReviewStatus: [
                "To Delete",
                "Color Correction Needed",
                "Good to Use",
                "Retouching Needed",
                "To Print",
            ],
            .bridge: ["Select", "Second", "Approved", "Review", "To Do"],
        ]
        for (label, name) in try zip(ColorLabel.allCases, #require(names[set])) {
            #expect(try Self.read(Self.packet("xmp:Label=\"\(name.lowercased())\"")).label == label)
            #expect(set.name(for: label) == name)
            let written = try Self.write(XMPFields(label: label), [.label], into: nil, XMPConventions(labels: set))
            #expect(written.text(XMPNamespace.label) == name && written.text(XMPNamespace.labelColor) == label.rawValue)
            #expect(Self.read(written).label == label)
        }
    }

    @Test func `a label no set names is a custom label, unless Lightroom's colour says which it is`() throws {
        let custom = try Self.read(Self.packet("xmp:Label=\"Urgent\""))
        #expect(custom.label == nil && custom.customLabel == "Urgent")
        let colored = try Self.read(Self.packet("xmp:Label=\"Urgent\" xmp:LabelColor=\"red\""))
        #expect(colored.label == .red && colored.customLabel == nil)
        // Redlamp's label set over the custom one replaces it, colour and all.
        let written = try Self.write(XMPFields(label: .blue), [.label], into: Self.packet("xmp:Label=\"Urgent\""))
        #expect(written.text(XMPNamespace.label) == "Blue" && written.text(XMPNamespace.labelColor) == "blue")
        // Clearing Redlamp's label leaves a custom label it can't show.
        #expect(try XMPFields().changes(
            [.label],
            to: Self.packet("xmp:Label=\"Urgent\""),
            conventions: XMPConventions(),
            now: Self.now,
        )
        .isEmpty)
    }

    @Test func `labels read and written as Urgency, numbered as Photo Mechanic's colour classes, only when it's on`(
    ) throws {
        let urgency = XMPConventions(urgency: true)
        let classes: [(Int, ColorLabel?)] = [
            (1, .purple), (2, .red), (3, nil), (4, .yellow), (5, .green), (6, .blue), (7, nil), (8, nil),
        ]
        for (value, label) in classes {
            let packet = try Self.packet("photoshop:Urgency=\"\(value)\"")
            #expect(Self.read(packet).label == nil, "Urgency is editorial priority unless the library reads it")
            #expect(Self.read(packet, urgency).label == label)
        }
        // A label by name comes first.
        #expect(try Self.read(Self.packet("photoshop:Urgency=\"2\" xmp:Label=\"Blue\""), urgency).label == .blue)

        for label in ColorLabel.allCases {
            let written = try Self.write(XMPFields(label: label), [.label], into: nil, urgency)
            #expect(written.text(XMPNamespace.urgency) == String(XMPUrgency.value(for: label)))
            #expect(Self.read(written, urgency).label == label)
        }
        let blue = try Self.write(XMPFields(label: .blue), [.label], into: nil, urgency)
        let cleared = try Self.write(XMPFields(), [.label], into: blue, urgency)
        #expect(!cleared.has(XMPNamespace.urgency) && !cleared.has(XMPNamespace.label))
        // With Urgency off, a label leaves another app's Urgency as it is.
        let other = try Self.write(XMPFields(label: .green), [.label], into: Self.packet("photoshop:Urgency=\"2\""))
        #expect(other.text(XMPNamespace.urgency) == "2" && other.text(XMPNamespace.label) == "Green")
    }

    @Test func `a reject is -1 in xmp:Rating, as Lightroom and Bridge write it, and its stars come back once it's lifted`(
    ) throws {
        let bridge = try Self.read(Self.packet("xmp:Rating=\"-1\" xmp:Label=\"Select\""))
        #expect(bridge.flag == .reject && bridge.rating == nil && bridge.label == .red)

        let rejected = XMPFields(rating: 3, flag: .reject)
        let written = try Self.write(rejected, [.rating, .flag])
        #expect(written.text(XMPNamespace.rating) == "-1")
        #expect(Self.read(written).flag == .reject && Self.read(written).rating == nil)
        let lifted = try Self.write(XMPFields(rating: 3), [.rating, .flag], into: written)
        #expect(lifted.text(XMPNamespace.rating) == "3" && Self.read(lifted).flag == nil)
        // Unrated stays out of a file that doesn't say, and is 0 in one that does.
        #expect(XMPFields().changes([.rating], to: nil, conventions: XMPConventions(), now: Self.now).isEmpty)
        #expect(try Self.write(XMPFields(), [.rating], into: lifted).text(XMPNamespace.rating) == "0")
        // Fractions round, and what's out of range isn't a rating.
        #expect(try Self.read(Self.packet("xmp:Rating=\"2.6\"")).rating == 3)
        #expect(try Self.read(Self.packet("xmp:Rating=\"9\"")).rating == nil)
    }

    @Test func `a pick is Lightroom's xmpDM:good, set and cleared`() throws {
        let picked = try Self.write(XMPFields(rating: 2, flag: .pick), [.rating, .flag])
        #expect(picked.text(XMPNamespace.good) == "True" && Self.read(picked).flag == .pick)
        let cleared = try Self.write(XMPFields(rating: 2), [.rating, .flag], into: picked)
        #expect(!cleared.has(XMPNamespace.good) && Self.read(cleared).flag == nil)
        #expect(try Self.read(Self.packet("xmpDM:good=\"False\"")).flag == nil)
        // A reject takes the place of a pick.
        let rejected = try Self.write(XMPFields(flag: .reject), [.rating, .flag], into: picked)
        #expect(!rejected.has(XMPNamespace.good) && rejected.text(XMPNamespace.rating) == "-1")
    }

    @Test func `darktable's labels are read, and its bookkeeping tags left out of the keywords`() throws {
        let darktable = try Self.read(Self.packet(
            "xmp:Rating=\"2\"",
            """
            <darktable:colorlabels><rdf:Seq><rdf:li>2</rdf:li><rdf:li>4</rdf:li></rdf:Seq></darktable:colorlabels>
            <dc:subject><rdf:Bag><rdf:li>darktable|format|ARW</rdf:li><rdf:li>Gulls</rdf:li></rdf:Bag></dc:subject>
            <lr:hierarchicalSubject><rdf:Bag><rdf:li>darktable|format|ARW</rdf:li><rdf:li>Birds|Gulls</rdf:li>
            </rdf:Bag></lr:hierarchicalSubject>
            """,
        ))
        #expect(darktable == XMPFields(rating: 2, label: .green, keywords: ["Birds/Gulls"]))
    }

    @Test func `keywords, titles and captions clear, and other apps' flat keywords join the paths`() throws {
        let flat = try Self.read(Self.packet("", "<dc:subject><rdf:Bag><rdf:li>Gulls</rdf:li></rdf:Bag></dc:subject>"))
        #expect(flat.keywords == ["Gulls"])
        let full = try Self.write(
            XMPFields(keywords: ["A/B", "C"], title: "T", caption: "C"), [.keywords, .title, .caption],
        )
        let cleared = try Self.write(XMPFields(), [.keywords, .title, .caption], into: full)
        for property in [
            XMPNamespace.subject,
            XMPNamespace.hierarchicalSubject,
            XMPNamespace.title,
            XMPNamespace.description,
        ] {
            #expect(full.has(property) && !cleared.has(property))
        }
    }

    @Test func `other apps' fields come from the .xmp, then darktable's, then the photo's own, field by field`() throws {
        let sidecar = try XMPSource(packet: Self.packet("xmp:Rating=\"0\""), conventions: XMPConventions())
        let darktable = try XMPSource(packet: Self.packet("xmp:Label=\"Blue\""), conventions: XMPConventions())
        let embedded = XMPSource(
            fields: XMPFields(rating: 5, label: .red, title: "Own"),
            present: [.rating, .label, .title],
        )
        // The .xmp saying unrated hides the photo's own five stars.
        #expect(XMPSource.combining([sidecar, darktable, embedded]) == XMPFields(label: .blue, title: "Own"))
        #expect(XMPSource.combining([nil, nil, embedded]) == embedded.fields)
    }

    @Test func `a photo's own XMP and IPTC are read from its file`() throws {
        let folder = try TemporaryFolder()
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        let image = try #require(context.makeImage())
        func destination(_ name: String) throws -> (URL, CGImageDestination) {
            let url = folder.url.appending(path: name)
            return try (url, #require(CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil,
            )))
        }

        let (xmpURL, xmp) = try destination("IMG_0001.jpg")
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "4" as CFString))
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, "Approved" as CFString))
        CGImageDestinationAddImageAndMetadata(xmp, image, metadata, nil)
        #expect(CGImageDestinationFinalize(xmp))
        let fromXMP = try #require(XMPSource.embedded(in: xmpURL))
        #expect(fromXMP.fields.rating == 4 && fromXMP.fields.label == .green)

        let (iptcURL, iptc) = try destination("IMG_0002.jpg")
        CGImageDestinationAddImage(iptc, image, [
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCKeywords: ["Gulls", "Tagus"], kCGImagePropertyIPTCObjectName: "Ferries",
            ],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(iptc))
        let fromIPTC = try #require(XMPSource.embedded(in: iptcURL))
        #expect(Set(fromIPTC.fields.keywords) == ["Gulls", "Tagus"] && fromIPTC.fields.title == "Ferries")

        #expect(XMPSource.embedded(in: folder.url.appending(path: "missing.jpg")) == nil)
    }
}
