import Foundation
import MLX
import Testing
@testable import RedlampGenerative

/// FLUX.2 [klein] 4B's diffusers folder (`REDLAMP_FLUX_MODEL`) and the reference prompt embeddings
/// made from it with transformers (`REDLAMP_FLUX_REFERENCE`, by
/// `research/prototypes/generative/reference_text_encoder.py`). Through xcodebuild, each is set as
/// `TEST_RUNNER_` and its name.
enum FluxSample {
    struct Prompt {
        let prompt: String
        let file: URL
        let tokens: Int
    }

    static let model = folder("REDLAMP_FLUX_MODEL")
    static let reference = folder("REDLAMP_FLUX_REFERENCE")

    static let prompts: [Prompt] = {
        guard let reference, let data = try? Data(contentsOf: reference.appending(path: "index.json")),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let prompt = entry["prompt"] as? String, let file = entry["file"] as? String,
                  let tokens = entry["tokens"] as? Int else { return nil }
            return Prompt(prompt: prompt, file: reference.appending(path: file), tokens: tokens)
        }
    }()

    static func folder(_ name: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[name], !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// How far `embeddings` are from `reference`, each token's distance against its length: the
    /// median and the worst over the prompt's `count` tokens, and over the padding after them.
    /// Padding attends to the prompt from far off, so it's far more sensitive to precision: PyTorch's
    /// own bfloat16 puts the prompt's tokens about 1% (at worst 5%) from float32's, and padding
    /// 6 to 8% (at worst 76%).
    static func errors(
        _ embeddings: MLXArray, _ reference: MLXArray, count: Int,
    ) -> (prompt: (median: Float, worst: Float), padding: (median: Float, worst: Float)) {
        let difference = (embeddings.asType(.float32) - reference).square().sum(axis: -1).sqrt()
        let errors = (difference / reference.square().sum(axis: -1).sqrt()).asArray(Float.self)
        func spread(_ values: ArraySlice<Float>) -> (median: Float, worst: Float) {
            let sorted = values.sorted()
            return (sorted.isEmpty ? 0 : sorted[sorted.count / 2], sorted.last ?? 0)
        }
        return (spread(errors[..<count]), spread(errors[count...]))
    }
}

@Suite(.enabled(if: FluxSample.model != nil && !FluxSample.prompts.isEmpty), .serialized)
struct FluxTextEncoderTests {
    @Test func `prompts become the tokens Qwen's tokenizer makes`() throws {
        let tokenizer = try FluxTextEncoder.tokenizer(model: #require(FluxSample.model))
        for sample in FluxSample.prompts {
            let (ids, count) = try FluxTextEncoder.tokens(for: sample.prompt, tokenizer: tokenizer)
            let reference = try #require(loadArrays(url: sample.file)["input_ids"]).asArray(Int32.self)
            #expect(count == sample.tokens, "\(sample.prompt)")
            #expect(ids == reference, "\(sample.prompt)")
        }
    }

    @Test func `prompt embeddings are diffusers', computed in float32`() throws {
        let encoder = try FluxTextEncoder(model: #require(FluxSample.model), dtype: .float32)
        for sample in FluxSample.prompts {
            let reference = try #require(loadArrays(url: sample.file)["embeddings"])
            let embeddings = try encoder.embeddings(for: sample.prompt)
            #expect(embeddings.shape == [FluxTextEncoder.length, 7680])
            let (prompt, padding) = FluxSample.errors(embeddings, reference, count: sample.tokens)
            #expect(prompt.worst < 0.001 && padding.median < 0.001, "\(sample.prompt): \(prompt), padding \(padding)")
        }
    }

    @Test func `and in bfloat16, about as closely as PyTorch's own bfloat16`() throws {
        let encoder = try FluxTextEncoder(model: #require(FluxSample.model), dtype: .bfloat16)
        for sample in FluxSample.prompts {
            let reference = try #require(loadArrays(url: sample.file)["embeddings"])
            let embeddings = try encoder.embeddings(for: sample.prompt)
            let (prompt, padding) = FluxSample.errors(embeddings, reference, count: sample.tokens)
            #expect(prompt.median < 0.01 && prompt.worst < 0.05, "\(sample.prompt): \(prompt)")
            #expect(padding.median < 0.08, "\(sample.prompt), padding: \(padding)")
        }
    }
}
