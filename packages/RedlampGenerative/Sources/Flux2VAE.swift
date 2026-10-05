import Foundation
import MLX

/// FLUX.2's autoencoder, as diffusers' `AutoencoderKLFlux2`: diffusers' convolutional encoder and
/// decoder (ResNet blocks, a single-head attention in the middle, group norm), with the latents
/// patched 2 × 2 into 128 channels and normalised by the batch-norm statistics the model ships.
/// Images and latents are channels last; it always computes in float32.
public final class Flux2VAE {
    struct Configuration: Decodable {
        let blockChannels: [Int]
        let latentChannels: Int
        let layersPerBlock: Int
        let groups: Int
        let batchNormEps: Float

        enum CodingKeys: String, CodingKey {
            case blockChannels = "block_out_channels"
            case latentChannels = "latent_channels"
            case layersPerBlock = "layers_per_block"
            case groups = "norm_num_groups"
            case batchNormEps = "batch_norm_eps"
        }
    }

    private struct Convolution {
        let weight: MLXArray
        let bias: MLXArray
        let stride: Int
        let padding: Int

        init(_ weights: Weights, _ name: String, stride: Int = 1, padding: Int? = nil) throws {
            // PyTorch's [out, in, kh, kw] as MLX's [out, kh, kw, in].
            weight = try weights(name + ".weight", .float32).transposed(0, 2, 3, 1)
            bias = try weights(name + ".bias", .float32)
            self.stride = stride
            self.padding = padding ?? weight.dim(1) / 2
        }

