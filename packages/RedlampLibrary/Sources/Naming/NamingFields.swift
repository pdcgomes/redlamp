import Foundation
import RedlampDocument

/// What a template can put in a photo's name. The caller fills it from the index, the photo's capture
/// metadata and its sidecar, so naming reads neither.
public struct NamingFields: Sendable, Hashable {
    /// The file's name as it is now, with its extension: `IMG_1234.CR3`.
    public var name: String
    /// The path of the folder the photo is in now.
    public var folder: String
    /// The file's name before Redlamp first renamed it, when the photo keeps it (LIB-26); nil when it
    /// hasn't been renamed.
    public var originalName: String?
    /// When the photo was taken by the camera's clock: the time it showed, read as if it were UTC, to
    /// the microsecond, as `CaptureMetadata.captured` holds it, with the shift its sidecar gives it.
    public var captured: Date?
    /// The camera's offset from UTC, in seconds east, when it recorded one or the caller assumes one.
    public var capturedOffset: Int?
    public var modified: Date?
    /// The camera as the library names it: "Nikon Z 6".
    public var camera: String?
    /// The camera's maker as people write it: "Nikon".
    public var make: String?
    /// The camera's model without its maker: "Z 6".
    public var model: String?
    public var lens: String?
    public var iso: Double?
    public var aperture: Double?
    /// In seconds.
    public var shutter: Double?
    /// In millimetres, as the lens reports it.
    public var focalLength: Double?
    /// Once the photo is turned upright.
    public var width: Int?
    public var height: Int?
    /// 0 to 5 stars.
    public var rating: Int
    public var flag: PhotoFlag?
    /// A colour label's name, "Red", or a custom label's.
    public var label: String?
    public var title: String?
    public var caption: String?
    public var creator: String?
    public var copyright: String?
    public var location: CaptureMetadata.Location?
    /// Each keyword by its path: "Places/Portugal/Lisbon".
    public var keywords: [String]

    public init(
        name: String, folder: String, originalName: String? = nil, captured: Date? = nil, capturedOffset: Int? = nil,
        modified: Date? = nil, camera: String? = nil, make: String? = nil, model: String? = nil, lens: String? = nil,
        iso: Double? = nil, aperture: Double? = nil, shutter: Double? = nil, focalLength: Double? = nil,
        width: Int? = nil, height: Int? = nil, rating: Int = 0, flag: PhotoFlag? = nil, label: String? = nil,
        title: String? = nil, caption: String? = nil, creator: String? = nil, copyright: String? = nil,
        location: CaptureMetadata.Location? = nil, keywords: [String] = [],
    ) {
        self.name = name
        self.folder = folder
        self.originalName = originalName
        self.captured = captured
        self.capturedOffset = capturedOffset
        self.modified = modified
        self.camera = camera
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.focalLength = focalLength
        self.width = width
        self.height = height
        self.rating = rating
        self.flag = flag
        self.label = label
        self.title = title
        self.caption = caption
        self.creator = creator
        self.copyright = copyright
        self.location = location
        self.keywords = keywords
    }

    /// A photo's fields from what its file says.
    public init(name: String, folder: String, metadata: CaptureMetadata, modified: Date? = nil) {
        let (make, model) = Self.makeAndModel(make: metadata.make, model: metadata.model)
        self.init(
            name: name, folder: folder, captured: metadata.captured, capturedOffset: metadata.capturedOffset,
            modified: modified, camera: metadata.cameraName, make: make, model: model, lens: metadata.lens,
            iso: metadata.iso, aperture: metadata.aperture, shutter: metadata.shutter,
            focalLength: metadata.focalLength, width: metadata.pixelSize?.width, height: metadata.pixelSize?.height,
            rating: min(max(metadata.rating ?? 0, 0), 5), label: metadata.label, title: metadata.title,
            caption: metadata.caption, creator: metadata.creator, copyright: metadata.copyright,
            location: metadata.location, keywords: metadata.keywords,
        )
    }

    /// A photo's fields as the index holds them, in `folder` (its path), with its camera's maker and
    /// model as the file wrote them: its organising fields merged from its `.redlamp` and other apps'.
    public init(
        photo: PhotoRecord, folder: String, camera: String?, cameraMake: String? = nil, cameraModel: String? = nil,
        lens: String?, keywords: [String] = [],
    ) {
        let (make, model) = Self.makeAndModel(make: cameraMake, model: cameraModel)
        self.init(
            name: photo.name, folder: folder, captured: photo.captured, capturedOffset: photo.capturedOffset,
            modified: photo.modified, camera: camera, make: make, model: model, lens: lens, iso: photo.iso,
            aperture: photo.aperture, shutter: photo.shutter, focalLength: photo.focal, width: photo.width,
            height: photo.height, rating: photo.rating, flag: photo.flag,
            label: photo.label.map(Self.labelName) ?? photo.customLabel, title: photo.title, caption: photo.caption,
            creator: photo.creator, copyright: photo.copyright, location: photo.location, keywords: keywords,
        )
    }

    /// Takes the rating, flag and label a photo's `.redlamp` sidecar holds, IPTC Core's fields where it
    /// holds them, an empty one as none, and the shift and zone it gives the capture time the file
    /// records.
    public mutating func apply(_ sidecar: PhotoMetadata) {
        if let captured {
            self.captured = captured.addingTimeInterval(TimeInterval(sidecar.captureShift))
            capturedOffset = sidecar.captureOffset ?? capturedOffset
        }
        rating = sidecar.rating
        flag = sidecar.flag
        label = sidecar.label.map(Self.labelName) ?? sidecar.customLabel
        for (field, value) in [
            (\NamingFields.title, sidecar.title), (\.caption, sidecar.caption), (\.creator, sidecar.creator),
            (\.copyright, sidecar.copyright),
        ] where value != nil {
            self[keyPath: field] = XMPFields.text(value)
        }
        if let location = sidecar.location {
            self.location = XMPFields.place(location)
        }
    }

    /// "Red", as Lightroom writes a label's text.
    public static func labelName(_ label: ColorLabel) -> String {
        label.rawValue.prefix(1).uppercased() + label.rawValue.dropFirst()
    }

    /// The maker as people write it, and the model without the maker's name: "Nikon" and "Z 6" from
    /// "NIKON CORPORATION" and "NIKON Z 6".
    static func makeAndModel(make: String?, model: String?) -> (make: String?, model: String?) {
        let brand = make.map(CaptureMetadata.brand).flatMap { $0.isEmpty ? nil : $0 }
        guard let model, let brand,
              let prefix = model.range(of: brand, options: [.anchored, .caseInsensitive]),
              prefix.upperBound == model.endIndex || model[prefix.upperBound] == " "
        else { return (brand, model) }
        let rest = model[prefix.upperBound...].trimmingCharacters(in: .whitespaces)
        return (brand, rest.isEmpty ? model : rest)
    }
}
