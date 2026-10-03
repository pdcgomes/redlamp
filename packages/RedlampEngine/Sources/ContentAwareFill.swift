import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd

/// Content-aware fill for Remove spots (RM-07): exemplar-based inpainting (Criminisi, Pérez and
/// Toyama, "Region filling and object removal by exemplar-based image inpainting", 2004, whose
/// patents have expired).
///
/// The hole is filled from its edge inwards, one 9 × 9 patch at a time: first where confidence
/// (how much of the patch is the photo rather than fill) and structure (an edge running into the
/// hole, across its edge) are greatest, so lines are continued before flat areas are filled. Each
/// patch is copied from the patch around the hole that best matches what's known of it, found by
/// scoring every candidate on the GPU (`rl_fill_costs`), not by PatchMatch's randomised search.
final class ContentAwareFill {
    struct Region {
        let width: Int
        let height: Int
        /// Perceptual (square-root) camera RGB.
        var pixels: [SIMD3<Float>]
        /// The pixels to fill.
        let hole: [Bool]
    }

    /// Patches are (2 × half + 1) texels across.
    static let half = 4
    /// Candidates are scored on every second texel, then the best one's neighbours on every texel.
    static let stride = 2

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let kernels: KernelLibrary

    init(device: any MTLDevice, queue: any MTLCommandQueue, kernels: KernelLibrary) {
        self.device = device
        self.queue = queue
        self.kernels = kernels
    }

