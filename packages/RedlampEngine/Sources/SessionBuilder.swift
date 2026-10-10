import Foundation
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampKernels
import RedlampMasking
import RedlampServices
import simd

/// How 2 x 2 Bayer mosaics are demosaiced.
enum BayerDemosaic {
    /// Directional filtering with a posteriori decision (Menon, Andriani & Calvagno 2007).
    case menon
    /// Gradient-corrected bilinear (Malvar, He & Cutler 2004); kept for comparison.
    case malvar
}

/// How X-Trans mosaics are demosaiced.
enum XTransDemosaic {
    /// Frank Markesteijn's algorithm, one pass (XTransDemosaic.swift, under the CDDL).
    case markesteijn
    /// Distance-weighted same-colour interpolation; kept for comparison.
    case generic
}

/// Uploads decoded sensor data and builds the demosaiced pyramid on the GPU.
struct SessionBuilder {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary
    var bayerDemosaic = BayerDemosaic.menon
    var xTransDemosaic = XTransDemosaic.markesteijn
    /// Menon's green is replaced by a plain average where only noise varies (CAM-06).
    var dualDemosaic = true
    /// The user's lens profiles, for raws that carry no correction (LNS-04). Off unless the app or
    /// CLI turns them on, so tests and references never depend on a developer's own profiles.
    var lensProfiles: LCPProfileLibrary?
    /// Where a photo's embedded mattes are found: the engine's decoder (the Mac app's decode
    /// service). None are found by builders that only render.
    var files: any FileInspecting = UnreadableFiles()

    static let analysisLongEdge = 1024
    /// A photosite counts as hot when it is this many noise sigmas above every neighbour...
    static let hotPixelThreshold: Float = 8
    /// ...and this many times as bright as the brightest.
    static let hotPixelRatio: Float = 2

    /// The photo's session, its raw stages at `revision`.
    func build(_ decoded: DecodedImage, revision: RawRevision = .current) throws -> ImageSession {
        try Self.checkGainMaps(decoded)
        let url = decoded.info.url
        let files = files
        let mattes = Prefetch(on: .global(qos: .userInitiated)) { files.embeddedMattes(in: url) }
        let balance = Self.balance(decoded)
        let noise = decoded.noise
        let noiseGain = try noiseGainTexture(decoded)
        let built = try pyramid(decoded, revision: revision, balance: balance, noise: noise, noiseGain: noiseGain)
        let pyramid = built.pyramid
        let maps = try Self.maps(of: pyramid, airlight: nil, device: device, queue: queue, kernels: kernels)
        let colorModel = decoded.isRaw ? decoded.xyzToCamera.flatMap(CameraColorModel.init(xyzToCameraRowMajor:)) : nil
        var info = decoded.info
        info.asShotWhiteBalance = colorModel?.whiteBalance(forMultipliers: decoded.asShotMultipliers)
        let embeddedLook = decoded.isRaw ? decoded.dngProfile.flatMap(EmbeddedLook.definition) : nil
        info.embeddedBaseLook = embeddedLook?.reference
        // A look designed to follow the gain table map renders as meant only where the map applies.
        info.embeddedBaseLookProcess = embeddedLook != nil && decoded.dngProfile?.gainTableMap != nil ? 5 : nil
        info.lensCorrection = LensCorrectionReader.correction(for: decoded, profiles: lensProfiles)

        return try ImageSession(
            info: info,
            decoded: decoded,
            pyramid: pyramid,
            rawRevision: revision,
            rawSource: built.dependsOnRevision ? ImageSession.RawSource(decoded: decoded, noise: noise) : nil,
            colorModel: colorModel,
            balanceMultipliers: balance,
            analysis: maps.analysis,
            noise: noise,
            repairedPixels: Int(built.repairedCount.contents().load(as: UInt32.self)),
            airlight: maps.airlight,
            hazeMap: maps.hazeMap,
            refinedHaze: maps.refinedHaze,
            toneBase: maps.toneBase,
            clarityBase: maps.clarityBase,
            glowSource: maps.glowSource,
            glowLights: maps.glowLights,
            noiseGain: noiseGain,
            hueSatMaps: decoded.isRaw ? HueSatMaps(profile: decoded.dngProfile, device: device) : nil,
            gainTableMap: decoded.isRaw ? GainTableMapTexture(decoded.dngProfile?.gainTableMap, device: device) : nil,
            embeddedLook: embeddedLook,
            embeddedMattes: mattes.value(),
        )
    }

