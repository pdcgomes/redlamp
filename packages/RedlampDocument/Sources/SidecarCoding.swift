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
        case rating, flag, label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rating = try container.decode(Int.self, forKey: .rating)
        flag = try container.decodeIfPresent(PhotoFlag.self, forKey: .flag)
        label = try container.decodeIfPresent(ColorLabel.self, forKey: .label)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rating, forKey: .rating)
        try container.encodeIfPresent(flag, forKey: .flag)
        try container.encodeIfPresent(label, forKey: .label)
    }
}
