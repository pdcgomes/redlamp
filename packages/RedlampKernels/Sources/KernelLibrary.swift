import Foundation
import Metal

/// The compiled Redlamp compute kernels.
///
/// Pipeline states are created once at startup; encoding a frame never compiles.
public final class KernelLibrary: @unchecked Sendable {
    public let device: any MTLDevice
    public let cfaNormalize: any MTLComputePipelineState
    public let rgbNormalize: any MTLComputePipelineState
    public let repairHotPixels: any MTLComputePipelineState
    public let reconstructHighlights: any MTLComputePipelineState
    public let applyGainMaps: any MTLComputePipelineState
    public let demosaicBayer: any MTLComputePipelineState
    public let demosaicGeneric: any MTLComputePipelineState
    public let menonDirectional: any MTLComputePipelineState
    public let menonGreen: any MTLComputePipelineState
    public let menonRBAtGreen: any MTLComputePipelineState
    public let menonRBAtRB: any MTLComputePipelineState
    public let develop: any MTLComputePipelineState
    public let histogram: any MTLComputePipelineState
    public let denoisePrepare: any MTLComputePipelineState
    public let denoiseRows: any MTLComputePipelineState
    public let denoiseColumns: any MTLComputePipelineState
    public let denoiseShrink: any MTLComputePipelineState
    public let denoiseNonLocal: any MTLComputePipelineState
    public let stackWarp: any MTLComputePipelineState
    public let stackPyramidDown: any MTLComputePipelineState
    public let stackLaplacian: any MTLComputePipelineState
    public let stackCollapse: any MTLComputePipelineState
    public let stackFuseAuto: any MTLComputePipelineState
    public let stackChooseAuto: any MTLComputePipelineState
    public let stackFuseDetail: any MTLComputePipelineState
    public let stackFuseSmooth: any MTLComputePipelineState
    public let stackFinish: any MTLComputePipelineState
    public let stackScale: any MTLComputePipelineState
    public let sharpenLog: any MTLComputePipelineState
    public let sharpenLuma: any MTLComputePipelineState
    public let sharpenBlur: any MTLComputePipelineState
    public let deconvolveColumns: any MTLComputePipelineState
    public let sharpenAnalysis: any MTLComputePipelineState
    public let sharpenApply: any MTLComputePipelineState
    public let localContrast: any MTLComputePipelineState
    public let detailLocal: any MTLComputePipelineState
    public let ladderRows: any MTLComputePipelineState
    public let ladderColumns: any MTLComputePipelineState
    public let ladderSeparate: any MTLComputePipelineState
    public let detailApply: any MTLComputePipelineState
    public let hazeDark: any MTLComputePipelineState
    public let hazeFilter: any MTLComputePipelineState
    public let glowSource: any MTLComputePipelineState
    public let rawClipping: any MTLComputePipelineState
    public let encodeSRGB: any MTLComputePipelineState
    public let maskClear: any MTLComputePipelineState
    public let maskStroke: any MTLComputePipelineState
    public let maskStrokeApply: any MTLComputePipelineState
    public let maskUpload: any MTLComputePipelineState
    public let retouchRim: any MTLComputePipelineState
    public let retouchRimMedian: any MTLComputePipelineState
    public let retouchApply: any MTLComputePipelineState
    public let fillCosts: any MTLComputePipelineState
    public let fillRender: any MTLComputePipelineState

