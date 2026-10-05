import Foundation
import MLX

/// FLUX.2 [klein]'s transformer, as diffusers' `Flux2Transformer2DModel`: double-stream blocks over
/// the prompt's and the image's tokens side by side, then single-stream blocks over them joined,
/// each modulated by the timestep, with rotary positions on four axes (time, row, column, layer).
/// One image at a time.
public final class Flux2Transformer {
    struct Configuration: Decodable {
        let headDimension: Int
        let ropeAxes: [Int]
        let inChannels: Int
        let contextDimension: Int
        let mlpRatio: Double
        let heads: Int
        let doubleLayers: Int
        let singleLayers: Int
        let ropeTheta: Double
        let timestepChannels: Int
        let eps: Float
        /// Set when the folder's weights are already quantised (Redlamp's download).
        let quantization: Quantization?

        struct Quantization: Decodable {
            let bits: Int
            let groupSize: Int

            enum CodingKeys: String, CodingKey {
                case bits
                case groupSize = "group_size"
            }
        }

        enum CodingKeys: String, CodingKey {
            case headDimension = "attention_head_dim"
            case ropeAxes = "axes_dims_rope"
            case inChannels = "in_channels"
            case contextDimension = "joint_attention_dim"
            case mlpRatio = "mlp_ratio"
            case heads = "num_attention_heads"
            case doubleLayers = "num_layers"
            case singleLayers = "num_single_layers"
            case ropeTheta = "rope_theta"
            case timestepChannels = "timestep_guidance_channels"
            case eps
            case quantization
        }

        var width: Int {
            heads * headDimension
        }
    }

    private struct DoubleBlock {
        let query, key, value, output: Linear
        let contextQuery, contextKey, contextValue, contextOutput: Linear
        let queryNorm, keyNorm, contextQueryNorm, contextKeyNorm: MLXArray
        let feedIn, feedOut, contextFeedIn, contextFeedOut: Linear
    }

    private struct SingleBlock {
        let projection: Linear
        let queryNorm, keyNorm: MLXArray
        let output: Linear
    }

    let configuration: Configuration
    let dtype: DType
    private let imageEmbedder, contextEmbedder: Linear
    private let timeIn, timeOut: Linear
    private let doubleImageModulation, doubleTextModulation, singleModulation: Linear
    private let doubleBlocks: [DoubleBlock]
    private let singleBlocks: [SingleBlock]
    private let normOut, projectionOut: Linear

    /// From the model's `transformer/` folder, computing in `dtype`, with the blocks' and the
    /// modulations' weights quantised when `quantization` is given or the folder's already are.
    public init(directory: URL, dtype: DType = .bfloat16, quantization: WeightQuantization? = nil) throws {
        configuration = try JSONDecoder().decode(
            Configuration.self, from: Data(contentsOf: directory.appending(path: "config.json")),
        )
        self.dtype = dtype
        let quantization = quantization ?? configuration.quantization.map {
            WeightQuantization(bits: $0.bits, groupSize: $0.groupSize)
        }
        let weights = try Weights(directory: directory)
        func linear(_ name: String, quantized: Bool = true) throws -> Linear {
            try Linear(weights, name, dtype: dtype, quantization: quantized ? quantization : nil)
        }
        func norm(_ name: String) throws -> MLXArray {
            try weights(name, dtype)
        }
        imageEmbedder = try linear("x_embedder", quantized: false)
        contextEmbedder = try linear("context_embedder")
        timeIn = try linear("time_guidance_embed.timestep_embedder.linear_1", quantized: false)
        timeOut = try linear("time_guidance_embed.timestep_embedder.linear_2", quantized: false)
        doubleImageModulation = try linear("double_stream_modulation_img.linear")
        doubleTextModulation = try linear("double_stream_modulation_txt.linear")
        singleModulation = try linear("single_stream_modulation.linear")
        doubleBlocks = try (0 ..< configuration.doubleLayers).map { index in
            let prefix = "transformer_blocks.\(index)."
            return try DoubleBlock(
                query: linear(prefix + "attn.to_q"),
                key: linear(prefix + "attn.to_k"),
                value: linear(prefix + "attn.to_v"),
                output: linear(prefix + "attn.to_out.0"),
                contextQuery: linear(prefix + "attn.add_q_proj"),
                contextKey: linear(prefix + "attn.add_k_proj"),
                contextValue: linear(prefix + "attn.add_v_proj"),
                contextOutput: linear(prefix + "attn.to_add_out"),
                queryNorm: norm(prefix + "attn.norm_q.weight"),
                keyNorm: norm(prefix + "attn.norm_k.weight"),
                contextQueryNorm: norm(prefix + "attn.norm_added_q.weight"),
                contextKeyNorm: norm(prefix + "attn.norm_added_k.weight"),
                feedIn: linear(prefix + "ff.linear_in"),
                feedOut: linear(prefix + "ff.linear_out"),
                contextFeedIn: linear(prefix + "ff_context.linear_in"),
                contextFeedOut: linear(prefix + "ff_context.linear_out"),
            )
        }
        singleBlocks = try (0 ..< configuration.singleLayers).map { index in
            let prefix = "single_transformer_blocks.\(index).attn."
            return try SingleBlock(
                projection: linear(prefix + "to_qkv_mlp_proj"),
                queryNorm: norm(prefix + "norm_q.weight"),
                keyNorm: norm(prefix + "norm_k.weight"),
                output: linear(prefix + "to_out"),
            )
        }
        normOut = try linear("norm_out.linear", quantized: false)
        projectionOut = try linear("proj_out", quantized: false)
        var held = [
            imageEmbedder,
            contextEmbedder,
            timeIn,
            timeOut,
            doubleImageModulation,
            doubleTextModulation,
            singleModulation,
            normOut,
            projectionOut,
        ].flatMap(\.arrays)
        for block in doubleBlocks {
            held += [
                block.query,
                block.key,
                block.value,
                block.output,
                block.contextQuery,
                block.contextKey,
                block.contextValue,
                block.contextOutput,
                block.feedIn,
                block.feedOut,
                block.contextFeedIn,
                block.contextFeedOut,
            ].flatMap(\.arrays)
        }
        for block in singleBlocks {
            held += block.projection.arrays + block.output.arrays
        }
        eval(held)
    }