        /// MLX unfolds a convolution's input, a copy for each tap of the kernel: 9 GB for a 3 × 3
        /// convolution over 1024 × 1024 pixels of 256 channels. Larger inputs are convolved in bands of
        /// rows, each with the rows its kernel reaches beyond it, so the copy stays under this.
        static let unfoldedBytes = 1 << 30

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            let (kernelHeight, kernelWidth) = (weight.dim(1), weight.dim(2))
            let outputHeight = (x.dim(1) + 2 * padding - kernelHeight) / stride + 1
            let outputWidth = (x.dim(2) + 2 * padding - kernelWidth) / stride + 1
            let rowBytes = outputWidth * kernelHeight * kernelWidth * x.dim(3) * 4
            let rows = max(Self.unfoldedBytes / rowBytes, 1)
            guard outputHeight > rows else {
                return conv2d(x, weight, stride: .init(stride), padding: .init(padding)) + bias
            }
            let height = x.dim(1)
            var bands: [MLXArray] = []
            for start in Swift.stride(from: 0, to: outputHeight, by: rows) {
                let end = min(start + rows, outputHeight)
                let top = start * stride - padding, bottom = (end - 1) * stride + kernelHeight - padding
                let band = padded(
                    x[0..., max(top, 0) ..< min(bottom, height)],
                    widths: [0, .init((max(-top, 0), max(bottom - height, 0))), .init(padding), 0],
                )
                let convolved = conv2d(band, weight, stride: .init(stride)) + bias
                eval(convolved)
                bands.append(convolved)
            }
            return concatenated(bands, axis: 1)
        }
    }

    private struct GroupNorm {
        let weight: MLXArray
        let bias: MLXArray
        let groups: Int

        init(_ weights: Weights, _ name: String, groups: Int) throws {
            weight = try weights(name + ".weight", .float32)
            bias = try weights(name + ".bias", .float32)
            self.groups = groups
        }

        /// Over `[1, h, w, c]`, as PyTorch's `GroupNorm` (eps 1e-6, diffusers' VAE), then SiLU when
        /// `activated`: in one kernel, so a full-size image makes no copies on the way.
        func callAsFunction(_ x: MLXArray, activated: Bool = false) -> MLXArray {
            let shape = x.shape
            let grouped = x.reshaped([1, -1, groups, shape[3] / groups])
            let mean = grouped.mean(axes: [1, 3], keepDims: true)
            let scale = rsqrt(grouped.variance(axes: [1, 3], keepDims: true) + 1e-6)
            let affine = [weight, bias].map { $0.reshaped([1, 1, groups, shape[3] / groups]) }
            let normalised = (activated ? Self.normalisedSiLU : Self.normalised)([grouped, mean, scale] + affine)[0]
            return normalised.reshaped(shape)
        }

        private static let normalised = compile { (inputs: [MLXArray]) in
            [(inputs[0] - inputs[1]) * inputs[2] * inputs[3] + inputs[4]]
        }

        private static let normalisedSiLU = compile { (inputs: [MLXArray]) in
            [silu((inputs[0] - inputs[1]) * inputs[2] * inputs[3] + inputs[4])]
        }
    }

    private struct ResnetBlock {
        let norm1, norm2: GroupNorm
        let conv1, conv2: Convolution
        let shortcut: Convolution?

        init(_ weights: Weights, _ name: String, groups: Int) throws {
            norm1 = try GroupNorm(weights, name + ".norm1", groups: groups)
            conv1 = try Convolution(weights, name + ".conv1")
            norm2 = try GroupNorm(weights, name + ".norm2", groups: groups)
            conv2 = try Convolution(weights, name + ".conv2")
            shortcut = weights.contains(name + ".conv_shortcut.weight")
                ? try Convolution(weights, name + ".conv_shortcut") : nil
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            let h = conv2(norm2(conv1(norm1(x, activated: true)), activated: true))
            return (shortcut.map { $0(x) } ?? x) + h
        }
    }

    private struct AttentionBlock {
        let norm: GroupNorm
        let query, key, value, output: Linear

        init(_ weights: Weights, _ name: String, groups: Int) throws {
            norm = try GroupNorm(weights, name + ".group_norm", groups: groups)
            query = try Linear(weights, name + ".to_q", dtype: .float32)
            key = try Linear(weights, name + ".to_k", dtype: .float32)
            value = try Linear(weights, name + ".to_v", dtype: .float32)
            output = try Linear(weights, name + ".to_out.0", dtype: .float32)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            let shape = x.shape
            let tokens = norm(x).reshaped([1, 1, -1, shape[3]])
            let attended = MLXFast.scaledDotProductAttention(
                queries: query(tokens), keys: key(tokens), values: value(tokens),
                scale: 1 / Float(shape[3]).squareRoot(), mask: .none,
            )
            return x + output(attended).reshaped(shape)
        }
    }

    private struct Middle {
        let first: ResnetBlock
        let attention: AttentionBlock
        let second: ResnetBlock

        init(_ weights: Weights, _ name: String, groups: Int) throws {
            first = try ResnetBlock(weights, name + ".resnets.0", groups: groups)
            attention = try AttentionBlock(weights, name + ".attentions.0", groups: groups)
            second = try ResnetBlock(weights, name + ".resnets.1", groups: groups)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            second(attention(first(x)))
        }
    }

    let configuration: Configuration
    private let encoderIn: Convolution
    private let encoderBlocks: [(resnets: [ResnetBlock], downsample: Convolution?)]
    private let encoderMiddle: Middle
    private let encoderNorm: GroupNorm
    private let encoderOut: Convolution
    private let quantConvolution: Convolution
    private let postQuantConvolution: Convolution
    private let decoderIn: Convolution
    private let decoderMiddle: Middle
    private let decoderBlocks: [(resnets: [ResnetBlock], upsample: Convolution?)]
    private let decoderNorm: GroupNorm
    private let decoderOut: Convolution
    /// The batch norm's running mean and standard deviation, per patched channel.
    private let latentMean: MLXArray
    private let latentDeviation: MLXArray

    /// From the model's `vae/` folder.
    public init(directory: URL) throws {
        let c = try JSONDecoder().decode(
            Configuration.self, from: Data(contentsOf: directory.appending(path: "config.json")),
        )
        configuration = c
        let weights = try Weights(directory: directory)
        let groups = c.groups
        encoderIn = try Convolution(weights, "encoder.conv_in")
        encoderBlocks = try c.blockChannels.indices.map { index in
            let prefix = "encoder.down_blocks.\(index)"
            let resnets = try (0 ..< c.layersPerBlock).map {
                try ResnetBlock(weights, "\(prefix).resnets.\($0)", groups: groups)
            }
            let downsample = index < c.blockChannels.count - 1
                ? try Convolution(weights, "\(prefix).downsamplers.0.conv", stride: 2, padding: 0) : nil
            return (resnets, downsample)
        }
        encoderMiddle = try Middle(weights, "encoder.mid_block", groups: groups)
        encoderNorm = try GroupNorm(weights, "encoder.conv_norm_out", groups: groups)
        encoderOut = try Convolution(weights, "encoder.conv_out")
        quantConvolution = try Convolution(weights, "quant_conv")
        postQuantConvolution = try Convolution(weights, "post_quant_conv")
        decoderIn = try Convolution(weights, "decoder.conv_in")
        decoderMiddle = try Middle(weights, "decoder.mid_block", groups: groups)
        decoderBlocks = try c.blockChannels.indices.map { index in
            let prefix = "decoder.up_blocks.\(index)"
            let resnets = try (0 ... c.layersPerBlock).map {
                try ResnetBlock(weights, "\(prefix).resnets.\($0)", groups: groups)
            }
            let upsample = index < c.blockChannels.count - 1
                ? try Convolution(weights, "\(prefix).upsamplers.0.conv") : nil
            return (resnets, upsample)
        }
        decoderNorm = try GroupNorm(weights, "decoder.conv_norm_out", groups: groups)
        decoderOut = try Convolution(weights, "decoder.conv_out")
        latentMean = try weights("bn.running_mean", .float32)
        latentDeviation = try sqrt(weights("bn.running_var", .float32) + c.batchNormEps)
    }

    /// The latents of `image` `[h, w, 3]` in -1…1 (each side a multiple of 16): the encoder's mean,
    /// patched 2 × 2 and normalised, `[h / 16, w / 16, 128]`.
    public func encode(_ image: MLXArray) -> MLXArray {
        var x = encoderIn(image.asType(.float32).expandedDimensions(axis: 0))
        for block in encoderBlocks {
            for resnet in block.resnets {
                x = resnet(x)
                eval(x)
            }
            if let downsample = block.downsample {
                // diffusers pads one row and column at the far edges before a stride-2 convolution.
                x = downsample(padded(x, widths: [0, [0, 1], [0, 1], 0]))
                eval(x)
            }
        }
        x = encoderOut(encoderNorm(encoderMiddle(x), activated: true))
        let moments = quantConvolution(x)
        let mean = moments[0..., 0..., 0..., ..<configuration.latentChannels]
        let latents = (Self.patched(mean[0]) - latentMean) / latentDeviation
        eval(latents)
        return latents
    }

    /// The image `[h, w, 3]` in -1…1 that `latents` `[h / 16, w / 16, 128]` (patched and
    /// normalised) decode to.
    public func decode(_ latents: MLXArray) -> MLXArray {
        let unpatched = Self.unpatched(latents.asType(.float32) * latentDeviation + latentMean)
        var x = decoderIn(postQuantConvolution(unpatched.expandedDimensions(axis: 0)))
        x = decoderMiddle(x)
        for block in decoderBlocks {
            for resnet in block.resnets {
                x = resnet(x)
                eval(x)
            }
            if let upsample = block.upsample {
                x = upsample(Self.nearest2x(x))
                eval(x)
            }
        }
        let image = decoderOut(decoderNorm(x, activated: true))[0]
        eval(image)
        return image
    }

    /// `[2h, 2w, c]` as `[h, w, 4c]`, channel `c · 4 + row · 2 + column` (diffusers' `_patchify_latents`).
    static func patched(_ x: MLXArray) -> MLXArray {
        let (h, w, c) = (x.dim(0) / 2, x.dim(1) / 2, x.dim(2))
        return x.reshaped([h, 2, w, 2, c]).transposed(0, 2, 4, 1, 3).reshaped([h, w, c * 4])
    }

    static func unpatched(_ x: MLXArray) -> MLXArray {
        let (h, w, c) = (x.dim(0), x.dim(1), x.dim(2) / 4)
        return x.reshaped([h, w, c, 2, 2]).transposed(0, 3, 1, 4, 2).reshaped([h * 2, w * 2, c])
    }

    private static func nearest2x(_ x: MLXArray) -> MLXArray {
        let s = x.shape
        let wide = broadcast(x.reshaped([s[0], s[1], 1, s[2], 1, s[3]]), to: [s[0], s[1], 2, s[2], 2, s[3]])
        return wide.reshaped([s[0], s[1] * 2, s[2] * 2, s[3]])
    }
}

/// `x · sigmoid(x)`.
func silu(_ x: MLXArray) -> MLXArray {
    x * sigmoid(x)
}