    public init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: KernelLibrary.self))

        func pipeline(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw KernelError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }

        cfaNormalize = try pipeline("rl_cfa_normalize")
        rgbNormalize = try pipeline("rl_rgb_normalize")
        repairHotPixels = try pipeline("rl_cfa_repair_hot_pixels")
        reconstructHighlights = try pipeline("rl_cfa_reconstruct_highlights")
        applyGainMaps = try pipeline("rl_cfa_apply_gain_maps")
        demosaicBayer = try pipeline("rl_demosaic_bayer")
        demosaicGeneric = try pipeline("rl_demosaic_generic")
        menonDirectional = try pipeline("rl_menon_directional")
        menonGreen = try pipeline("rl_menon_green")
        menonRBAtGreen = try pipeline("rl_menon_rb_at_green")
        menonRBAtRB = try pipeline("rl_menon_rb_at_rb")
        develop = try pipeline("rl_develop")
        histogram = try pipeline("rl_histogram")
        denoisePrepare = try pipeline("rl_denoise_prepare")
        denoiseRows = try pipeline("rl_denoise_rows")
        denoiseColumns = try pipeline("rl_denoise_columns")
        denoiseShrink = try pipeline("rl_denoise_shrink")
        denoiseNonLocal = try pipeline("rl_denoise_nonlocal")
        stackWarp = try pipeline("rl_stack_warp")
        stackPyramidDown = try pipeline("rl_stack_pyr_down")
        stackLaplacian = try pipeline("rl_stack_laplacian")
        stackCollapse = try pipeline("rl_stack_collapse")
        stackFuseAuto = try pipeline("rl_stack_fuse_auto")
        stackChooseAuto = try pipeline("rl_stack_choose_auto")
        stackFuseDetail = try pipeline("rl_stack_fuse_detail")
        stackFuseSmooth = try pipeline("rl_stack_fuse_smooth")
        stackFinish = try pipeline("rl_stack_finish")
        stackScale = try pipeline("rl_stack_scale")
        sharpenLog = try pipeline("rl_sharpen_log")
        sharpenLuma = try pipeline("rl_sharpen_luma")
        sharpenBlur = try pipeline("rl_sharpen_blur")
        deconvolveColumns = try pipeline("rl_deconvolve_columns")
        sharpenAnalysis = try pipeline("rl_sharpen_analysis")
        sharpenApply = try pipeline("rl_sharpen_apply")
        localContrast = try pipeline("rl_local_contrast")
        detailLocal = try pipeline("rl_detail_local")
        ladderRows = try pipeline("rl_ladder_rows")
        ladderColumns = try pipeline("rl_ladder_columns")
        ladderSeparate = try pipeline("rl_ladder_separate")
        detailApply = try pipeline("rl_detail_apply")
        hazeDark = try pipeline("rl_haze_dark")
        hazeFilter = try pipeline("rl_haze_filter")
        glowSource = try pipeline("rl_glow_source")
        rawClipping = try pipeline("rl_raw_clipping")
        encodeSRGB = try pipeline("rl_encode_srgb")
        maskClear = try pipeline("rl_mask_clear")
        maskStroke = try pipeline("rl_mask_stroke")
        maskStrokeApply = try pipeline("rl_mask_stroke_apply")
        maskUpload = try pipeline("rl_mask_upload")
        retouchRim = try pipeline("rl_retouch_rim")
        retouchRimMedian = try pipeline("rl_retouch_rim_median")
        retouchApply = try pipeline("rl_retouch_apply")
        fillCosts = try pipeline("rl_fill_costs")
        fillRender = try pipeline("rl_fill_render")
    }
}

public enum KernelError: Error, CustomStringConvertible {
    case missingFunction(String)
    case bufferAllocation

    public var description: String {
        switch self {
        case let .missingFunction(name): "Metal function \(name) is missing from the kernel library"
        case .bufferAllocation: "A Metal buffer could not be allocated"
        }
    }
}

public extension MTLComputeCommandEncoder {
    /// Binds an array of plain values: inline when small enough, otherwise in a new buffer.
    func setArray<T>(_ values: [T], index: Int, device: any MTLDevice) throws {
        let length = values.count * MemoryLayout<T>.stride
        try values.withUnsafeBytes { bytes in
            if length <= 4096 {
                setBytes(bytes.baseAddress!, length: length, index: index)
            } else {
                guard let buffer = device.makeBuffer(
                    bytes: bytes.baseAddress!,
                    length: length,
                    options: .storageModeShared,
                )
                else { throw KernelError.bufferAllocation }
                setBuffer(buffer, offset: 0, index: index)
            }
        }
    }

    /// Dispatches one thread per pixel of a `width` x `height` grid. A threadgroup is never taller
    /// than the grid: a kernel indexed by a scalar `thread_position_in_grid` (a 1-row grid) must
    /// get threadgroups one row tall, or Metal's validation layer aborts the dispatch.
    func dispatchGrid(width: Int, height: Int, pipeline: any MTLComputePipelineState) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: min(h, 16, max(height, 1)), depth: 1),
        )
    }
}
