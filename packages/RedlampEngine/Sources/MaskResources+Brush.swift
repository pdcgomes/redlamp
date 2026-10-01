import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels

/// Brush components: strokes drawn on the GPU into a slice, the last one redrawn over a copy of
/// the slice without it while painting.
extension MaskResources {
    func drawBrush(
        _ brush: BrushMask,
        avoiding used: Set<Int>,
        guide: (any MTLTexture)?,
        commands: any MTLCommandBuffer,
    ) throws -> Int? {
        let strokes = brush.strokes
        let base = BrushMask(strokes: Array(strokes.dropLast()))
        // The slice holding an earlier version of this brush: the same strokes with a shorter
        // last one (while painting), or fewer strokes.
        let earlier = keys.indices.first { index in
            guard !used.contains(index), case let .brush(old) = keys[index] else { return false }
            return old.strokes.count == strokes.count && Array(old.strokes.dropLast()) == base.strokes
                || old.strokes.count < strokes.count && Array(strokes.prefix(old.strokes.count)) == old.strokes
        }
        guard let slice = try freeSlice(avoiding: used, preferring: earlier, commands: commands),
              let rasters
        else { return nil }
        let scratch = try scratchTexture(commands: commands)

        if let last = strokes.last, let paintBase, paintBase.key == base {
            try copy(paintBase.texture, slice: 0, to: rasters, slice: slice, commands: commands)
            try encodeStrokes([last], slice: slice, scratch: scratch, guide: guide, commands: commands)
            return slice
        }
        var drawn = 0
        if let earlier, earlier == slice, case let .brush(old) = keys[earlier],
           old.strokes.count < strokes.count, Array(strokes.prefix(old.strokes.count)) == old.strokes {
            drawn = old.strokes.count
        } else {
            try clear(slice, commands: commands)
        }
        guard !strokes.isEmpty else { return slice }
        if drawn < strokes.count - 1 {
            try encodeStrokes(
                Array(strokes[drawn ..< strokes.count - 1]), slice: slice, scratch: scratch, guide: guide,
                commands: commands,
            )
        }
        let baseTexture = try paintBase?.texture ?? makeSingle()
        try copy(rasters, slice: slice, to: baseTexture, slice: 0, commands: commands)
        paintBase = (base, baseTexture)
        try encodeStrokes(
            [strokes[strokes.count - 1]],
            slice: slice,
            scratch: scratch,
            guide: guide,
            commands: commands,
        )
        return slice
    }

    /// Where a stroke's dabs gather; zero everywhere between strokes (applying clears it).
    private func scratchTexture(commands: any MTLCommandBuffer) throws -> any MTLTexture {
        if let scratch {
            return scratch
        }
        let texture = try makeSingle()
        try clear(texture, slice: 0, commands: commands)
        scratch = texture
        return texture
    }

    /// Draws strokes in order into `slice`.
    private func encodeStrokes(
        _ strokes: [BrushStroke],
        slice: Int,
        scratch: any MTLTexture,
        guide: (any MTLTexture)?,
        commands: any MTLCommandBuffer,
    ) throws {
        guard let rasters, let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        let size = SIMD2<Float>(Float(rasterSize.width), Float(rasterSize.height))
        for stroke in strokes where !stroke.points.isEmpty {
            let plan = BrushRaster.plan(stroke, rasterSize: rasterSize)
            let brush = SIMD4<Float>(
                Float(plan.radius), Float(stroke.feather / 100), Float(stroke.flow / 100), Float(stroke.density / 100),
            )
            encoder.setComputePipelineState(kernels.maskStroke)
            encoder.setTexture(scratch, index: 0)
            encoder.setTexture(guide ?? emptyGuide, index: 1)
            for run in plan.runs {
                var points = run.points
                var params = MaskRasterParams(
                    box: run.box, info: SIMD4(0, Int32(points.count), stroke.autoMask && guide != nil ? 1 : 0, 0),
                    brush: brush, raster: SIMD4(size.x, size.y, 0, 0),
                )
                encoder.setBytes(&params, length: MemoryLayout<MaskRasterParams>.stride, index: 0)
                encoder.setBytes(&points, length: points.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
                encoder.dispatchGrid(width: Int(run.box.z), height: Int(run.box.w), pipeline: kernels.maskStroke)
            }
            var params = MaskRasterParams(
                box: plan.box, info: SIMD4(Int32(slice), 0, 0, stroke.erase ? 1 : 0), brush: brush,
                raster: SIMD4(size.x, size.y, 0, 0),
            )
            encoder.setComputePipelineState(kernels.maskStrokeApply)
            encoder.setTexture(scratch, index: 0)
            encoder.setTexture(rasters, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<MaskRasterParams>.stride, index: 0)
            encoder.dispatchGrid(width: Int(plan.box.z), height: Int(plan.box.w), pipeline: kernels.maskStrokeApply)
        }
        encoder.endEncoding()
    }
}

/// How a stroke is drawn: its points in raster pixels, cut into runs of segments with the area
/// each touches. Shared with the CPU reference in tests.
enum BrushRaster {
    struct Run {
        /// x, y in raster pixels, z pressure.
        var points: [SIMD4<Float>]
        var box: SIMD4<Int32>
    }

    struct Plan {
        var radius: Double
        var runs: [Run]
        /// The union of the runs' areas.
        var box: SIMD4<Int32>
    }

    static func plan(_ stroke: BrushStroke, rasterSize: PixelSize) -> Plan {
        let width = Double(rasterSize.width)
        let height = Double(rasterSize.height)
        let radius = max(stroke.size * height, 0.5)
        let points = stroke.points.indices.map { index in
            let point = stroke.points[index]
            return SIMD4<Float>(Float(point.x * width), Float(point.y * height), Float(stroke.pressure(at: index)), 0)
        }
        var runs: [Run] = []
        let step = MaskResources.segmentsPerDispatch
        var start = 0
        repeat {
            let end = min(start + step, points.count - 1)
            let run = Array(points[start ... max(end, start)])
            runs.append(Run(points: run, box: box(run, radius: radius, width: width, height: height)))
            start = end
        } while start < points.count - 1
        let union = runs.map(\.box).reduce(SIMD4<Int32>(Int32.max, Int32.max, Int32.min, Int32.min)) { total, box in
            SIMD4(min(total.x, box.x), min(total.y, box.y), max(total.z, box.x + box.z), max(total.w, box.y + box.w))
        }
        return Plan(
            radius: radius, runs: runs,
            box: SIMD4(union.x, union.y, max(union.z - union.x, 0), max(union.w - union.y, 0)),
        )
    }

    private static func box(_ points: [SIMD4<Float>], radius: Double, width: Double, height: Double) -> SIMD4<Int32> {
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        let x0 = max(Int(((xs.min() ?? 0) - radius).rounded(.down)), 0)
        let y0 = max(Int(((ys.min() ?? 0) - radius).rounded(.down)), 0)
        let x1 = min(Int(((xs.max() ?? 0) + radius).rounded(.up)), Int(width))
        let y1 = min(Int(((ys.max() ?? 0) + radius).rounded(.up)), Int(height))
        return SIMD4(Int32(x0), Int32(y0), Int32(max(x1 - x0, 0)), Int32(max(y1 - y0, 0)))
    }
}