    /// The velocity for `image`'s first `outputs` tokens, given all of them `[n, in channels]` (the
    /// noisy latents, then any reference latents), at `timestep` (0 to 1), with the prompt's
    /// embeddings `context` `[l, context dimension]` and each token's position on the four axes
    /// (`imageIDs` `[n, 4]`, `textIDs` `[l, 4]`). In float32.
    public func velocity(
        image: MLXArray, context: MLXArray, imageIDs: MLXArray, textIDs: MLXArray, timestep: Float,
        outputs: Int? = nil,
    ) -> MLXArray {
        let c = configuration
        let textCount = context.dim(0)
        let time = timeOut(silu(timeIn(timestepEmbedding(timestep * 1000).asType(dtype)))).asType(.float32)
        let modulationInput = silu(time).asType(dtype)
        let doubleImage = split(doubleImageModulation(modulationInput).asType(.float32), parts: 6, axis: -1)
        let doubleText = split(doubleTextModulation(modulationInput).asType(.float32), parts: 6, axis: -1)
        let single = split(singleModulation(modulationInput).asType(.float32), parts: 3, axis: -1)
        let (cosines, sines) = rotaryEmbedding(concatenated([textIDs, imageIDs], axis: 0))

        var x = imageEmbedder(image.asType(dtype)).asType(.float32)
        var text = contextEmbedder(context.asType(dtype)).asType(.float32)
        for block in doubleBlocks {
            let normed = modulate(x, shift: doubleImage[0], scale: doubleImage[1])
            let normedText = modulate(text, shift: doubleText[0], scale: doubleText[1])
            let queries = concatenated([
                heads(block.contextQuery(normedText), norm: block.contextQueryNorm),
                heads(block.query(normed), norm: block.queryNorm),
            ], axis: 1)
            let keys = concatenated([
                heads(block.contextKey(normedText), norm: block.contextKeyNorm),
                heads(block.key(normed), norm: block.keyNorm),
            ], axis: 1)
            let values = concatenated([heads(block.contextValue(normedText)), heads(block.value(normed))], axis: 1)
            let attended = attention(queries, keys, values, cosines: cosines, sines: sines)
            x = x + doubleImage[2] * block.output(attended[textCount...]).asType(.float32)
            text = text + doubleText[2] * block.contextOutput(attended[..<textCount]).asType(.float32)
            let fed = modulate(x, shift: doubleImage[3], scale: doubleImage[4])
            x = x + doubleImage[5] * block.feedOut(swiGLU(block.feedIn(fed))).asType(.float32)
            let fedText = modulate(text, shift: doubleText[3], scale: doubleText[4])
            text = text + doubleText[5] * block.contextFeedOut(swiGLU(block.contextFeedIn(fedText))).asType(.float32)
        }

        var joined = concatenated([text, x], axis: 0)
        let attentionWidth = 3 * c.width
        for block in singleBlocks {
            let projected = block.projection(modulate(joined, shift: single[0], scale: single[1]))
            let qkv = split(projected[0..., ..<attentionWidth], parts: 3, axis: -1)
            let attended = attention(
                heads(qkv[0], norm: block.queryNorm), heads(qkv[1], norm: block.keyNorm), heads(qkv[2]),
                cosines: cosines, sines: sines,
            )
            let fed = swiGLU(projected[0..., attentionWidth...])
            joined = joined + single[2] * block.output(concatenated([attended, fed], axis: -1)).asType(.float32)
        }

        let imageTokens = joined[textCount ..< (textCount + (outputs ?? image.dim(0)))]
        let out = split(normOut(modulationInput).asType(.float32), parts: 2, axis: -1)
        let normed = layerNorm(imageTokens, eps: c.eps) * (1 + out[0]) + out[1]
        let velocity = projectionOut(normed.asType(dtype)).asType(.float32)
        eval(velocity)
        return velocity
    }

