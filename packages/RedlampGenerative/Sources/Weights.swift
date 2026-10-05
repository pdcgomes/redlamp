import Foundation
import MLX

/// A model folder's safetensors shards, by tensor name.
struct Weights {
    enum WeightsError: Error {
        case missing(String)
    }

    private var arrays: [String: MLXArray] = [:]

    init(directory: URL) throws {
        let shards = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        for shard in shards {
            try arrays.merge(loadArrays(url: shard)) { $1 }
        }
    }

    func contains(_ name: String) -> Bool {
        arrays[name] != nil
    }

    /// `name`, in `dtype`.
    func callAsFunction(_ name: String, _ dtype: DType) throws -> MLXArray {
        guard let array = arrays[name] else { throw WeightsError.missing(name) }
        return array.asType(dtype)
    }

    /// `name` as stored (a quantised weight keeps its packed integers).
    func raw(_ name: String) throws -> MLXArray {
        guard let array = arrays[name] else { throw WeightsError.missing(name) }
        return array
    }
}

/// How the transformer's large layers are kept: their weights quantised to `bits` a value, in groups
/// of `groupSize` along the input (MLX's affine quantisation).
public struct WeightQuantization: Hashable, Sendable {
    public var bits: Int
    public var groupSize: Int

    public init(bits: Int, groupSize: Int = 64) {
        self.bits = bits
        self.groupSize = groupSize
    }
}

/// A linear layer, `x · Wᵀ (+ b)`, from a PyTorch weight `[out, in]`: dense in the compute type, or
/// with its weight quantised in groups along the input (MLX's affine quantisation).
struct Linear {
    private enum Storage {
        case dense(MLXArray)
        case quantized(weight: MLXArray, scales: MLXArray, biases: MLXArray?, groupSize: Int, bits: Int)
    }

    private let storage: Storage
    private let bias: MLXArray?

    /// From `name.weight` (and `name.bias` when there is one). A weight already quantised in the
    /// folder (`name.scales`, `name.biases`, with `bits`) is used as it is.
    init(_ weights: Weights, _ name: String, dtype: DType, quantization: WeightQuantization? = nil) throws {
        bias = weights.contains(name + ".bias") ? try weights(name + ".bias", dtype) : nil
        if weights.contains(name + ".scales"), let quantization {
            storage = try .quantized(
                weight: weights.raw(name + ".weight"),
                scales: weights(name + ".scales", dtype),
                biases: weights.contains(name + ".biases") ? weights(name + ".biases", dtype) : nil,
                groupSize: quantization.groupSize, bits: quantization.bits,
            )
        } else if let quantization {
            let (weight, scales, biases) = try MLX.quantized(
                weights(name + ".weight", dtype), groupSize: quantization.groupSize, bits: quantization.bits,
            )
            storage = .quantized(
                weight: weight, scales: scales, biases: biases,
                groupSize: quantization.groupSize, bits: quantization.bits,
            )
        } else {
            storage = try .dense(weights(name + ".weight", dtype).T)
        }
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let y = switch storage {
        case let .dense(weight):
            matmul(x, weight)
        case let .quantized(weight, scales, biases, groupSize, bits):
            quantizedMM(x, weight, scales: scales, biases: biases, transpose: true, groupSize: groupSize, bits: bits)
        }
        return bias.map { y + $0 } ?? y
    }

    /// The arrays it holds, to evaluate once they're made.
    var arrays: [MLXArray] {
        let held: [MLXArray] = switch storage {
        case let .dense(weight): [weight]
        case let .quantized(weight, scales, biases, _, _): [weight, scales] + (biases.map { [$0] } ?? [])
        }
        return held + (bias.map { [$0] } ?? [])
    }
}
