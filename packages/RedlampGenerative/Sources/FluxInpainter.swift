import Foundation
import MLX

/// FLUX.2 [klein]'s noise levels, as diffusers' Flux2Klein pipelines set them: `steps` evenly from
/// 1 to `1 / steps`, shifted towards noise by `compute_empirical_mu` for the image's size
/// (FlowMatchEulerDiscreteScheduler's exponential time shift), then 0.
public struct FlowMatchSchedule: Hashable, Sendable {
    public let sigmas: [Float]

    public init(steps: Int, imageTokens: Int) {
        let mu = Self.mu(imageTokens: imageTokens, steps: steps)
        let shifted = (0 ..< steps).map { index -> Float in
            let t = Float(1 - Double(index) * (1 - 1 / Double(steps)) / Double(max(steps - 1, 1)))
            return Float(exp(mu) / (exp(mu) + Double(1 / t - 1)))
        }
        sigmas = shifted + [0]
    }

    /// diffusers' `compute_empirical_mu`.
    static func mu(imageTokens: Int, steps: Int) -> Double {
        let (a1, b1) = (8.73809524e-05, 1.89833333)
        let (a2, b2) = (0.00016927, 0.45666666)
        let tokens = Double(imageTokens)
        guard imageTokens <= 4300 else { return a2 * tokens + b2 }
        let m200 = a2 * tokens + b2
        let m10 = a1 * tokens + b1
        let a = (m200 - m10) / 190
        return a * Double(steps) + (m200 - 200 * a)
    }
}

/// Repaints part of an image with FLUX.2 [klein] 4B, as diffusers' `Flux2KleinInpaintPipeline`
/// does at strength 1: the image's latents go in as a reference beside the noise, and after each
/// step the area outside the mask is put back at that step's noise level.
public final class FluxInpainter {
    public let transformer: Flux2Transformer
    public let vae: Flux2VAE

    /// From the model's diffusers folder (`transformer/`, `vae/`).
    public init(model directory: URL, dtype: DType = .bfloat16, quantization: WeightQuantization? = nil) throws {
        transformer = try Flux2Transformer(
            directory: directory.appending(path: "transformer"), dtype: dtype, quantization: quantization,
        )
        vae = try Flux2VAE(directory: directory.appending(path: "vae"))
    }

    /// Gaussian noise for a fill `width` × `height` (multiples of 16), `[tokens, 128]`, from `seed`.
    public static func noise(width: Int, height: Int, seed: UInt64) -> MLXArray {
        MLXRandom.normal([(height / 16) * (width / 16), 128], key: MLXRandom.key(seed))
    }

    /// Positions on the four axes (time, row, column, layer) of a `rows` × `columns` grid of
    /// latents at `time`, `[rows · columns, 4]`.
    static func gridIDs(rows: Int, columns: Int, time: Int) -> MLXArray {
        var ids: [Float] = []
        ids.reserveCapacity(rows * columns * 4)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                ids += [Float(time), Float(row), Float(column), 0]
            }
        }
        return MLXArray(ids, [rows * columns, 4])
    }

    /// A prompt's positions: the fourth axis counts its tokens, `[count, 4]`.
    static func textIDs(count: Int) -> MLXArray {
        MLXArray((0 ..< count).flatMap { [0, 0, 0, Float($0)] }, [count, 4])
    }

    /// `mask` `[h, w]` on the latents' grid, `[tokens, 1]`: binarised at a half, as the pipeline's
    /// mask processor does, then sampled bilinearly (PyTorch's `interpolate`, corners not aligned),
    /// which for a sixteenth averages the four pixels at each cell's centre.
    static func latentMask(_ mask: MLXArray) -> MLXArray {
        let (h, w) = (mask.dim(0), mask.dim(1))
        let binary = (mask.asType(.float32) .>= 0.5).asType(.float32)
        let cells = binary.reshaped([h / 16, 16, w / 16, 16])[0..., 7 ..< 9, 0..., 7 ..< 9]
        return cells.mean(axes: [1, 3]).reshaped([-1, 1])
    }

    /// Repaints `mask`'s area (1 repaints, 0 keeps) of `image` `[h, w, 3]` in -1…1, each side a
    /// multiple of 16, guided by a prompt's `embeddings` `[512, 7680]`, from `noise`
    /// (`noise(width:height:seed:)`), with `reference` images beside the image if any. Returns the
    /// final latents `[tokens, 128]` and the decoded image `[h, w, 3]` in -1…1. `progress` hears
    /// each step as it's done.
    public func inpaint(
        image: MLXArray, mask: MLXArray, embeddings: MLXArray, noise: MLXArray, steps: Int = 4,
        references: [MLXArray] = [], progress: ((Int) -> Void)? = nil,
    ) -> (latents: MLXArray, image: MLXArray) {
        let (rows, columns) = (image.dim(0) / 16, image.dim(1) / 16)
        let count = rows * columns
        let imageLatents = vae.encode(image).reshaped([count, 128])
        var conditions = [imageLatents]
        var conditionIDs = [Self.gridIDs(rows: rows, columns: columns, time: 10)]
        for (index, reference) in references.enumerated() {
            let latents = vae.encode(reference)
            conditions.append(latents.reshaped([-1, 128]))
            conditionIDs.append(Self.gridIDs(rows: latents.dim(0), columns: latents.dim(1), time: 20 + 10 * index))
        }
        let condition = concatenated(conditions, axis: 0)
        let imageIDs = concatenated([Self.gridIDs(rows: rows, columns: columns, time: 0)] + conditionIDs, axis: 0)
        let textIDs = Self.textIDs(count: embeddings.dim(0))
        let latentMask = Self.latentMask(mask)
        let sigmas = FlowMatchSchedule(steps: steps, imageTokens: count).sigmas
        let noise = noise.asType(.float32)

        var latents = noise
        for step in 0 ..< steps {
            let velocity = transformer.velocity(
                image: concatenated([latents, condition], axis: 0), context: embeddings, imageIDs: imageIDs,
                textIDs: textIDs, timestep: sigmas[step], outputs: count,
            )
            latents = latents + (sigmas[step + 1] - sigmas[step]) * velocity
            let next = sigmas[step + 1]
            let kept = step < steps - 1 ? next * noise + (1 - next) * imageLatents : imageLatents
            latents = (1 - latentMask) * kept + latentMask * latents
            eval(latents)
            progress?(step + 1)
        }
        return (latents, vae.decode(latents.reshaped([rows, columns, 128])))
    }
}