    /// `photo` built again at `revision` from its raw source, with its own pyramid and maps, for
    /// the photo's edits at that revision (`RevisionStage`). Nil when every revision builds the
    /// photo's own pyramid.
    func variant(of photo: ImageSession, at revision: RawRevision) throws -> ImageSession? {
        guard let source = photo.rawSource else { return nil }
        let decoded = source.decoded
        let built = try pyramid(
            decoded, revision: revision, balance: Self.balance(decoded), noise: source.noise,
            noiseGain: photo.noiseGain,
        )
        let maps = try Self.maps(of: built.pyramid, airlight: nil, device: device, queue: queue, kernels: kernels)
        return ImageSession(variantOf: photo, revision: revision, pyramid: built.pyramid, maps: maps)
    }

    /// A mipmapped pyramid of `decoded` through the raw stages at `revision`; the buffer counting
    /// repaired photosites, and whether a stage that differs between revisions changed the pyramid.
    private func pyramid(
        _ decoded: DecodedImage, revision: RawRevision, balance: SIMD3<Double>, noise: NoiseModel,
        noiseGain: any MTLTexture,
    ) throws -> (pyramid: any MTLTexture, repairedCount: any MTLBuffer, dependsOnRevision: Bool) {
        let width = decoded.width
        let height = decoded.height
        let levels = Int(log2(Double(max(width, height)))) + 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true,
        )
        descriptor.mipmapLevelCount = levels
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let pyramid = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer() else {
            throw EngineError.gpuUnavailable
        }
        commands.label = "Build pyramid"
        let (repairedCount, highlights) = try encodeBase(
            decoded, revision: revision, balance: balance, noise: noise, noiseGain: noiseGain, into: pyramid,
            commands: commands,
        )
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.generateMipmaps(for: pyramid)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }
        return (pyramid, repairedCount, highlights != nil)
    }

    /// The maps made from the photo's own pixels, from `pyramid` with its mipmaps: its analysis
    /// copy, Dehaze's haze maps (from `airlight`, or one found in it), edge-aware Highlights and
    /// Shadows' and Clarity's bases, and the glow sources. Made when a photo opens, and again for a
    /// retouched copy, so nothing it removed lives on in them.
    static func maps(
        of pyramid: any MTLTexture, airlight known: SIMD3<Float>?, device: any MTLDevice, queue: any MTLCommandQueue,
        kernels: KernelLibrary,
    ) throws -> ImageMaps {
        let levels = pyramid.mipmapLevelCount
        let analysisLevel = max(0, levels - 1 - Int(log2(Double(Self.analysisLongEdge))))
        let analysisWidth = max(1, pyramid.width >> analysisLevel)
        let analysisHeight = max(1, pyramid.height >> analysisLevel)
        let rowBytes = analysisWidth * 8
        guard let readback = device.makeBuffer(length: rowBytes * analysisHeight, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { throw EngineError.gpuUnavailable }
        commands.label = "Analysis copy"
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
        let pixels = (0 ..< analysisWidth * analysisHeight).lazy.map { index in
            SIMD3<Float>(Float(halves[index * 4]), Float(halves[index * 4 + 1]), Float(halves[index * 4 + 2]))
        }
        let analysis = AnalysisImage(width: analysisWidth, height: analysisHeight, pixels: pixels)
        let airlight = known ?? Haze.airlight(analysis)
        let toneBase = try ToneBase.coefficients(analysis).texture(device: device)
        let clarityBase = try ClarityBase.coefficients(analysis, fullLongEdge: max(pyramid.width, pyramid.height))
            .texture(device: device)
        guard let hazeCommands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        hazeCommands.label = "Haze map"
        let (hazeMap, hazeBlocks) = try Haze.encodeMap(
            pyramid: pyramid, airlight: airlight, device: device, kernels: kernels, commands: hazeCommands,
        )
        let glowSource = try Glow.encodeSource(
            pyramid: pyramid, device: device, kernels: kernels, commands: hazeCommands,
        )
        let glowLights = try Glow.encodeSource(
            pyramid: pyramid, device: device, kernels: kernels, commands: hazeCommands, lightsOnly: true,
        )
        // Renders run on another queue, so the maps must be finished before the session is.
        hazeCommands.commit()
        hazeCommands.waitUntilCompleted()
        if let error = hazeCommands.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }
        let refinedHaze = try Haze.refined(blocks: hazeBlocks).texture(device: device)
        return ImageMaps(
            analysis: analysis, airlight: airlight, hazeMap: hazeMap, refinedHaze: refinedHaze, toneBase: toneBase,
            clarityBase: clarityBase, glowSource: glowSource, glowLights: glowLights,
        )
    }

    /// A frame for focus stacking: level 0 only (no mipmaps, analysis or haze map), full resolution,
    /// in camera RGB balanced by `balance(_:)`, exactly as a session's pyramid holds it. Its raw
    /// stages are the first revision's: a stack's merge is cached and shared by all its edits, so
    /// a later revision would change older edits whenever the cache is merged again.
    func demosaic(_ decoded: DecodedImage) throws -> DemosaicedFrame {
        try Self.checkGainMaps(decoded)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: decoded.width, height: decoded.height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer() else {
            throw EngineError.gpuUnavailable
        }
        commands.label = "Demosaic frame"
        let balance = Self.balance(decoded)
        let noise = decoded.noise
        _ = try encodeBase(
            decoded, revision: .first, balance: balance, noise: noise, noiseGain: noiseGainTexture(decoded),
            into: texture, commands: commands,
        )
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }
        return DemosaicedFrame(texture: texture, balance: balance, decoded: decoded, noise: noise)
    }

    /// As-shot white balance with the smallest channel at 1: what normalisation multiplies by, so
    /// highlight reconstruction and demosaicing see neutral colours.
    static func balance(_ decoded: DecodedImage) -> SIMD3<Double> {
        let minimum = decoded.asShotMultipliers.min()
        return minimum > 0 ? decoded.asShotMultipliers / minimum : SIMD3(1, 1, 1)
    }

    /// The fade's weights, sampled between cells by `rl_cfa_neutralize_highlights`.
    private func fadeTexture(_ fade: HighlightFade) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: fade.width, height: fade.height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        let halves = fade.weights.map(Float16.init)
        halves.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, fade.width, fade.height), mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: fade.width * MemoryLayout<Float16>.stride,
            )
        }
        return texture
    }

    /// The gain maps' gain per camera channel (see `NoiseGain`); 1 everywhere without them.
    private func noiseGainTexture(_ decoded: DecodedImage) throws -> any MTLTexture {
        let field = switch decoded.layout {
        case let .mosaic(pattern):
            NoiseGain.field(decoded.gainMaps, width: decoded.width, height: decoded.height, pattern: pattern)
        case .linearRGB:
            NoiseGain.field(decoded.gainMaps, width: decoded.width, height: decoded.height, pattern: nil)
        case .linearSRGBHalf, .balancedCameraHalf:
            NoiseGain.field([], width: decoded.width, height: decoded.height, pattern: nil)
        }
        return try NoiseGain.texture(field, device: device)
    }

    /// Level 0 of `texture`: normalised, hot pixels repaired, highlights rebuilt as `revision` does
    /// and demosaiced. Returns the buffer counting repaired photosites, readable once `commands`
    /// completes, and the highlight model, nil when nothing clipped.
    private func encodeBase(
        _ decoded: DecodedImage,
        revision: RawRevision,
        balance: SIMD3<Double>,
        noise: NoiseModel,
        noiseGain: any MTLTexture,
        into texture: any MTLTexture,
        commands: any MTLCommandBuffer,
    ) throws -> (repairedCount: any MTLBuffer, highlights: HighlightModel?) {
        let multipliers = SIMD4<Float>(SIMD3<Float>(balance), 1)
        guard let repairedCount = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
        else {
            throw EngineError.gpuUnavailable
        }
        memset(repairedCount.contents(), 0, repairedCount.length)
        var highlights: HighlightModel?
        switch decoded.layout {
        case let .mosaic(pattern):
            highlights = HighlightModel.fit(decoded, balance: SIMD3<Float>(balance), revision: revision)
            try encodeMosaic(
                decoded, pattern: pattern, multipliers: multipliers,
                noise: noise.scaled(by: SIMD3<Float>(balance)), noiseGain: noiseGain, repairedCount: repairedCount,
                highlights: highlights, into: texture, commands: commands,
            )
        case .linearRGB:
            try encodeLinearRGB(decoded, multipliers: multipliers, into: texture, commands: commands)
        case .linearSRGBHalf, .balancedCameraHalf:
            try encodeHalves(decoded, into: texture, commands: commands)
        }
        return (repairedCount, highlights)
    }

    private func encodeMosaic(
        _ decoded: DecodedImage,
        pattern: CFAPattern,
        multipliers: SIMD4<Float>,
        noise: NoiseModel,
        noiseGain: any MTLTexture,
        repairedCount: any MTLBuffer,
        highlights: HighlightModel?,
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
              let repaired = device.makeTexture(descriptor: cfaDescriptor),
              let samples = decoded.samples.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
              })
        else {
            throw EngineError.gpuUnavailable
        }
        let fade = try highlights?.fade.map { try (cell: $0.cell, texture: fadeTexture($0)) }

        try commands.withComputeEncoder { encoder in
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
            let banding = decoded.banding
            let lines = [(banding?.rows ?? [], height), (banding?.columns ?? [], width)]
            for (index, (offsets, count)) in lines.enumerated() {
                let values = offsets.count == count ? offsets : [Float](repeating: 0, count: count)
                guard let buffer = device.makeBuffer(
                    bytes: values, length: count * MemoryLayout<Float>.stride, options: .storageModeShared,
                ) else {
                    throw EngineError.gpuUnavailable
                }
                encoder.setBuffer(buffer, offset: 0, index: 4 + index)
            }
            encoder.setTexture(cfa, index: 0)
            encoder.dispatchGrid(width: width, height: height, pipeline: kernels.cfaNormalize)

            var hotParams = HotPixelParams(
                width: UInt32(width), height: UInt32(height),
                patternWidth: UInt32(pattern.width), patternHeight: UInt32(pattern.height),
                threshold: Self.hotPixelThreshold, ratio: Self.hotPixelRatio,
                a: SIMD4(noise.a, 0), b: SIMD4(noise.b, 0),
            )
            encoder.setComputePipelineState(kernels.repairHotPixels)
            encoder.setTexture(cfa, index: 0)
            encoder.setTexture(repaired, index: 1)
            encoder.setBytes(&hotParams, length: MemoryLayout<HotPixelParams>.stride, index: 0)
            encoder.setBytes(&colors, length: colors.count, index: 1)
            encoder.setBuffer(repairedCount, offset: 0, index: 2)
            encoder.dispatchGrid(width: width, height: height, pipeline: kernels.repairHotPixels)

            // Rebuilt highlights go back into the first texture, which the demosaic then reads; faded
            // ones into the second.
            var mosaic = repaired
            if let highlights {
                var highlightParams = HighlightParams(
                    width: UInt32(width), height: UInt32(height),
                    patternWidth: UInt32(pattern.width), patternHeight: UInt32(pattern.height),
                    clip: highlights.clip,
                )
                var coefficients = highlights.coefficients
                let reconstruct = highlights.revision >= .second
                    ? kernels.reconstructHighlightsJoint : kernels.reconstructHighlights
                encoder.setComputePipelineState(reconstruct)
                encoder.setTexture(repaired, index: 0)
                encoder.setTexture(cfa, index: 1)
                encoder.setBytes(&highlightParams, length: MemoryLayout<HighlightParams>.stride, index: 0)
                encoder.setBytes(&colors, length: colors.count, index: 1)
                encoder.setBytes(
                    &coefficients, length: coefficients.count * MemoryLayout<SIMD4<Float>>.stride, index: 2,
                )
                encoder.dispatchGrid(width: width, height: height, pipeline: reconstruct)
                mosaic = cfa
                if let fade {
                    var fadeParams = HighlightFadeParams(
                        width: UInt32(width), height: UInt32(height),
                        patternWidth: UInt32(pattern.width), patternHeight: UInt32(pattern.height),
                        clip: highlights.clip, cell: UInt32(fade.cell),
                    )
                    encoder.setComputePipelineState(kernels.neutralizeHighlights)
                    encoder.setTexture(cfa, index: 0)
                    encoder.setTexture(repaired, index: 1)
                    encoder.setTexture(fade.texture, index: 2)
                    encoder.setBytes(&fadeParams, length: MemoryLayout<HighlightFadeParams>.stride, index: 0)
                    encoder.setBytes(&colors, length: colors.count, index: 1)
                    encoder.dispatchGrid(width: width, height: height, pipeline: kernels.neutralizeHighlights)
                    mosaic = repaired
                }
            }

            // Lens shading last: clipping and hot pixels are judged against the sensor's own levels.
            if !decoded.gainMaps.isEmpty {
                let (maps, gains) = try gainMapBuffers(decoded.gainMaps)
                var count = UInt32(decoded.gainMaps.count)
                encoder.setComputePipelineState(kernels.applyGainMaps)
                encoder.setTexture(mosaic, index: 0)
                encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 0)
                encoder.setBuffer(maps, offset: 0, index: 1)
                encoder.setBuffer(gains, offset: 0, index: 2)
                encoder.dispatchGrid(width: width, height: height, pipeline: kernels.applyGainMaps)
            }

            var demosaicParams = DemosaicParams(
                width: UInt32(width), height: UInt32(height),
                patternWidth: UInt32(pattern.width), patternHeight: UInt32(pattern.height),
            )
            let bayer = pattern.width == 2 && pattern.height == 2
            if bayer, bayerDemosaic == .menon {
                try encodeMenon(
                    mosaic: mosaic, spare: mosaic === cfa ? repaired : cfa, colors: colors, params: demosaicParams,
                    noise: noise, noiseGain: noiseGain,
                    into: pyramid, encoder: encoder,
                )
                return
            }
            let demosaic = bayer ? kernels.demosaicBayer : kernels.demosaicGeneric
            encoder.setComputePipelineState(demosaic)
            encoder.setTexture(mosaic, index: 0)
            encoder.setTexture(pyramid, index: 1)
            encoder.setBytes(&demosaicParams, length: MemoryLayout<DemosaicParams>.stride, index: 0)
            encoder.setBytes(&colors, length: colors.count, index: 1)
            encoder.dispatchGrid(width: width, height: height, pipeline: demosaic)
            // X-Trans keeps the generic interpolation only in the 8 photosites at its edges.
            if !bayer, xTransDemosaic == .markesteijn, let table = XTransMarkesteijn(pattern) {
                try encodeMarkesteijn(
                    table, mosaic: mosaic, colors: colors, cameraToSRGB: decoded.cameraToSRGB, into: pyramid,
                    encoder: encoder,
                )
            }
        }
    }

    /// The four Menon passes. `spare` is a free full-resolution float texture, reused for green;
    /// `noise` (white-balanced) and `noiseGain` set where the dual demosaic smooths.
    private func encodeMenon(
        mosaic: any MTLTexture,
        spare: any MTLTexture,
        colors: [UInt8],
        params: DemosaicParams,
        noise: NoiseModel,
        noiseGain: any MTLTexture,
        into pyramid: any MTLTexture,
        encoder: any MTLComputeCommandEncoder,
    ) throws {
        let width = mosaic.width
        let height = mosaic.height
        func texture(_ format: MTLPixelFormat) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false,
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
            return texture
        }
        // Pass 1's estimates, then pass 3's partial RGB.
        let working = try texture(.rgba16Float)
        let directions = try texture(.r8Snorm)
        var params = params
        var colors = colors
        func dispatch(_ pipeline: any MTLComputePipelineState, _ textures: [any MTLTexture]) {
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() {
                encoder.setTexture(texture, index: index)
            }
            encoder.setBytes(&params, length: MemoryLayout<DemosaicParams>.stride, index: 0)
            encoder.setBytes(&colors, length: colors.count, index: 1)
            encoder.dispatchGrid(width: width, height: height, pipeline: pipeline)
        }
        dispatch(kernels.menonDirectional, [mosaic, working])
        dispatch(kernels.menonGreen, [mosaic, working, spare, directions])
        dispatch(kernels.menonRBAtGreen, [mosaic, spare, working])
        // Without noise every site counts as detail, which turns the blend off.
        let blend = dualDemosaic ? noise : NoiseModel(a: .zero, b: .zero)
        var model = [SIMD4<Float>(blend.a, 0), SIMD4<Float>(blend.b, 0)]
        encoder.setBytes(&model, length: model.count * MemoryLayout<SIMD4<Float>>.stride, index: 2)
        dispatch(kernels.menonRBAtRB, [working, directions, pyramid, mosaic, noiseGain])
    }

    /// Checked before any encoder opens: an encoder left open by a throw aborts under Metal's
    /// validation layer.
    private static func checkGainMaps(_ decoded: DecodedImage) throws {
        guard GainMap.areValid(decoded.gainMaps) else {
            throw EngineError.decodeFailed("the photo's lens shading is damaged")
        }
    }

    /// Gain maps as kernel buffers; a neutral placeholder when there are none.
    private func gainMapBuffers(_ maps: [GainMap]) throws -> (maps: any MTLBuffer, gains: any MTLBuffer) {
        var descriptors: [GainMapGPU] = []
        var gains: [Float] = []
        for map in maps {
            descriptors.append(GainMapGPU(
                area: SIMD4(Int32(map.top), Int32(map.left), Int32(map.bottom), Int32(map.right)),
                grid: SIMD4(Int32(map.rowPitch), Int32(map.columnPitch), Int32(map.pointsV), Int32(map.pointsH)),
                placement: SIMD4(Float(map.spacingV), Float(map.spacingH), Float(map.originV), Float(map.originH)),
                planes: SIMD4(Int32(map.plane), Int32(map.planes), Int32(map.mapPlanes), Int32(gains.count)),
            ))
            gains += map.gains
        }
        if descriptors.isEmpty {
            descriptors = [GainMapGPU(
                area: .zero,
                grid: SIMD4(1, 1, 1, 1),
                placement: SIMD4(1, 1, 0, 0),
                planes: .zero,
            )]
            gains = [1]
        }
        guard let mapBuffer = device.makeBuffer(
            bytes: descriptors, length: descriptors.count * MemoryLayout<GainMapGPU>.stride,
            options: .storageModeShared,
        ),
            let gainBuffer = device.makeBuffer(
                bytes: gains, length: gains.count * MemoryLayout<Float>.stride, options: .storageModeShared,
            )
        else {
            throw EngineError.gpuUnavailable
        }
        return (mapBuffer, gainBuffer)
    }

    private func encodeLinearRGB(
        _ decoded: DecodedImage,
        multipliers: SIMD4<Float>,
        into pyramid: any MTLTexture,
        commands: any MTLCommandBuffer,
    ) throws {
        guard let samples = decoded.samples.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else {
            throw EngineError.gpuUnavailable
        }
        try commands.withComputeEncoder { encoder in
            var params = CFAParams(
                width: UInt32(decoded.width), height: UInt32(decoded.height), channels: 3,
                patternWidth: 1, patternHeight: 1, white: decoded.whiteLevel, multipliers: multipliers,
            )
            params.pad0 = UInt32(decoded.gainMaps.count)
            let (maps, gains) = try gainMapBuffers(decoded.gainMaps)
            var blacks = decoded.blackLevels
            encoder.setComputePipelineState(kernels.rgbNormalize)
            encoder.setBuffer(samples, offset: 0, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<CFAParams>.stride, index: 1)
            encoder.setBytes(&blacks, length: blacks.count * MemoryLayout<Float>.stride, index: 2)
            encoder.setBuffer(maps, offset: 0, index: 3)
            encoder.setBuffer(gains, offset: 0, index: 4)
            encoder.setTexture(pyramid, index: 0)
            encoder.dispatchGrid(width: decoded.width, height: decoded.height, pipeline: kernels.rgbNormalize)
        }
    }

    /// Float16 RGBA samples copied straight into level 0.
    private func encodeHalves(
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
