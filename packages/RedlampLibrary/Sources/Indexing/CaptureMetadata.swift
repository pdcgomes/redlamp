import Foundation
import RedlampDocument
import RedlampEngineAPI

/// What the library indexes from a photo's file: the camera's capture settings, and what other apps
/// leave for organising photos (ratings, labels, keywords, titles, captions, creators, copyrights and
/// places), from its EXIF, GPS, IPTC and XMP or another app's `.xmp` sidecar.
public struct CaptureMetadata: Sendable, Hashable, Codable {
    /// Where the photo was taken, in IPTC's fields, as the sidecar holds it.
    public typealias Location = PhotoLocation

    /// As the file writes them: "NIKON CORPORATION", "NIKON Z 6".
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Double?
    public var aperture: Double?
    /// The exposure time, in seconds.
    public var shutter: Double?
    /// In millimetres, as the lens reports it rather than its 35 mm equivalent.
    public var focalLength: Double?
    /// The widest f-number the lens had at `focalLength` (`LensOptics.widestAperture`).
    public var widestAperture: Double?
    /// The focal length in 35 mm terms, in whole millimetres (`LensOptics.focal35`).
    public var focal35: Double?
    /// When the photo was taken by the camera's clock: the time it showed, read as if it were UTC. The
    /// library sorts and filters by that wall-clock time, which every camera records, rather than by
    /// the moment, which needs a zone most files leave out; the moment is `captured` minus
    /// `capturedOffset` when the camera recorded its zone.
    public var captured: Date?
    /// The camera's offset from UTC, in seconds, from EXIF's OffsetTimeOriginal; nil when the file
    /// doesn't say, and the camera's zone is unknown.
    public var capturedOffset: Int?
    /// The image's size once its orientation is applied.
    public var pixelSize: PixelSize?
    /// EXIF's orientation, 1 to 8.
    public var orientation: Int?
    /// In degrees, north positive.
    public var latitude: Double?
    /// In degrees, east positive.
    public var longitude: Double?
    /// 1 to 5 stars, or -1 for a photo marked rejected, as Bridge writes it (xmp:Rating).
    public var rating: Int?
    /// A colour label's name, "Red", whichever app's name for it the file has; or a custom label's.
    public var label: String?
    /// Each keyword as its path from the top of its hierarchy: "Places/Portugal/Lisbon", with a slash
    /// inside a name as `%2F` (`KeywordPath`).
    public var keywords: [String]
    public var title: String?
    public var caption: String?
    /// The photo's creators, separated by semicolons.
    public var creator: String?
    public var copyright: String?
    public var location: Location?
    /// The rating, flag, label, keywords, title and caption as `LibraryXMP` reads them, and which of
    /// them the file has at all (`XMPSource`); nil when it has none. `rating` to `caption` are these,
    /// for file names.
    public var xmp: XMPSource?

    public init(
        make: String? = nil, model: String? = nil, lens: String? = nil, iso: Double? = nil, aperture: Double? = nil,
        shutter: Double? = nil, focalLength: Double? = nil, captured: Date? = nil, capturedOffset: Int? = nil,
        pixelSize: PixelSize? = nil, orientation: Int? = nil, latitude: Double? = nil, longitude: Double? = nil,
        rating: Int? = nil, label: String? = nil, keywords: [String] = [], title: String? = nil,
        caption: String? = nil, creator: String? = nil, copyright: String? = nil, location: Location? = nil,
        xmp: XMPSource? = nil, widestAperture: Double? = nil, focal35: Double? = nil,
    ) {
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.focalLength = focalLength
        self.captured = captured
        self.capturedOffset = capturedOffset
        self.pixelSize = pixelSize
        self.orientation = orientation
        self.latitude = latitude
        self.longitude = longitude
        self.rating = rating
        self.label = label
        self.keywords = keywords
        self.title = title
        self.caption = caption
        self.creator = creator
        self.copyright = copyright
        self.location = location
        self.xmp = xmp
        self.widestAperture = widestAperture
        self.focal35 = focal35
    }

    /// The camera's name to show and group by, like `ImageInfo.cameraName` for a decoded raw: the maker
    /// as people write it, then the model without the maker's name repeated ("Nikon Z 6" from
    /// "NIKON CORPORATION" and "NIKON Z 6", "Sony ILCE-7M3", "Canon EOS R6").
    public var cameraName: String? {
        let brand = make.map(Self.brand).flatMap { $0.isEmpty ? nil : $0 }
        guard let model else { return brand }
        guard let brand else { return model }
        if let prefix = model.range(of: brand, options: [.anchored, .caseInsensitive]) {
            return brand + model[prefix.upperBound...]
        }
        return model.localizedCaseInsensitiveContains(brand) ? model : "\(brand) \(model)"
    }

    /// A maker's name without the words of its company's ("RICOH IMAGING COMPANY, LTD." is Ricoh),
    /// and capitalised when the file shouts it or whispers it ("SONY", "samsung"); a short name in
    /// capitals is an acronym and stays ("DJI").
    static func brand(_ make: String) -> String {
        var words = make.split { $0 == " " || $0 == "," }
        while words.count > 1, let last = words.last,
              companyWords.contains(last.trimmingCharacters(in: .punctuationCharacters).uppercased()) {
            words.removeLast()
        }
        return words.map { word in
            (word.count > 3 && word == word.uppercased()) || word == word.lowercased() ? word.capitalized : String(word)
        }.joined(separator: " ")
    }

    private static let companyWords: Set<String> = [
        "AG", "CAMERA", "CO", "COMPANY", "CORP", "CORPORATION", "GMBH", "IMAGING", "INC", "LIMITED", "LTD", "OPTICAL",
    ]
}
