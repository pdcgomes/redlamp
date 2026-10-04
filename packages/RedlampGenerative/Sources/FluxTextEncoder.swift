import Foundation
import MLX

/// FLUX.2 [klein] 4B's prompt embeddings, as diffusers' Flux2Klein pipelines make them
/// (`_get_qwen3_prompt_embeds`): the prompt in Qwen's chat template without thinking, padded with
/// `<|endoftext|>` to 512 tokens, through Qwen3-4B, with the hidden states after layers 9, 18 and
/// 27 side by side for each token.
public final class FluxTextEncoder {
    public static let length = 512
    public static let layers = [9, 18, 27]

    public let tokenizer: QwenTokenizer
    private let encoder: Qwen3Encoder

    public enum TextEncoderError: Error {
        case noPaddingToken
    }

    /// From the model's diffusers folder (`tokenizer/`, `text_encoder/`), computing in `dtype`.
    public init(model directory: URL, dtype: DType = .bfloat16) throws {
        tokenizer = try Self.tokenizer(model: directory)
        encoder = try Qwen3Encoder(
            directory: directory.appending(path: "text_encoder"), layers: Self.layers.max() ?? 0, dtype: dtype,
        )
    }

    public static func tokenizer(model directory: URL) throws -> QwenTokenizer {
        try QwenTokenizer(contentsOf: directory.appending(path: "tokenizer/tokenizer.json"))
    }

    /// The prompt's tokens, padded to `length`, and how many of them are the prompt's.
    public static func tokens(for prompt: String, tokenizer: QwenTokenizer) throws -> (ids: [Int32], count: Int) {
        guard let padding = tokenizer.addedToken("<|endoftext|>") else { throw TextEncoderError.noPaddingToken }
        let text = "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let ids = Array(tokenizer.encode(text).prefix(length))
        return (ids + [Int32](repeating: padding, count: length - ids.count), ids.count)
    }

    /// `[length, 3 × hidden]`, in float32.
    public func embeddings(for prompt: String) throws -> MLXArray {
        let (ids, count) = try Self.tokens(for: prompt, tokenizer: tokenizer)
        return concatenated(encoder.hiddenStates(tokens: ids, count: count, after: Self.layers), axis: -1)
    }
}
