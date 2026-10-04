import Foundation
import MLX

/// A Qwen3 language model's decoder layers run as an encoder: one pass over a whole padded prompt,
/// keeping the hidden states (the residual stream, before the final norm) after some of them.
/// Only the layers up to the last one asked for are loaded.
final class Qwen3Encoder {
    private struct Layer {
        let inputNorm: MLXArray
        let query: MLXArray
        let key: MLXArray
        let value: MLXArray
        let output: MLXArray
        let queryNorm: MLXArray
        let keyNorm: MLXArray
        let postNorm: MLXArray
        let gate: MLXArray
        let up: MLXArray
        let down: MLXArray
    }

    enum EncoderError: Error {
        case missingWeight(String)
    }

    let configuration: Qwen3Configuration
    let dtype: DType
    private let embeddings: MLXArray
    private let layers: [Layer]

    /// From a Hugging Face model folder: `config.json` and its safetensors shards.
    init(directory: URL, layers count: Int, dtype: DType) throws {
        configuration = try Qwen3Configuration(contentsOf: directory.appending(path: "config.json"))
        self.dtype = dtype
        var weights: [String: MLXArray] = [:]
        let shards = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        for shard in shards {
            try weights.merge(loadArrays(url: shard)) { $1 }
        }
        func weight(_ name: String) throws -> MLXArray {
            guard let array = weights[name] else { throw EncoderError.missingWeight(name) }
            return array.asType(dtype)
        }
        embeddings = try weight("model.embed_tokens.weight")
        layers = try (0 ..< min(count, configuration.layers)).map { index in
            let prefix = "model.layers.\(index)."
            return try Layer(
                inputNorm: weight(prefix + "input_layernorm.weight").asType(.float32),
                query: weight(prefix + "self_attn.q_proj.weight").T,
                key: weight(prefix + "self_attn.k_proj.weight").T,
                value: weight(prefix + "self_attn.v_proj.weight").T,
                output: weight(prefix + "self_attn.o_proj.weight").T,
                queryNorm: weight(prefix + "self_attn.q_norm.weight"),
                keyNorm: weight(prefix + "self_attn.k_norm.weight"),
                postNorm: weight(prefix + "post_attention_layernorm.weight").asType(.float32),
                gate: weight(prefix + "mlp.gate_proj.weight").T,
                up: weight(prefix + "mlp.up_proj.weight").T,
                down: weight(prefix + "mlp.down_proj.weight").T,
            )
        }
        eval(
            embeddings,
            layers.flatMap { [$0.inputNorm, $0.query, $0.key, $0.value, $0.output, $0.gate, $0.up, $0.down] },
        )
    }

    /// The hidden states after each of `outputs` layers (counted from 1), `[length, hidden]` each
    /// in float32, for `tokens`, of which the first `count` are the prompt and the rest padding. As
    /// in transformers, each position attends to the prompt's tokens up to itself, so padding
    /// attends to the whole prompt.
    func hiddenStates(tokens: [Int32], count: Int, after outputs: [Int]) -> [MLXArray] {
        let length = tokens.count
        let c = configuration
        var masked = [Float](repeating: -.infinity, count: length * length)
        for query in 0 ..< length {
            for key in 0 ..< min(query + 1, count) {
                masked[query * length + key] = 0
            }
        }
        let mask = MLXArray(masked, [length, length]).asType(dtype)
        let scale = 1 / Float(c.headDimension).squareRoot()
        func heads(_ projected: MLXArray, _ count: Int) -> MLXArray {
            projected.reshaped([1, length, count, c.headDimension])
        }
        // The residual stream stays in float32: summed in bfloat16, a prompt's tokens drift twice as
        // far from float32's as they do this way.
        var x = embeddings.take(MLXArray(tokens), axis: 0).expandedDimensions(axis: 0).asType(.float32)
        var states: [MLXArray] = []
        for (index, layer) in layers.enumerated() {
            let normed = MLXFast.rmsNorm(x, weight: layer.inputNorm, eps: c.normEpsilon).asType(dtype)
            var queries = MLXFast.rmsNorm(
                heads(matmul(normed, layer.query), c.heads), weight: layer.queryNorm, eps: c.normEpsilon,
            ).transposed(0, 2, 1, 3)
            var keys = MLXFast.rmsNorm(
                heads(matmul(normed, layer.key), c.keyValueHeads), weight: layer.keyNorm, eps: c.normEpsilon,
            ).transposed(0, 2, 1, 3)
            let values = heads(matmul(normed, layer.value), c.keyValueHeads).transposed(0, 2, 1, 3)
            queries = MLXFast.RoPE(
                queries, dimensions: c.headDimension, traditional: false, base: c.ropeTheta, scale: 1, offset: 0,
            )
            keys = MLXFast.RoPE(
                keys, dimensions: c.headDimension, traditional: false, base: c.ropeTheta, scale: 1, offset: 0,
            )
            let attended = MLXFast.scaledDotProductAttention(
                queries: queries, keys: keys, values: values, scale: scale, mask: .array(mask),
            ).transposed(0, 2, 1, 3).reshaped([1, length, c.heads * c.headDimension])
            x = x + matmul(attended, layer.output).asType(.float32)
            let normedAgain = MLXFast.rmsNorm(x, weight: layer.postNorm, eps: c.normEpsilon).asType(dtype)
            let gated = matmul(normedAgain, layer.gate)
            x = x + matmul(gated * sigmoid(gated) * matmul(normedAgain, layer.up), layer.down).asType(.float32)
            if outputs.contains(index + 1) {
                states.append(x[0])
            }
        }
        eval(states)
        return states
    }
}
