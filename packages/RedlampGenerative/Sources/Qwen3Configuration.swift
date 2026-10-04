import Foundation

/// The shape of a Qwen3 language model, as its `config.json` gives it: FLUX.2 [klein] 4B's text
/// encoder is Qwen3-4B.
public struct Qwen3Configuration: Decodable, Sendable, Equatable {
    public var hiddenSize: Int
    public var intermediateSize: Int
    public var layers: Int
    public var heads: Int
    public var keyValueHeads: Int
    public var headDimension: Int
    public var vocabularySize: Int
    public var normEpsilon: Float
    public var ropeTheta: Float

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case layers = "num_hidden_layers"
        case heads = "num_attention_heads"
        case keyValueHeads = "num_key_value_heads"
        case headDimension = "head_dim"
        case vocabularySize = "vocab_size"
        case normEpsilon = "rms_norm_eps"
        case ropeTheta = "rope_theta"
    }

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