    /// diffusers' sinusoidal timestep embedding, cosines first (`flip_sin_to_cos`), `[1, channels]`.
    private func timestepEmbedding(_ t: Float) -> MLXArray {
        let half = configuration.timestepChannels / 2
        let frequencies = exp(-Float(Foundation.log(10000.0)) * MLXArray(0 ..< half).asType(.float32) / Float(half))
        let arguments = t * frequencies
        return concatenated([cos(arguments), sin(arguments)], axis: -1).expandedDimensions(axis: 0)
    }

    /// The rotary cosines and sines, `[tokens, head dimension]`, each axis's frequencies repeated
    /// for the two values of a pair (diffusers' `repeat_interleave_real`).
    private func rotaryEmbedding(_ ids: MLXArray) -> (MLXArray, MLXArray) {
        var cosines: [MLXArray] = []
        var sines: [MLXArray] = []
        let positions = ids.asType(.float32)
        for (axis, dimension) in configuration.ropeAxes.enumerated() {
            let exponents = MLXArray(stride(from: 0, to: dimension, by: 2).map(Float.init)) / Float(dimension)
            let frequencies = 1 / pow(MLXArray(Float(configuration.ropeTheta)), exponents)
            let angles = positions[0..., axis].expandedDimensions(axis: 1) * frequencies.expandedDimensions(axis: 0)
            let pairs = angles.expandedDimensions(axis: -1)
            cosines.append(repeated(cos(pairs), count: 2, axis: -1).reshaped([angles.dim(0), dimension]))
            sines.append(repeated(sin(pairs), count: 2, axis: -1).reshaped([angles.dim(0), dimension]))
        }
        return (concatenated(cosines, axis: -1), concatenated(sines, axis: -1))
    }

    /// Layer norm without parameters, then `(1 + scale) · x + shift`, in the compute type.
    private func modulate(_ x: MLXArray, shift: MLXArray, scale: MLXArray) -> MLXArray {
        (layerNorm(x, eps: configuration.eps) * (1 + scale) + shift).asType(dtype)
    }

    /// `[tokens, width]` as `[1, tokens, heads, head dimension]`, RMS-normed per head with `norm`.
    private func heads(_ x: MLXArray, norm: MLXArray? = nil) -> MLXArray {
        let c = configuration
        let split = x.reshaped([1, x.dim(0), c.heads, c.headDimension])
        return norm.map { rmsNorm(split, weight: $0, eps: c.eps) } ?? split
    }

    /// Rotary positions on the queries and keys (in float32), then attention over every token.
    private func attention(
        _ queries: MLXArray, _ keys: MLXArray, _ values: MLXArray, cosines: MLXArray, sines: MLXArray,
    ) -> MLXArray {
        let c = configuration
        let cosines = cosines.expandedDimensions(axes: [0, 2])
        let sines = sines.expandedDimensions(axes: [0, 2])
        func rotate(_ x: MLXArray) -> MLXArray {
            let x = x.asType(.float32)
            let pairs = split(x.reshaped(x.shape.dropLast() + [c.headDimension / 2, 2]), parts: 2, axis: -1)
            let turned = concatenated([-pairs[1], pairs[0]], axis: -1).reshaped(x.shape)
            return (x * cosines + turned * sines).asType(dtype)
        }
        let attended = MLXFast.scaledDotProductAttention(
            queries: rotate(queries).transposed(0, 2, 1, 3),
            keys: rotate(keys).transposed(0, 2, 1, 3),
            values: values.transposed(0, 2, 1, 3),
            scale: 1 / Float(c.headDimension).squareRoot(),
            mask: .none,
        )
        return attended.transposed(0, 2, 1, 3).reshaped([queries.dim(1), c.width])
    }

    /// SiLU of the first half, times the second.
    private func swiGLU(_ x: MLXArray) -> MLXArray {
        let halves = split(x, parts: 2, axis: -1)
        return silu(halves[0]) * halves[1]
    }
}