    /// Where each hole pixel copies from, as a move in the region's texels (zero outside the hole,
    /// and wherever no candidate fits).
    func fill(_ region: Region) throws -> [SIMD2<Int32>] {
        let (width, height, half) = (region.width, region.height, Self.half)
        let count = width * height
        var offsets = [SIMD2<Int32>](repeating: .zero, count: count)
        guard width > 2 * half + 1, height > 2 * half + 1, region.hole.contains(true) else { return offsets }
        guard let imageBuffer = device.makeBuffer(length: count * 16, options: .storageModeShared),
              let knownBuffer = device.makeBuffer(length: count, options: .storageModeShared),
              let sourceBuffer = device.makeBuffer(length: count, options: .storageModeShared)
        else { throw EngineError.gpuUnavailable }
        let image = imageBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let known = knownBuffer.contents().bindMemory(to: UInt8.self, capacity: count)
        let sourceOK = sourceBuffer.contents().bindMemory(to: UInt8.self, capacity: count)
        for index in 0 ..< count {
            image[index] = SIMD4(region.pixels[index], 0)
            known[index] = region.hole[index] ? 0 : 1
        }
        // A source patch lies inside the region and touches no hole pixel (an integral image of the hole).
        var integral = [Int](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0 ..< height {
            var row = 0
            for x in 0 ..< width {
                row += region.hole[y * width + x] ? 1 : 0
                integral[(y + 1) * (width + 1) + x + 1] = integral[y * (width + 1) + x + 1] + row
            }
        }
        var anySource = false
        for y in 0 ..< height {
            for x in 0 ..< width {
                guard x >= half, y >= half, x < width - half, y < height - half else {
                    sourceOK[y * width + x] = 0
                    continue
                }
                let (x0, y0, x1, y1) = (x - half, y - half, x + half + 1, y + half + 1)
                let holes = integral[y1 * (width + 1) + x1] - integral[y0 * (width + 1) + x1]
                    - integral[y1 * (width + 1) + x0] + integral[y0 * (width + 1) + x0]
                sourceOK[y * width + x] = holes == 0 ? 1 : 0
                anySource = anySource || holes == 0
            }
        }
        guard anySource else { return offsets }

        let gridWidth = (width - 2 * half + Self.stride - 1) / Self.stride
        let gridHeight = (height - 2 * half + Self.stride - 1) / Self.stride
        guard let costBuffer = device.makeBuffer(length: gridWidth * gridHeight * 4, options: .storageModeShared)
        else { throw EngineError.gpuUnavailable }
        let costs = costBuffer.contents().bindMemory(to: Float.self, capacity: gridWidth * gridHeight)

        // The front only ever lies within the hole's bounds.
        var low = SIMD2(width, height), high = SIMD2(-1, -1)
        for y in 0 ..< height {
            for x in 0 ..< width where region.hole[y * width + x] {
                low = simd_min(low, SIMD2(x, y))
                high = simd_max(high, SIMD2(x, y))
            }
        }
        var confidence = region.hole.map { $0 ? Float(0) : 1 }
        var remaining = region.hole.filter(\.self).count
        func luma(_ index: Int) -> Float {
            simd_dot(SIMD3(image[index].x, image[index].y, image[index].z), SIMD3(0.27, 0.67, 0.06))
        }
        while remaining > 0 {
            guard let target = nextTarget(
                width: width,
                height: height,
                low: low,
                high: high,
                known: known,
                confidence: confidence,
                luma: luma,
            )
            else { break }
            var params = FillCostParams(
                size: SIMD4(Int32(width), Int32(height), Int32(half), Int32(Self.stride)),
                target: SIMD4(Int32(target.x), Int32(target.y), 0, 0),
                candidates: SIMD4(Int32(half), Int32(half), Int32(gridWidth), Int32(gridHeight)),
            )
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
            else { throw EngineError.gpuUnavailable }
            encoder.setComputePipelineState(kernels.fillCosts)
            encoder.setBytes(&params, length: MemoryLayout<FillCostParams>.stride, index: 0)
            encoder.setBuffer(imageBuffer, offset: 0, index: 1)
            encoder.setBuffer(knownBuffer, offset: 0, index: 2)
            encoder.setBuffer(sourceBuffer, offset: 0, index: 3)
            encoder.setBuffer(costBuffer, offset: 0, index: 4)
            encoder.dispatchGrid(width: gridWidth, height: gridHeight, pipeline: kernels.fillCosts)
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            var best = -1
            var bestCost = Float.infinity
            for index in 0 ..< gridWidth * gridHeight where costs[index] < bestCost {
                bestCost = costs[index]
                best = index
            }
            guard best >= 0 else { break }
            var source = SIMD2(half + (best % gridWidth) * Self.stride, half + (best / gridWidth) * Self.stride)
            // The skipped texels around the best candidate.
            for dy in -1 ... 1 {
                for dx in -1 ... 1 where dx != 0 || dy != 0 {
                    let q = source &+ SIMD2(dx, dy)
                    guard q.x >= 0, q.y >= 0, q.x < width, q.y < height,
                          sourceOK[q.y * width + q.x] == 1 else { continue }
                    let cost = patchCost(
                        target: target,
                        source: q,
                        width: width,
                        height: height,
                        image: image,
                        known: known,
                    )
                    if cost < bestCost {
                        bestCost = cost
                        source = q
                    }
                }
            }
            let patchConfidence = averageConfidence(target, width: width, height: height, confidence: confidence)
            for dy in -half ... half {
                for dx in -half ... half {
                    let t = target &+ SIMD2(dx, dy)
                    guard t.x >= 0, t.y >= 0, t.x < width, t.y < height, known[t.y * width + t.x] == 0 else { continue }
                    let s = source &+ SIMD2(dx, dy)
                    image[t.y * width + t.x] = image[s.y * width + s.x]
                    known[t.y * width + t.x] = 1
                    confidence[t.y * width + t.x] = patchConfidence
                    offsets[t.y * width + t.x] = SIMD2(Int32(source.x - target.x), Int32(source.y - target.y))
                    remaining -= 1
                }
            }
        }
        return offsets
    }

    /// The front pixel to fill next: the highest confidence times data term, the first in scan
    /// order on a tie.
    private func nextTarget(
        width: Int, height: Int, low: SIMD2<Int>, high: SIMD2<Int>, known: UnsafeMutablePointer<UInt8>,
        confidence: [Float], luma: (Int) -> Float,
    ) -> SIMD2<Int>? {
        var best: (priority: Float, point: SIMD2<Int>)?
        for y in low.y ... high.y {
            for x in low.x ... high.x where known[y * width + x] == 0 {
                let onFront = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
                    let (nx, ny) = (x + dx, y + dy)
                    return nx >= 0 && ny >= 0 && nx < width && ny < height && known[ny * width + nx] == 1
                }
                guard onFront else { continue }
                let point = SIMD2(x, y)
                let priority = averageConfidence(point, width: width, height: height, confidence: confidence)
                    * (dataTerm(point, width: width, height: height, known: known, luma: luma) + 0.001)
                if best.map({ priority > $0.priority }) ?? true {
                    best = (priority, point)
                }
            }
        }
        return best?.point
    }

