import Foundation

// Coded by hand so fields a newer Redlamp wrote come back out unchanged. Every stored
// property must be decoded and encoded here, under the key and with the optionality
// synthesized coding gave it: a property added to the type but not here is lost on the next
// save (HandCodedTypeTests catches it).

public extension ExposureAnchor {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case stops, source, camera
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stops = try container.decode(Double.self, forKey: .stops)
        source = try container.decode(Source.self, forKey: .source)
        camera = try container.decodeIfPresent(String.self, forKey: .camera)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stops, forKey: .stops)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(camera, forKey: .camera)
    }
}

public extension AppliedRecipe {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, version, name, amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(Int.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        amount = try container.decode(Double.self, forKey: .amount)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(amount, forKey: .amount)
    }
}
