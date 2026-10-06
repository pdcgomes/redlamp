import Foundation
import RedlampDocument

/// The names apps give Redlamp's five colour labels in `xmp:Label`: each is a label set, and only
/// a label written with the receiving app's name shows there as a colour.
public enum XMPLabelNames: String, Sendable, Hashable, Codable, CaseIterable {
    /// Lightroom Classic's default set, which Capture One, Photo Mechanic and FastRawViewer also
    /// read: the colours' English names.
    case lightroom
    /// Lightroom Classic's Review Status set.
    case lightroomReviewStatus = "review"
    /// Adobe Bridge's default set.
    case bridge

    /// In red, yellow, green, blue and purple's order, as `ColorLabel` has them.
    private var names: [String] {
        switch self {
        case .lightroom: ["Red", "Yellow", "Green", "Blue", "Purple"]
        case .lightroomReviewStatus: [
                "To Delete",
                "Color Correction Needed",
                "Good to Use",
                "Retouching Needed",
                "To Print",
            ]
        case .bridge: ["Select", "Second", "Approved", "Review", "To Do"]
        }
    }

    public func name(for label: ColorLabel) -> String {
        names[ColorLabel.allCases.firstIndex(of: label) ?? 0]
    }

    /// The colour a label's name stands for in any of the sets, ignoring case; nil for a name none
    /// of them has, which is a custom label.
    public static func label(named name: String) -> ColorLabel? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for set in allCases {
            if let index = set.names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return ColorLabel.allCases[index]
            }
        }
        return nil
    }
}

/// How Redlamp's labels go into XMP, and come out of it.
public struct XMPConventions: Sendable, Hashable, Codable {
    /// The set `xmp:Label` is written in. Labels are read in every set.
    public var labels: XMPLabelNames
    /// Labels are also read from and written to `photoshop:Urgency` as Photo Mechanic numbers its
    /// colour classes, which Capture One links to its colour tags. Off by default: Urgency is also
    /// IPTC's editorial priority, which a photo can carry without a label.
    public var urgency: Bool

    public init(labels: XMPLabelNames = .lightroom, urgency: Bool = false) {
        self.labels = labels
        self.urgency = urgency
    }
}

/// `photoshop:Urgency` as a label: Photo Mechanic's colour classes 1 to 8 (Winner, Winner alt,
/// Superior, Superior alt, Typical, Typical alt, Extras and Trash), whose default colours are
/// purple, red, orange, yellow, green, blue, light blue and grey. Orange, light blue and grey have
/// no label in Redlamp.
enum XMPUrgency {
    private static let classes: [ColorLabel: Int] = [.purple: 1, .red: 2, .yellow: 4, .green: 5, .blue: 6]

    static func value(for label: ColorLabel) -> Int {
        classes[label] ?? 0
    }

    static func label(for urgency: Int) -> ColorLabel? {
        classes.first { $0.value == urgency }?.key
    }
}

/// The namespaces of the properties Redlamp reads and writes, and the prefixes it declares them
/// with.
enum XMPNamespace {
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
    static let lightroom = "http://ns.adobe.com/lightroom/1.0/"
    static let dynamicMedia = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"
    static let darktable = "http://darktable.sf.net/"
    static let iptcCore = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"

    static let prefixes = [
        xmp: "xmp", dc: "dc", photoshop: "photoshop", lightroom: "lr", dynamicMedia: "xmpDM", darktable: "darktable",
        iptcCore: "Iptc4xmpCore",
    ]

    static let rating = XMPProperty(xmp, "Rating")
    static let label = XMPProperty(xmp, "Label")
    /// The label's colour, which Lightroom Classic writes beside `xmp:Label` since 15.0: `red`.
    static let labelColor = XMPProperty(xmp, "LabelColor")
    static let metadataDate = XMPProperty(xmp, "MetadataDate")
    static let urgency = XMPProperty(photoshop, "Urgency")
    /// Lightroom's pick flag: `True`.
    static let good = XMPProperty(dynamicMedia, "good")
    static let subject = XMPProperty(dc, "subject")
    static let hierarchicalSubject = XMPProperty(lightroom, "hierarchicalSubject")
    static let title = XMPProperty(dc, "title")
    static let description = XMPProperty(dc, "description")
    /// The creators, a sequence of names.
    static let creator = XMPProperty(dc, "creator")
    /// The copyright notice, a language alternative.
    static let rights = XMPProperty(dc, "rights")
    /// IPTC Core's sublocation: a place within the city.
    static let sublocation = XMPProperty(iptcCore, "Location")
    static let city = XMPProperty(photoshop, "City")
    static let state = XMPProperty(photoshop, "State")
    static let country = XMPProperty(photoshop, "Country")
    static let countryCode = XMPProperty(iptcCore, "CountryCode")
    /// darktable's colour labels, a sequence of 0 (red) to 4 (purple).
    static let colorLabels = XMPProperty(darktable, "colorlabels")
}