    private func averageConfidence(_ point: SIMD2<Int>, width: Int, height: Int, confidence: [Float]) -> Float {
        let half = Self.half
        var sum: Float = 0
        for dy in -half ... half {
            for dx in -half ... half {
                let (x, y) = (point.x + dx, point.y + dy)
                if x >= 0, y >= 0, x < width, y < height {
                    sum += confidence[y * width + x]
                }
            }
        }
        return sum / Float((2 * half + 1) * (2 * half + 1))
    }

    /// How strongly an edge runs into the hole here: the isophote (along the edge) against the
    /// front's normal. Both come from known pixels only.
    private func dataTerm(
        _ point: SIMD2<Int>, width: Int, height: Int, known: UnsafeMutablePointer<UInt8>, luma: (Int) -> Float,
    ) -> Float {
        var normal = SIMD2<Float>.zero
        var gradient = SIMD2<Float>.zero
        var pairs = SIMD2<Float>.zero
        for dy in -1 ... 1 {
            for dx in -1 ... 1 where dx != 0 || dy != 0 {
                let (x, y) = (point.x + dx, point.y + dy)
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                if known[y * width + x] == 1 {
                    normal += SIMD2(Float(dx), Float(dy))
                }
            }
        }
        // Central differences of luminance across known pairs around the point.
        for dy in -1 ... 1 {
            for dx in -1 ... 1 {
                let (x, y) = (point.x + dx, point.y + dy)
                guard x >= 1, y >= 1, x < width - 1, y < height - 1 else { continue }
                let index = y * width + x
                if known[index - 1] == 1, known[index + 1] == 1 {
                    gradient.x += (luma(index + 1) - luma(index - 1)) / 2
                    pairs.x += 1
                }
                if known[index - width] == 1, known[index + width] == 1 {
                    gradient.y += (luma(index + width) - luma(index - width)) / 2
                    pairs.y += 1
                }
            }
        }
        guard simd_length(normal) > 0 else { return 0 }
        gradient /= simd_max(pairs, SIMD2(repeating: 1))
        let isophote = SIMD2(-gradient.y, gradient.x)
        return abs(simd_dot(isophote, simd_normalize(normal)))
    }

    private func patchCost(
        target: SIMD2<Int>, source: SIMD2<Int>, width: Int, height: Int, image: UnsafeMutablePointer<SIMD4<Float>>,
        known: UnsafeMutablePointer<UInt8>,
    ) -> Float {
        let half = Self.half
        var sum: Float = 0
        for dy in -half ... half {
            for dx in -half ... half {
                let t = target &+ SIMD2(dx, dy)
                guard t.x >= 0, t.y >= 0, t.x < width, t.y < height, known[t.y * width + t.x] == 1 else { continue }
                let s = source &+ SIMD2(dx, dy)
                let d = image[t.y * width + t.x] - image[s.y * width + s.x]
                sum += d.x * d.x + d.y * d.y + d.z * d.z
            }
        }
        return sum
    }
}
