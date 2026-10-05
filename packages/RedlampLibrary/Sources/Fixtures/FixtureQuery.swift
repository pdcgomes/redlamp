import Foundation
import RedlampDocument

/// A query in the library's language (docs/plans/2026-10-05-library-design.md, The query
/// language) and which of a fixture's photos it must return.
///
/// The fields read as the library reads them: a photo's rating, flag and label are its
/// `.redlamp` sidecar's, else its other app's `.xmp`'s (no photo has both); its keywords are its
/// IPTC keywords and its `.xmp`'s; `date` is the EXIF capture date as written; text, `camera`,
/// `lens`, `name` and `in` match substrings, ignoring case, and `in` matches the folder's path
/// below the fixture's root (no query's value is in the path of the root itself).
public struct FixtureQuery: Sendable {
    public let text: String
    public let matches: @Sendable (FixturePhoto) -> Bool

    public init(_ text: String, _ matches: @escaping @Sendable (FixturePhoto) -> Bool) {
        self.text = text
        self.matches = matches
    }

    /// The queries every manifest counts, each typed a character at a time by the search scenarios.
    public static let corpus: [FixtureQuery] = [
        FixtureQuery("rating>=3") { $0.rating >= 3 },
        FixtureQuery("rating:5") { $0.rating == 5 },
        FixtureQuery("rating:0") { $0.rating == 0 },
        FixtureQuery("flag:pick") { $0.flag == .pick },
        FixtureQuery("flag:reject") { $0.flag == .reject },
        FixtureQuery("-flag:reject") { $0.flag != .reject },
        FixtureQuery("label:red") { $0.label == .red },
        FixtureQuery("label:red,blue") { $0.label == .red || $0.label == .blue },
        FixtureQuery("label:none") { $0.label == nil },
        FixtureQuery("edited:yes") { $0.isEdited },
        FixtureQuery("camera:\"X-T5\"") { includes($0.camera, "X-T5") },
        FixtureQuery("camera:\"EOS R5\"") { includes($0.camera, "EOS R5") },
        FixtureQuery("camera:iPhone") { includes($0.camera, "iPhone") },
        FixtureQuery("lens:35") { includes($0.lens, "35") },
        FixtureQuery("iso<=800") { ($0.iso ?? .max) <= 800 },
        FixtureQuery("iso>=3200") { ($0.iso ?? 0) >= 3200 },
        FixtureQuery("f:1.4..2.8") { $0.aperture.map { (1.4 ... 2.8).contains($0) } ?? false },
        FixtureQuery("focal:24..70") { $0.focalLength.map { (24 ... 70).contains($0) } ?? false },
        FixtureQuery("shutter>=1") { ($0.exposureTime ?? 0) >= 1 },
        FixtureQuery("date:2019") { $0.captured.year == 2019 },
        FixtureQuery("date:2019-06..2019-08") { $0.captured.year == 2019 && (6 ... 8).contains($0.captured.month) },
        FixtureQuery("date:2015-07") { $0.captured.year == 2015 && $0.captured.month == 7 },
        FixtureQuery("has:gps") { $0.location != nil },
        FixtureQuery("-has:gps") { $0.location == nil },
        FixtureQuery("has:keywords") { !$0.keywords.isEmpty },
        FixtureQuery("has:caption") { $0.caption != nil },
        FixtureQuery("kw:birds") { $0.keywords.contains("birds") },
        FixtureQuery("kw:sunset") { $0.keywords.contains("sunset") },
        FixtureQuery("type:raw") { $0.kind == .raw },
        FixtureQuery("type:heic") { $0.kind == .heic },
        FixtureQuery("type:jpeg") { $0.kind == .jpeg },
        FixtureQuery("in:\"Clients\"") { includes($0.folder, "Clients") },
        FixtureQuery("in:\"Card Dump\"") { includes($0.folder, "Card Dump") },
        FixtureQuery("name:DSCF") { includes($0.name, "DSCF") },
        FixtureQuery("sunset") { photo in
            [photo.name, photo.folder, photo.caption, photo.camera, photo.lens].contains { includes($0, "sunset") }
                || photo.keywords.contains { includes($0, "sunset") }
        },
        FixtureQuery("rating>=3 flag:pick") { $0.rating >= 3 && $0.flag == .pick },
        FixtureQuery("camera:\"X-T5\" iso<=800") { includes($0.camera, "X-T5") && ($0.iso ?? .max) <= 800 },
        FixtureQuery("date:2019 has:gps") { $0.captured.year == 2019 && $0.location != nil },
        FixtureQuery("type:raw -flag:reject") { $0.kind == .raw && $0.flag != .reject },
        FixtureQuery("label:red OR label:blue") { $0.label == .red || $0.label == .blue },
        FixtureQuery("(rating>=4 OR flag:pick) -label:none") { ($0.rating >= 4 || $0.flag == .pick) && $0.label != nil
        },
        FixtureQuery("kw:birds has:gps") { $0.keywords.contains("birds") && $0.location != nil },
        FixtureQuery("in:\"Clients\" rating>=3") { includes($0.folder, "Clients") && $0.rating >= 3 },
    ]

    private static func includes(_ text: String?, _ part: String) -> Bool {
        text?.range(of: part, options: .caseInsensitive) != nil
    }
}
