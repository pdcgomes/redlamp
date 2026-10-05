import Foundation

/// A saved naming template and its options. Lightroom Classic's file naming templates come built in,
/// in Redlamp's grammar and under their names, for photographers who know them, beside Redlamp's own.
public struct NamingPreset: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var template: NamingTemplate
    public var options: NamingOptions

    public init(
        id: String = UUID().uuidString,
        name: String,
        template: NamingTemplate,
        options: NamingOptions = NamingOptions(),
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, template, options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id), name: container.decode(String.self, forKey: .name),
            template: container.decode(NamingTemplate.self, forKey: .template),
            options: container.decodeIfPresent(NamingOptions.self, forKey: .options) ?? NamingOptions(),
        )
    }

    /// Lightroom Classic's templates, in the order its menu lists them. Its Custom Text and Shoot
    /// Name are the job's texts `{text}` and `{text:shoot}`, its Sequence # `{sequence}`, its Total #
    /// `{total}`, its Original number suffix `{number}` and its Date (YYYYMMDD) `{date:yyyyMMdd}`.
    public static let lightroom: [NamingPreset] = [
        builtIn("lightroom-custom-name-sequence", "Custom Name - Sequence", "{text}-{sequence}"),
        builtIn("lightroom-custom-name", "Custom Name", "{text}"),
        builtIn("lightroom-custom-name-x-of-y", "Custom Name (x of y)", "{text} ({sequence} of {total})"),
        builtIn("lightroom-custom-name-original-number", "Custom Name - Original File Number", "{text}-{number}"),
        builtIn("lightroom-date-filename", "Date - Filename", "{date:yyyyMMdd}-{name}"),
        builtIn("lightroom-filename", "Filename", "{name}"),
        builtIn("lightroom-filename-sequence", "Filename - Sequence", "{name}-{sequence}"),
        builtIn("lightroom-shoot-name-original-number", "Shoot Name - Original File Number", "{text:shoot}-{number}"),
        builtIn("lightroom-shoot-name-sequence", "Shoot Name - Sequence", "{text:shoot}-{sequence}"),
    ]

    /// What Lightroom's templates can't do: the time to the millisecond, for bursts; a counter that
    /// carries on from one shoot to the next; a sequence in each folder.
    public static let redlamp: [NamingPreset] = [
        builtIn("redlamp-capture-time", "Capture Time to the Millisecond", "{date:yyyyMMdd-HHmmss-SSS}"),
        builtIn("redlamp-shoot-counter", "Shoot Name - Counter", "{text:shoot}-{counter:shoot:5}"),
        builtIn(
            "redlamp-date-folder-sequence",
            "Date - Folder - Sequence",
            "{date:yyyy-MM-dd}-{folder}-{sequence:4:folder}",
        ),
    ]

    public static let builtIn = lightroom + redlamp

    private static func builtIn(_ id: String, _ name: String, _ template: String) -> NamingPreset {
        NamingPreset(id: id, name: name, template: try! NamingTemplate(parsing: template))
    }
}
