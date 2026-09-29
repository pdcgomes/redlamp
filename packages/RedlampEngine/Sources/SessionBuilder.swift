import Foundation
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd

/// Uploads decoded sensor data and builds the demosaiced pyramid on the GPU.
struct SessionBuilder {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    static let analysisLongEdge = 1024

    func build(_ decoded: DecodedImage) throws -> ImageSession {
        let width = decoded.width
        let height = decoded.height
        let levels = Int(log2(Double(max(width, height)))) + 1

        let pyramidDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true,
        )
        pyramidDescriptor.mipmapLevelCount = levels
        pyramidDescriptor.usage = [.shaderRead, .shaderWrite]
        pyramidDescriptor.storageMode = .private
        guard let pyramid = device.makeTexture(descriptor: pyramidDescriptor),
              let commands = queue.makeCommandBuffer()
        else {
            throw EngineError.gpuUnavailable
        }
        commands.label = "Build pyramid"

        let minimum = decoded.asShotMultipliers.min()
        let balance = minimum > 0 ? decoded.asShotMultipliers / minimum : SIMD3(1, 1, 1)
        let multipliers = SIMD4<Float>(SIMD3<Float>(balance), 1)

        switch decoded.layout {
        case let .mosaic(pattern):
            try encodeMosaic(decoded, pattern: pattern, multipliers: multipliers, into: pyramid, commands: commands)
        case .linearRGB:
            try encodeLinearRGB(decoded, multipliers: multipliers, into: pyramid, commands: commands)
        case .linearSRGBHalf:
            try encodeBitmap(decoded, into: pyramid, commands: commands)
        }

        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.generateMipmaps(for: pyramid)
        let analysisLevel = max(0, levels - 1 - Int(log2(Double(Self.analysisLongEdge))))
        let analysisWidth = max(1, width >> analysisLevel)
        let analysisHeight = max(1, height >> analysisLevel)
        let rowBytes = analysisWidth * 8
        guard let readback = device.makeBuffer(length: rowBytes * analysisHeight, options: .storageModeShared) else {
            throw EngineError.gpuUnavailable
        }
        blit.copy(
            from: pyramid, sourceSlice: 0, sourceLevel: analysisLevel,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: analysisWidth, height: analysisHeight, depth: 1),
            to: readback, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * analysisHeight,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }

        let halves = readback.contents().assumingMemoryBound(to: Float16.self)
        let pixels = (0 ..< analysisWidth * analysisHeight).map { index in
            SIMD3<Float>(Float(halves[index * 4]), Float(halves[index * 4 + 1]), Float(halves[index * 4 + 2]))
        }
        let analysis = AnalysisImage(width: analysisWidth, height: analysisHeight, pixels: pixels)
        let colorModel = decoded.isRaw ? decoded.xyzToCamera.flatMap(CameraColorModel.init(xyzToCameraRowMajor:)) : nil
        var info = decoded.info
        info.asShotWhiteBalance = colorModel?.whiteBalance(forMultipliers: decoded.asShotMultipliers)

        return ImageSession(
            info: info,
            decoded: decoded,
            pyramid: pyramid,
            colorModel: colorModel,
            balanceMultipliers: balance,
            analysis: analysis,
        )
    }

    private func encodeMosaic(
        _ decoded: DecodedImage,
        pattern: CFAPattern,
        multipliers: SIMD4<Float>,
        into pyramid: any MTLTexture,
        commands: any MTLCommandBuffer,
    ) throws {
        let width = decoded.width
        let height = decoded.height
        let cfaDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false,
        )
        cfaDescriptor.usage = [.shaderRead, .shaderWrite]
        cfaDescriptor.storageMode = .private
        guard let cfa = device.makeTexture(descriptor: cfaDescriptor),
              let samples = decoded.samples.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
              }),
              let encoder = commands.makeComputeCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }

        var params = CFAParams(
            width: UInt32(width), height: UInt32(height), channels: 1,
            patternWidth: UInt32(pattern.width), patternHeight: UInt32(pattern.height),
            white: decoded.whiteLevel, multipliers: multipliers,
        )
        var blacks = decoded.blackLevels
        var colors = pattern.colors
        encoder.setComputePipelineState(kernels.cfaNormalize)
        encoder.setBuffer(samples, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<CFAParams>.stride, index: 1)
        encoder.setBytes(&blacks, length: blacks.count * MemoryLayout<Float>.stride, index: 2)
        encoder.setBytes(&colors, length: colors.count, index: 3)
        encoder.setTexture(cfa, index: 0)
        encoder.dispatchGrid(width: width, height: height, pipeline: kernels.cfaNormalize)

        var demosaicParams = DemosaicParams(
            width: UInt32(width), height: UInt32(height),
            patternWidth: UInt32(pattern.width), patternHeight: UInt32(pattern.height),
        )
        let demosaic = pattern.width == 2 && pattern.height == 2 ? kernels.demosaicBayer : kernels.demosaicGeneric
        encoder.setComputePipelineState(demosaic)
        encoder.setTexture(cfa, index: 0)
        encoder.setTexture(pyramid, index: 1)
        encoder.setBytes(&demosaicParams, length: MemoryLayout<DemosaicParams>.stride, index: 0)
        encoder.setBytes(&colors, length: colors.count, index: 1)
        encoder.dispatchGrid(width: width, height: height, pipeline: demosaic)
        encoder.endEncoding()
    }

    private func encodeLinearRGB(
        _ decoded: DecodedImage,
        multipliers: SIMD4<Float>,
        into pyramid: any MTLTexture,
        commands: any MTLCommandBuffer,
    ) throws {
        guard let samples = decoded.samples.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }),
            let encoder = commands.makeComputeCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }
        var params = CFAParams(
            width: UInt32(decoded.width), height: UInt32(decoded.height), channels: 3,
            patternWidth: 1, patternHeight: 1, white: decoded.whiteLevel, multipliers: multipliers,
        )
        var blacks = decoded.blackLevels
        encoder.setComputePipelineState(kernels.rgbNormalize)
        encoder.setBuffer(samples, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<CFAParams>.stride, index: 1)
        encoder.setBytes(&blacks, length: blacks.count * MemoryLayout<Float>.stride, index: 2)
        encoder.setTexture(pyramid, index: 0)
        encoder.dispatchGrid(width: decoded.width, height: decoded.height, pipeline: kernels.rgbNormalize)
        encoder.endEncoding()
    }

    private func encodeBitmap(
        _ decoded: DecodedImage,
        into pyramid: any MTLTexture,
        commands: any MTLCommandBuffer,
    ) throws {
        let rowBytes = decoded.width * 8
        guard let staging = decoded.samples.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }),
            let blit = commands.makeBlitCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes,
            sourceBytesPerImage: rowBytes * decoded.height,
            sourceSize: MTLSize(width: decoded.width, height: decoded.height, depth: 1),
            to: pyramid, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        )
        blit.endEncoding()
    }
}
