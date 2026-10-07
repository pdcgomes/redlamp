import CoreGraphics
import CoreML
import Foundation
import RedlampEngineAPI

/// ViTMatte-base (hustvl; J. Yao, X. Wang, S. Yang and B. Wang, "ViTMatte: Boosting image matting
/// with pre-trained plain vision transformers", 2024), converted by
/// `research/prototypes/masking/convert_vitmatte.py` and `compress_vitmatte.py`: the alpha matte of
/// a 1024 px tile from the photo and a trimap (MSK-32). It solves the unsure band of a Subject,
/// Background or person mask, from 1% of the long side inside Vision's edge to 5% outside it: on
/// hair_bench's heads that halves closed-form matting's error along the edge and keeps 43% of the
/// stray strands against 15% (`vitmatte_bench.py`). With closed-form's narrower band it drops them.
///
/// Its weights are Apache-2.0, trained on Composition-1k and Distinctions-646, whose terms the
/// owner accepted as an exception to the licence gate (DEC-35).
public final class ViTMatte: @unchecked Sendable {
    public static let tile = 1024
    /// Tiles overlap by this much and blend across it, so no seam shows where they meet.
    static let overlap = 128
    /// The unsure band, as fractions of the long side inside and outside the coarse edge.
    public static let inner: Float = 0.01
    public static let outer: Float = 0.05

    public let manifest: ModelManifest
    private let model: MLModel
    private let lock = NSLock()

    public init(manifest: ModelManifest, directory: URL) throws {
        self.manifest = manifest
        guard let name = SAMSegmenter.packages(in: manifest).first
        else { throw ModelStoreError.unknownModel(manifest.id) }
        let compiled = try CompiledModels.compiled(
            package: directory.appending(path: "\(name).mlpackage"), key: "\(manifest.id)-v\(manifest.version)-\(name)",
        )
        let configuration = MLModelConfiguration()
        // On the Neural Engine a tile takes three times as long.
        configuration.computeUnits = .cpuAndGPU
        model = try Inference.shared.load(compiled, configuration: configuration)
    }

    /// `coarse` with its unsure band solved against `image`, at the image's size. Only the tiles
    /// the band reaches are run.
    public func refine(_ coarse: GrayMask, image: CGImage) throws -> GrayMask {
        let size = PixelSize(width: image.width, height: image.height)
        guard let rgb = RGBImage(image, size: size) else { return coarse.resized(to: size) }
        let mask = coarse.resized(to: size).coverage
        let trimap = ClosedFormMatte.trimap(
            mask, width: size.width, height: size.height, inner: Self.inner, outer: Self.outer,
        )
        var total = [Float](repeating: 0, count: trimap.count)
        var weight = [Float](repeating: 0, count: trimap.count)
        for y in Self.starts(size.height) {
            for x in Self.starts(size.width) {
                let area = (width: min(Self.tile, size.width - x), height: min(Self.tile, size.height - y))
                let unsure = (y ..< y + area.height).contains { row in
                    trimap[(row * size.width + x) ..< (row * size.width + x + area.width)].contains(0.5)
                }
                guard unsure else { continue }
                let alpha = try predict(rgb, trimap: trimap, x: x, y: y, area: area)
                for row in 0 ..< area.height {
                    for column in 0 ..< area.width {
                        let blend = Self.ramp(row, area.height) * Self.ramp(column, area.width)
                        let index = (y + row) * size.width + x + column
                        total[index] += alpha[row * Self.tile + column] * blend
                        weight[index] += blend
                    }
                }
            }
        }
        let coverage = trimap.indices.map { index in
            trimap[index] != 0.5 ? trimap[index] : weight[index] > 0 ? total[index] / weight[index] : mask[index]
        }
        return GrayMask(width: size.width, height: size.height, coverage: coverage)
    }

    /// How wide, either side of a strand's centre, an addition to a matte may be and still count
    /// as a strand.
    static let strandRadius = 3

    /// `base` with what `matte` adds to it kept only where it is thin enough to be hair: the part
    /// of the addition that a grey opening by a square `2 * strandRadius + 1` px wide removes.
    /// Over the wide band it needs for strands, ViTMatte also pulls patches of background beside
    /// the subject into its matte (on the evaluation set, about 1.7% of each frame); added this
    /// way to closed-form's matte it keeps 42% of hair_bench's strands, against closed-form's
    /// 15%, and adds almost nothing else (`vitmatte_bench.py strands`).
    public static func strands(of matte: GrayMask, addedTo base: GrayMask) -> GrayMask {
        let size = PixelSize(width: base.width, height: base.height)
        let ours = base.coverage
        let added = zip(matte.resized(to: size).coverage, ours).map { max($0 - $1, 0) }
        let opened = GrayMask.opening(added, width: size.width, height: size.height, radius: strandRadius)
        return GrayMask(
            width: size.width, height: size.height,
            coverage: ours.indices.map { min(ours[$0] + added[$0] - opened[$0], 1) },
        )
    }

    /// Where tiles start along a side: whole tiles where the side allows, the last one flush with
    /// its end.
    static func starts(_ length: Int) -> [Int] {
        let step = tile - overlap
        var positions = Array(stride(from: 0, through: max(length - tile, 0), by: step))
        if let last = positions.last, last + tile < length {
            positions.append(length - tile)
        }
        return positions
    }

    /// A tile's weight at `position` along a side `length` long: 1 inside, falling linearly across
    /// the overlap to its edges.
    static func ramp(_ position: Int, _ length: Int) -> Float {
        let x = Float(position) + 0.5
        return min(max(min(x, Float(length) - x) / Float(overlap), 1e-3), 1)
    }

    /// The model's matte of the tile at (`x`, `y`), row by row at the tile's width. A photo
    /// smaller than a tile is padded with its edge pixels, as sure background.
    private func predict(
        _ rgb: RGBImage, trimap: [Float], x: Int, y: Int, area: (width: Int, height: Int),
    ) throws -> [Float] {
        let side = Self.tile as NSNumber
        let image = try MLMultiArray(shape: [1, 3, side, side], dataType: .float32)
        let tri = try MLMultiArray(shape: [1, 1, side, side], dataType: .float32)
        let pixels = image.dataPointer.assumingMemoryBound(to: Float.self)
        let unsure = tri.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = Self.tile * Self.tile
        for row in 0 ..< Self.tile {
            for column in 0 ..< Self.tile {
                let inside = row < area.height && column < area.width
                let (px, py) = (x + min(column, area.width - 1), y + min(row, area.height - 1))
                let colour = rgb.rgb(px, py)
                let index = row * Self.tile + column
                pixels[index] = colour.x
                pixels[plane + index] = colour.y
                pixels[2 * plane + index] = colour.z
                unsure[index] = inside ? trimap[py * rgb.width + px] : 0
            }
        }
        let output = try lock.withLock {
            try Inference.shared.predict(model, from: MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(multiArray: image), "trimap": MLFeatureValue(multiArray: tri),
            ]))
        }
        guard let alpha = output.featureValue(for: "alpha")?.multiArrayValue
        else { throw MaskComputationError.unsupported(.subject) }
        return DepthAnything3.values(alpha).map { min(max($0, 0), 1) }
    }
}
