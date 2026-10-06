import Foundation
import RedlampEngineAPI

extension Snapshot: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, created, recipe
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        created = try container.decode(Date.self, forKey: .created)
        recipe = try container.decode(EditRecipe.self, forKey: .recipe)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(created, forKey: .created)
        try container.encode(recipe, forKey: .recipe)
    }
}

extension PhotoMetadata: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rating, flag, label, customLabel, mark, originalName, keywords, title, caption, creator, copyright
        case location, collections, stack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rating = try container.decode(Int.self, forKey: .rating)
        flag = try container.decodeIfPresent(PhotoFlag.self, forKey: .flag)
        label = try container.decodeIfPresent(ColorLabel.self, forKey: .label)
        customLabel = try container.decodeIfPresent(String.self, forKey: .customLabel)
        mark = try container.decodeIfPresent(Bool.self, forKey: .mark) ?? false
        originalName = try container.decodeIfPresent(String.self, forKey: .originalName)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        location = try container.decodeIfPresent(PhotoLocation.self, forKey: .location)
        collections = try container.decodeIfPresent([String].self, forKey: .collections) ?? []
        stack = try container.decodeIfPresent(PhotoStack.self, forKey: .stack)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    /// Writes each field only when it's set: `mark` only when true and `collections` only when there
    /// are some, so metadata older builds wrote is written back as it was.
    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rating, forKey: .rating)
        try container.encodeIfPresent(flag, forKey: .flag)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(customLabel, forKey: .customLabel)
        if mark {
            try container.encode(true, forKey: .mark)
        }
        try container.encodeIfPresent(originalName, forKey: .originalName)
        try container.encodeIfPresent(keywords, forKey: .keywords)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(caption, forKey: .caption)
        try container.encodeIfPresent(creator, forKey: .creator)
        try container.encodeIfPresent(copyright, forKey: .copyright)
        try container.encodeIfPresent(location, forKey: .location)
        if !collections.isEmpty {
            try container.encode(collections, forKey: .collections)
        }
        try container.encodeIfPresent(stack, forKey: .stack)
    }
}

extension PhotoLocation: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case country, state, city, sublocation, countryCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        sublocation = try container.decodeIfPresent(String.self, forKey: .sublocation)
        countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(country, forKey: .country)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(city, forKey: .city)
        try container.encodeIfPresent(sublocation, forKey: .sublocation)
        try container.encodeIfPresent(countryCode, forKey: .countryCode)
    }
}

extension PhotoStack: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, top
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        top = try container.decodeIfPresent(Bool.self, forKey: .top) ?? false
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    /// Leaves out `top` when it's false, as the sidecar leaves out defaults.
    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        if top {
            try container.encode(true, forKey: .top)
        }
    }
}
